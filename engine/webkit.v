module engine

// ---------------------------------------------------------------------------
// WebKit engine backend (WinCairo) — replaces the Ultralight backend.
//
// Ultralight -> WebKit mapping:
//   ulCreateApp/ulCreateWindow/ulWindowAddPanel  -> wk_host_create + WKViewCreate
//   ulViewLoadURL                                -> WKPageLoadURL
//   ulViewLoadHTML                               -> WKPageLoadHTMLString
//   ulAppRunOnce loop                            -> Win32 message pump (ours)
//   ulViewEvaluateScript (sync)                  -> WKPageEvaluateJavaScriptInMainFrame (async!)
//   ULJSAPI / window.vshell (frozen)             -> WKUserContentController + WKUserScript
//   ulStartRemoteInspectorServer (Free: no)      -> WKInspector*.WebKit has the real Inspector
//
// API signatures and their origin: docs/wk-api-signatures.md
// Build/staging of the engine:      scripts/stage_runtime.sh
//
// C glue (window, WKViewCreate with RECT-by-value, message thunk): engine/wk_host.h
// ---------------------------------------------------------------------------

// `import` must come before the C declarations. The V1 compatibility compiler
// rejects an import placed after a #include with "`import x` can only be
// declared at the beginning of the file", even though the default compiler
// accepts it, so the order here is deliberate.
import time

#include "engine/wk_host.h"

// Link against the WinCairo import library that stage_runtime.sh produces with
// gendef + dlltool from WebKit2.dll. Without this the link fails with
// "undefined reference to `__imp_WKRelease'" (and one per API call), because
// WK_EXPORT expands to __declspec(dllimport) and nothing supplies the __imp_
// stubs. The -L is relative to the module root so it resolves from any cwd;
// build_vshell.sh also passes it absolutely, since V runs the linker from a
// temp directory and a relative -L would resolve against that instead.
#flag -L@VMODROOT/.work/wk/lib
#flag -lWebKit2

// --- what wk_host.h exposes to V (all handles are void*) ---------------------
fn C.wk_host_create(title &char, width int, height int, on_close WkCloseCb, ctx voidptr) voidptr
fn C.wk_host_hwnd(state voidptr) voidptr
fn C.wk_host_attach_view(state voidptr, page_configuration voidptr, width int, height int) voidptr
fn C.wk_host_page(state voidptr) voidptr
fn C.wk_host_view(state voidptr) voidptr
fn C.wk_host_resize_view(state voidptr, width int, height int)
fn C.wk_host_set_title(state voidptr, title &char)
fn C.wk_host_wait(state voidptr, ms int)
fn C.wk_host_pump_once(state voidptr) int
fn C.wk_host_destroy(state voidptr)

fn C.wk_page_configuration_create() voidptr
fn C.wk_page_configuration_set_user_content_controller(config voidptr, ucc voidptr)
fn C.wk_page_configuration_set_developer_extras(config voidptr, enabled int)
fn C.wk_user_content_controller_create() voidptr
fn C.wk_user_content_controller_add_message_handler(ucc voidptr, cb WkMsgCb, ctx voidptr)
fn C.wk_user_content_controller_add_user_script(ucc voidptr, source &char)

fn C.wk_page_load_url(page voidptr, url &char)
fn C.wk_page_load_html(page voidptr, html &char, base_url &char)
fn C.wk_page_eval(page voidptr, script &char, cb WkEvalCb, ctx voidptr)
fn C.wk_type_to_utf8(type_ref voidptr) voidptr
fn C.wk_cstr_len(s voidptr) usize
fn C.wk_page_copy_title(page voidptr) voidptr
fn C.wk_page_copy_url(page voidptr) voidptr
fn C.wk_host_free(p voidptr)

fn C.wk_page_show_inspector(page voidptr, attached int) int
fn C.wk_page_inspector_is_visible(page voidptr) int
fn C.wk_release(ref voidptr)

// --- callback signatures ----------------------------------------------------
type WkCloseCb = fn (ctx voidptr)
type WkMsgCb = fn (text &char, ctx voidptr)
type WkEvalCb = fn (value voidptr, err_ref voidptr, ctx voidptr)

// voidptr -> string. `vstring()` only exists on &char, not on a bare voidptr,
// so this uses the same idiom as ultralight.v (vbytes + bytestr): the bytes are
// copied explicitly because those buffers are freed right after the call.
fn wk_cstr(p voidptr) string {
	if p == unsafe { nil } {
		return ''
	}
	n := C.wk_cstr_len(p)
	if n == 0 {
		return ''
	}
	return unsafe { p.vbytes(int(n)).bytestr() }
}

// --- the frozen page-side object (mirrors the Ultralight ULJSAPI namespace) --
//
// WebKit only delivers the message body, never the handler name, so the page
// packs name and payload with an ASCII unit separator (0x1F) that cannot appear
// in a method name. Swap for x.json2 if you prefer typed decoding.
const vshell_user_script = '
window.vshell = Object.freeze({
	version: "vshell-bridge-wk",
	post: (name, payload) => window.webkit.messageHandlers.vshell.postMessage(
		String(name) + "\u001f" + (payload === undefined ? "" : String(payload))),
});
'

// ---------------------------------------------------------------------------
// bridge state (Wk-prefixed so this file can coexist with ultralight.v while
// you migrate; delete the Wk prefix once ultralight.v is gone)
// ---------------------------------------------------------------------------
struct WkBridgeMsg {
	name    string
	payload string
}

struct WkBridgeInbox {
mut:
	msgs []WkBridgeMsg
}

struct WkEvalBox {
mut:
	done  bool
	value string
	err   string
}

// ---------------------------------------------------------------------------
// WebKitEngine
// ---------------------------------------------------------------------------
pub struct WebKitEngine {
mut:
	host   voidptr = unsafe { nil }
	hwnd   voidptr = unsafe { nil }
	view   voidptr = unsafe { nil }
	page   voidptr = unsafe { nil }
	ucc    voidptr = unsafe { nil }
	config voidptr = unsafe { nil }
	title  string

	inbox      &WkBridgeInbox = unsafe { nil }
	page_ready bool
	eval_ticks int
	pending    []string
	closing    bool
	// Window title sync. pump() runs every ~8 ms, and WKPageCopyTitle() is a
	// synchronous call into the UI process, so poll sparsely and remember what we
	// last showed to avoid redundant WM_SETTEXT messages.
	title_ticks int
	shown_title string
	// Startup timing. Both marks reuse probes we already make, so measuring costs
	// no extra IPC: `page_ready` is the existing readyState poll and the title is
	// polled every ~250 ms anyway. They stay in the code because "why is the shell
	// slow to appear" is the first question any perf change has to answer.
	t0 time.Time
}

// pump() iterations between title polls (~30 x 8 ms = ~250 ms).
const title_poll_ticks = 30

// --- callbacks invoked from the C thunks ------------------------------------
fn wk_on_close(ctx voidptr) {
	mut e := unsafe { &WebKitEngine(ctx) }
	e.closing = true
}

fn wk_on_message(text &char, ctx voidptr) {
	mut e := unsafe { &WebKitEngine(ctx) }
	if e.inbox == unsafe { nil } {
		return
	}
	raw := unsafe { text.vstring() }
	parts := raw.split_any('\x1f')
	name := if parts.len > 0 { parts[0] } else { '' }
	payload := if parts.len > 1 { parts[1..].join('') } else { '' }
	e.inbox.msgs << WkBridgeMsg{
		name:    name
		payload: payload
	}
}

fn wk_on_eval(value voidptr, err_ref voidptr, ctx voidptr) {
	mut box := unsafe { &WkEvalBox(ctx) }
	// Both strings are freshly allocated by wk_host.h; we own them and must free.
	// (The parameter is not named `error`: that is a V builtin.)
	if err_ref != unsafe { nil } {
		p := unsafe { C.wk_type_to_utf8(err_ref) }
		if p != unsafe { nil } {
			box.err = wk_cstr(p)
			C.wk_host_free(p)
		}
	}
	if value != unsafe { nil } {
		p := unsafe { C.wk_type_to_utf8(value) }
		if p != unsafe { nil } {
			box.value = wk_cstr(p)
			C.wk_host_free(p)
		}
	}
	box.done = true
}

// --- Engine interface -------------------------------------------------------

pub fn (mut e WebKitEngine) create_window(title string, url string, width int, height int, dev_mode bool) ! {
	e.t0 = time.now()
	e.title = title
	e.inbox = &WkBridgeInbox{}

	// 1. the frame is ours: WebKit gives us a child view, not a window.
	e.host = C.wk_host_create(title.str, width, height, wk_on_close, voidptr(e))
	if e.host == unsafe { nil } {
		return error('wk_host_create() failed (window could not be created)')
	}
	e.hwnd = C.wk_host_hwnd(e.host)

	// 2. configuration + user content controller + the JS->V channel.
	e.config = C.wk_page_configuration_create()
	if e.config == unsafe { nil } {
		return error('WKPageConfigurationCreate() returned NULL')
	}
	e.ucc = C.wk_user_content_controller_create()
	if e.ucc == unsafe { nil } {
		return error('WKUserContentControllerCreate() returned NULL')
	}
	// Must be registered before the first load: user scripts run at document start.
	C.wk_user_content_controller_add_user_script(e.ucc, vshell_user_script.str)
	C.wk_user_content_controller_add_message_handler(e.ucc, wk_on_message, voidptr(e))
	C.wk_page_configuration_set_user_content_controller(e.config, e.ucc)
	if dev_mode {
		C.wk_page_configuration_set_developer_extras(e.config, 1)
	}

	// 3. the view (RECT by value + parent HWND) and its page.
	e.view = C.wk_host_attach_view(e.host, e.config, width, height)
	if e.view == unsafe { nil } {
		return error('WKViewCreate() returned NULL')
	}
	e.page = C.wk_host_page(e.host)
	if e.page == unsafe { nil } {
		return error('WKViewGetPage() returned NULL')
	}

	e.load_url(url)!
}

pub fn (mut e WebKitEngine) load_url(url string) ! {
	if e.page == unsafe { nil } {
		return error('no page: call create_window() first')
	}
	C.wk_page_load_url(e.page, url.str)
}

pub fn (mut e WebKitEngine) load_html(html string) ! {
	if e.page == unsafe { nil } {
		return error('no page: call create_window() first')
	}
	C.wk_page_load_html(e.page, html.str, c'about:blank')
}

pub fn (mut e WebKitEngine) resize(width int, height int) {
	if e.host != unsafe { nil } {
		C.wk_host_resize_view(e.host, width, height)
	}
}

// run drives the Win32 message pump from V.
//
// Same shape as the Ultralight backend on purpose: the per-frame work
// (bridge tick, CLI evals) happens in V between messages, never inside an
// engine callback. Evaluating JS from inside a WebKit callback re-enters the UI
// process and hangs, which is the WebKit flavour of the deadlock that already
// bit us with ulAppRun()'s update callback.
pub fn (mut e WebKitEngine) run() ! {
	if e.host == unsafe { nil } {
		return error('no window: call create_window() first')
	}
	for {
		if C.wk_host_pump_once(e.host) != 0 {
			break
		}
		e.pump()
		// Wakes on any message, or after 8 ms so the bridge still ticks when idle.
		C.wk_host_wait(e.host, 8)
	}
}

pub fn (mut e WebKitEngine) quit() {
	// Ownership, from the real WebKit/WKView.h (verified, not assumed):
	//
	//   WKViewRef WKViewCreate(RECT, WKPageConfigurationRef, HWND)  <- Create, +1
	//   WKPageRef WKViewGetPage(WKViewRef)                          <- Get, borrowed
	//
	// There is no WKViewRelease: a WKViewRef is released with the generic
	// WKRelease(). And because getters do not transfer ownership, `e.page` belongs
	// to the view and must NOT be released here.
	//
	// Releasing it anyway was the shutdown crash: the page proxy's refcount is
	// held by the view, so our extra release frees it early, and the following
	// WKRelease(view) jumps into the freed WebView ("Unhandled Exception ... at
	// 7ffe...", a constant address each run, right after the page step). The
	// symptom masqueraded as an exit-order problem; the cause was ownership.
	if e.view != unsafe { nil } {
		C.wk_release(e.view)
	}
	// Both were created with a *Create* function, so these two are ours. The view
	// retained them; releasing it first means these are now the last references.
	if e.ucc != unsafe { nil } {
		C.wk_release(e.ucc)
	}
	if e.config != unsafe { nil } {
		C.wk_release(e.config)
	}
	if e.host != unsafe { nil } {
		C.wk_host_destroy(e.host)
		e.host = unsafe { nil }
	}
	e.page = unsafe { nil }
	e.view = unsafe { nil }
	e.ucc = unsafe { nil }
	e.config = unsafe { nil }
	e.inbox = unsafe { nil }
}

// --- bridge -----------------------------------------------------------------

// eval_js keeps the interface synchronous, but WebKit's evaluate is async:
// it pumps the message loop until the callback fires. Do NOT call it from
// inside a WebKit callback (message handler, client): it would re-enter.
pub fn (mut e WebKitEngine) eval_js(script string) !string {
	if e.page == unsafe { nil } {
		return error('no page: call create_window() first')
	}
	mut box := &WkEvalBox{}
	C.wk_page_eval(e.page, script.str, wk_on_eval, voidptr(box))

	deadline := time.now().add(3 * time.second)
	for !box.done {
		if time.now() > deadline {
			return error('eval timed out: ${script}')
		}
		if C.wk_host_pump_once(e.host) != 0 {
			return error('window closed while evaluating: ${script}')
		}
		C.wk_host_wait(e.host, 4)
	}
	if box.err != '' {
		return error('JS exception: ${box.err}')
	}
	return box.value
}

pub fn (mut e WebKitEngine) queue_eval(script string) {
	e.pending << script
}

// pump is the per-iteration bridge tick, driven from V (see run()).
fn (mut e WebKitEngine) pump() {
	if e.page == unsafe { nil } {
		return
	}

	if !e.page_ready {
		// `or` instead of if-optional: the body of the loop stays simple, and a
		// timeout here does not need an else branch.
		rs := e.eval_js('document.readyState') or { '' }
		if rs == 'complete' {
			e.page_ready = true
			eprintln('vshell: page ready (document.readyState) at ${time.since(e.t0).milliseconds()} ms')
		}
	}
	if e.page_ready && e.pending.len > 0 {
		e.eval_ticks++
		// readyState completes on the bare host page; the workbench mounts later,
		// so wait until the body has content (same heuristic as the Ultralight
		// backend) before running the CLI evals.
		body := e.eval_js('document.body ? document.body.innerHTML.length : 0') or { '0' }
		if body.int() > 0 || e.eval_ticks > 1200 {
			for script in e.pending {
				if rv := e.eval_js(script) {
					println('vshell: eval -> ${rv}')
				} else {
					eprintln('vshell: eval failed: ${err}')
				}
			}
			e.pending = []
		}
	}

	// Drain what page script pushed through vshell.post().
	if e.inbox != unsafe { nil } && e.inbox.msgs.len > 0 {
		for m in e.inbox.msgs {
			eprintln('vshell: js->v ${m.name} ${m.payload}')
		}
		e.inbox.msgs = []
	} 

	// Keep the frame's title bar in sync with the page (the workbench sets
	// document.title, so this is what makes the window say something useful
	// instead of a fixed "vshell").
	if e.title_ticks > 0 {
		e.title_ticks--
	} else {
		e.title_ticks = title_poll_ticks
		t := e.page_title()
		if t != '' && t != e.shown_title {
			first := e.shown_title == ''
			e.shown_title = t
			C.wk_host_set_title(e.host, t.str)
			if first {
				// The workbench sets document.title once it has mounted, so this is
				// the "shell is actually usable" moment, not just "HTML arrived".
				eprintln("vshell: workbench title set at ${time.since(e.t0).milliseconds()} ms -> '${t}'")
			}
		}
	}
}

// --- inspector / devtools ---------------------------------------------------

// WinCairo has no WebKitGTK-style remote inspector server. The real Web
// Inspector is available locally, which is strictly better than Ultralight's
// Free edition (where the remote server returns false).
pub fn (mut e WebKitEngine) start_remote_inspector(port int) bool {
	return false
}

// show_inspector opens WebKit's Inspector: docked when `attached`, in its own
// window when not. Wire `--devtools` to this.
pub fn (mut e WebKitEngine) show_inspector(attached bool) bool {
	if e.page == unsafe { nil } {
		return false
	}
	return C.wk_page_show_inspector(e.page, if attached { 1 } else { 0 }) != 0
}

pub fn (mut e WebKitEngine) inspector_visible() bool {
	if e.page == unsafe { nil } {
		return false
	}
	return C.wk_page_inspector_is_visible(e.page) != 0
}

// title/url are polled the same way the Ultralight backend polled the page:
// WKPageCopyTitle/WKPageCopyActiveURL are synchronous getters. Move to
// WKPageSetPageNavigationClient if you want push events.
pub fn (mut e WebKitEngine) page_title() string {
	if e.page == unsafe { nil } {
		return ''
	}
	p := C.wk_page_copy_title(e.page)
	if p == unsafe { nil } {
		return ''
	}
	s := wk_cstr(p)
	// wk_page_copy_title returns a char* that wk_type_to_utf8 malloc'd for us, so
	// free() here is right. (Do NOT WKRelease it: it is not a WKStringRef.
	// The WKStringRef that WKPageCopyTitle itself returns is what wk_type_to_utf8
	// takes and should release -- see the leak note there.)
	C.wk_host_free(p)
	return s
}

pub fn (mut e WebKitEngine) page_url() string {
	if e.page == unsafe { nil } {
		return ''
	}
	p := C.wk_page_copy_url(e.page)
	if p == unsafe { nil } {
		return ''
	}
	s := wk_cstr(p)
	// Same as page_title(): the returned char* is ours to free.
	C.wk_host_free(p)
	return s
}
