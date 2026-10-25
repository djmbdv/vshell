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
import json2
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

// COM + shell for wk_host_pick_folder (IFileOpenDialog -> ole32/shell32,
// CLSID_FileOpenDialog -> uuid). Unrelated to WebKit; kept here because this
// module is the only one that compiles the Win32 C glue.
#flag -lole32 -loleaut32 -luuid -lshell32

// --- what wk_host.h exposes to V (all handles are void*) ---------------------
fn C.wk_host_create(title &char, width int, height int, on_close WkCloseCb, ctx voidptr) voidptr
fn C.wk_host_hwnd(state voidptr) voidptr
fn C.wk_host_attach_view(state voidptr, page_configuration voidptr, width int, height int) voidptr
fn C.wk_host_page(state voidptr) voidptr
fn C.wk_host_view(state voidptr) voidptr
fn C.wk_host_resize_view(state voidptr, width int, height int)
fn C.wk_host_set_title(state voidptr, title &char)
fn C.wk_host_enable_state_notifications(state voidptr) int
fn C.wk_host_take_state_flags(state voidptr) int
fn C.wk_host_wait(state voidptr, ms int)
fn C.wk_host_pump_once(state voidptr) int
fn C.wk_host_destroy(state voidptr)
fn C.wk_host_pick_folder(parent voidptr) voidptr
fn C.wk_host_menu_create() voidptr
fn C.wk_host_menu_add_item(menu voidptr, id int, label &char)
fn C.wk_host_menu_add_submenu(menu voidptr, label &char) voidptr
fn C.wk_host_menu_add_separator(menu voidptr)
fn C.wk_host_set_command_cb(state voidptr, cb WkMenuCb, ctx voidptr)
fn C.wk_host_set_menu_bar(state voidptr, bar voidptr)
fn C.wk_host_close_window(state voidptr)
fn C.wk_host_message_box(state voidptr, title &char, text &char)

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
fn C.wk_page_reload(page voidptr)
fn C.wk_host_free(p voidptr)

fn C.wk_page_show_inspector(page voidptr, attached int) int
fn C.wk_page_inspector_is_visible(page voidptr) int
fn C.wk_release(ref voidptr)

// --- callback signatures ----------------------------------------------------
type WkCloseCb = fn (ctx voidptr)
type WkMsgCb = fn (text &char, ctx voidptr)
type WkEvalCb = fn (value voidptr, err_ref voidptr, ctx voidptr)
type WkMenuCb = fn (id int, ctx voidptr)

// First id the shell uses for its own menu items. Mirrors WK_MENU_ID_BASE in
// engine/wk_host.h.
const wk_menu_id_base = 40000

// Mirrors WK_STATE_* in engine/wk_host.h: the bits wk_host_take_state_flags()
// returns for page changes that arrived since the previous pump tick. There is
// no loading bit on purpose: the C API reports that loading changed but has no
// getter for the direction (see wk_host.h).
const (
	wk_state_title = 1
	wk_state_url   = 2
)

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
//
// The script is NOT a const any more: it carries the shell's session token and
// the folder it opened, which are per-run. See build_user_script().
const vshell_user_script_head = '
(function () {
	// Idempotent: the shell injects this twice on purpose — as a WKUserScript at
	// document start, and again by evaluation after the load, because a page with a
	// strict Content-Security-Policy (vscode-reh-web sends one) blocks the inline
	// injection and would otherwise leave the page with no bridge at all.
	if (window.vshell) { return; }
	var pending = {}, seq = 0;
	window.vshell = Object.freeze({
		version: "vshell-bridge-wk",
		post: (name, payload) => window.webkit.messageHandlers.vshell.postMessage(
			String(name) + "\u001f" + (payload === undefined ? "" : String(payload))),
		// Request/response over the one-way post() channel: the page sends a call
		// with an id, the shell answers later through __resolve(). The id and the
		// pending resolvers live in this closure, not on the frozen object, so the
		// object stays immutable while the machinery behind it does not.
		call: function (method, args) {
			return new Promise(function (resolve) {
				var id = "r" + (++seq);
				pending[id] = resolve;
				window.vshell.post("vshell.call", JSON.stringify({ id: id, method: method, args: args || [] }));
			});
		},
		dialog: {
			openFolder: function () { return window.vshell.call("dialog.openFolder"); },
		},
		__resolve: function (id, value) {
			var r = pending[id];
			if (r) { delete pending[id]; r(value); }
		},
	});
})();
'

// The bootstrap tail is appended to the head above. It is delivered to the page
// as a WKUserScript at document start, so unlike everything the Bun server
// serves it never appears in an HTTP response another local process could fetch
// — the token only reaches a context the engine itself injected. The page then
// re-broadcasts it on a same-origin BroadcastChannel, which is how the extension
// host worker (which has no `window`) gets it. See extensions/codebun-backend.
const vshell_user_script_tail = '
(function () {
	if (window.__codebunBootstrap) { return; }
	// Last-resort diagnostics for the shell: the engine has no console hook in the
	// C API (console messages need an injected bundle), so errors are collected here
	// and read back with --eval and JSON.stringify(window.__codebunErrors). A page
	// that renders but silently fails to do something (the remote connection, for
	// one) is otherwise indistinguishable from a working one. No quote characters in
	// this comment: it lives inside a V single-quoted string literal.
	window.__codebunErrors = [];
	window.addEventListener("error", function (e) {
		try { window.__codebunErrors.push("error: " + (e.message || e.error || e)); } catch (err) {}
	});
	window.addEventListener("unhandledrejection", function (e) {
		try {
			var r = e && e.reason;
			window.__codebunErrors.push("rejection: " + ((r && (r.stack || r.message)) || String(r)));
		} catch (err) {}
	});
	var boot = { token: "%TOKEN%", folder: "%FOLDER%" };
	window.__codebunBootstrap = boot;
	// One dialog at a time, per request id. The extension re-sends its request
	// every 250 ms until it gets a reply, because a BroadcastChannel has no replay
	// and either side may have started late. Without this, every retry while the
	// (modal!) folder dialog is open would queue another dialog.
	var picking = {};
	try {
		var bc = new BroadcastChannel("codebun-bootstrap");
		bc.onmessage = function (ev) {
			var d = ev && ev.data;
			if (!d) return;
			if (d.type === "codebun:hello") {
				bc.postMessage({ type: "codebun:bootstrap", token: boot.token, folder: boot.folder });
			} else if (d.type === "codebun:pickFolder") {
				if (picking[d.id]) return;
				picking[d.id] = true;
				window.vshell.dialog.openFolder().then(function (f) {
					delete picking[d.id];
					bc.postMessage({ type: "codebun:folderPicked", id: d.id, folder: f || "" });
				});
			}
		};
		// Native menu -> workbench. The shell owns the menu and forwards the
		// commands it does not handle itself (see run_menu_command in webkit.v); the
		// extension maps them to VS Code commands. Published as a global because the
		// engine evaluates it from outside this closure.
		window.__codebunMenu = function (command) {
			try { bc.postMessage({ type: "codebun:menu", command: String(command) }); } catch (err) {}
		};
		bc.postMessage({ type: "codebun:bootstrap", token: boot.token, folder: boot.folder });
	} catch (err) {}
})();
'

// escape_for_js_string makes a value safe inside a double-quoted JS string
// literal (the token and the folder path are interpolated into the tail above).
// Only the bytes that would end the literal or break the source are escaped:
// '\\' and '"' get a backslash, the usual whitespace gets its short form, and
// other control bytes are dropped. Bytes >= 0x20 pass through untouched, so a
// UTF-8 path stays UTF-8 — which is what WKStringCreateWithUTF8CString wants.
fn escape_for_js_string(s string) string {
	mut out := []u8{cap: s.len + 8}
	for c in s.bytes() {
		if c == 92 { // backslash
			out << u8(92)
			out << u8(92)
		} else if c == 34 { // double quote
			out << u8(92)
			out << u8(34)
		} else if c == 10 { // newline
			out << u8(92)
			out << u8(110)
		} else if c == 13 { // carriage return
			out << u8(92)
			out << u8(114)
		} else if c == 9 { // tab
			out << u8(92)
			out << u8(116)
		} else if c >= 32 {
			out << c
		}
	}
	return out.bytestr()
}

// pick_folder_owned is the one place that calls the C dialog. `parent` is the
// owner HWND: NULL for the startup prompt (no window yet), the frame's HWND for
// an on-demand call so the dialog is properly modal to it.
fn pick_folder_owned(parent voidptr) ?string {
	p := C.wk_host_pick_folder(parent)
	if p == unsafe { nil } {
		return none
	}
	defer {
		C.wk_host_free(p)
	}
	s := wk_cstr(p)
	if s == '' {
		return none
	}
	return s
}

// pick_folder shows the shell's native "choose a folder" dialog and returns the
// chosen absolute path, or none when the user cancelled. Module-level (not an
// Engine method) because it needs no engine state, and the shell calls it before
// the window — and so before the engine — exists. There is no window to own the
// dialog yet, so it is unowned (the on-demand path passes the HWND instead).
pub fn pick_folder() ?string {
	return pick_folder_owned(unsafe { nil })
}

// VsCall is the request half of the page -> shell call protocol: the page sends
// this as JSON under the name "vshell.call" (see vshell_user_script_head).
struct VsCall {
	id     string
	method string
	args   []string
}

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
	// Window title/URL sync. WebKit pushes changes through the page state client
	// (wk_host_enable_state_notifications), so pump() only drains a bitmask and
	// reads the values then -- but it still reads them with the Copy* getters, and
	// `shown_*` keeps WM_SETTEXT from repeating on every tick.
	state_flags int
	shown_title string
	shown_url   string
	// Fallback for a build where the state client is unavailable: poll the title
	// every `title_poll_ticks` ticks instead of waiting for a push.
	poll_title  bool
	title_ticks int
	// Startup timing. Both marks reuse probes we already make, so measuring costs
	// no extra IPC: `page_ready` is the existing readyState poll and the title is
	// polled every ~250 ms anyway. They stay in the code because "why is the shell
	// slow to appear" is the first question any perf change has to answer.
	t0 time.Time

	// Per-run values handed to the page as a user script (build_user_script):
	// the shell's session token for the Bun backend, and the folder the user
	// opened. Both default to '' — with no token the backend stays open, which is
	// only meant for standalone development.
	boot_token  string
	boot_folder string

	// Menu: Win32 gives items integer ids, so the shell's command strings are
	// mapped through this table. `pending_menu` is what WM_COMMAND produced and
	// pump() has not dispatched yet — a message handler must not run shell logic
	// that evaluates JS, so it only records the command here.
	menu_commands map[int]string
	pending_menu  string
	// bridge_injected tracks the by-evaluation injection for the current document.
	// The WKUserScript covers the common case, but a page with a strict CSP
	// (vscode-reh-web) blocks inline user scripts, so the pump injects again after
	// the load; the script itself is idempotent. Reset on every navigation.
	bridge_injected bool
}

// pump() iterations between title polls (~30 x 8 ms = ~250 ms). Only used when
// the page state client is unavailable; with push events there is nothing to
// poll.
const title_poll_ticks = 30

// What Help > About shows. A const so the text does not have to be a C literal
// with hand-escaped newlines at the call site.
const about_text = 'vshell - a V shell for the VS Code web build.\n\nRenderer: WebKit (WinCairo), JavaScriptCore\nServer: Bun, JavaScriptCore'

// --- callbacks invoked from the C thunks ------------------------------------
fn wk_on_close(ctx voidptr) {
	mut e := unsafe { &WebKitEngine(ctx) }
	e.closing = true
}

fn wk_on_menu(id int, ctx voidptr) {
	mut e := unsafe { &WebKitEngine(ctx) }
	// WM_COMMAND arrives inside wk_host_pump_once(), which may itself be running
	// inside eval_js(). Recording a string is all that is safe here; pump() does
	// the dispatch.
	e.pending_menu = e.menu_commands[id] or { '' }
	if e.pending_menu == '' {
		eprintln('vshell: unknown menu id ${id}')
	}
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
	// `err_ref` is always NULL in this API, so it is not converted: WebKit's
	// WKPageEvaluateJavaScriptInFrame ends with
	//     if (result) callback(toAPI(...), nullptr, context);
	//     else        callback(nullptr, nullptr, context);
	// (Source/WebKit/UIProcess/API/C/WKPage.cpp). A syntax error, a thrown
	// exception and a cancelled evaluation are therefore indistinguishable here,
	// which is why eval_js_checked() catches inside the script instead.
	ignore := err_ref
	if ignore != unsafe { nil } {
		eprintln('vshell: note: WebKit reported an eval error reference, which the API is not documented to do')
	}
	// The string is freshly allocated by wk_host.h; we own it and must free.
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

// set_bootstrap records what the page will be told through the injected user
// script. Call it BEFORE create_window: the script is registered there and runs
// at document start, so a later value would miss the first document.
pub fn (mut e WebKitEngine) set_bootstrap(token string, folder string) {
	e.boot_token = token
	e.boot_folder = folder
}

// build_user_script renders the page-side bridge for this run: the frozen
// vshell object plus the bootstrap tail carrying the token and the folder.
fn (e WebKitEngine) build_user_script() string {
	tail := vshell_user_script_tail
		.replace('%TOKEN%', escape_for_js_string(e.boot_token))
		.replace('%FOLDER%', escape_for_js_string(e.boot_folder))
	script := vshell_user_script_head + tail
	// A truncated bridge fails SILENTLY — the page simply has no `window.vshell`,
	// and the only symptom is every call answering undefined. That happened once:
	// a comment inside one of the string literals above contained two single quotes,
	// which ended the V string early and dropped the rest of the script on the
	// floor, with no compile error. The shape is cheap to assert.
	if !script.trim_space().ends_with('})();') {
		eprintln('vshell: WARNING injected bridge script looks truncated (len=${script.len}); check for a stray quote in engine/webkit.v')
	}
	return script
}

// --- menu -------------------------------------------------------------------

// set_menu_bar builds the Win32 menu from the shell's items and installs it.
// Call it after create_window(): the bar belongs to the frame the engine created,
// and Windows destroys it with that window (so nothing here is freed by hand).
pub fn (mut e WebKitEngine) set_menu_bar(items []MenuItem) bool {
	if e.host == unsafe { nil } {
		return false
	}
	bar := C.wk_host_menu_create()
	if bar == unsafe { nil } {
		return false
	}
	e.menu_commands = map[int]string{}
	e.add_menu_items(bar, items, wk_menu_id_base)
	C.wk_host_set_command_cb(e.host, wk_on_menu, voidptr(e))
	C.wk_host_set_menu_bar(e.host, bar)
	return true
}

// add_menu_items fills `menu` and returns the first id it did NOT use, so a
// nested submenu can continue the numbering (V has no `mut` params for ints).
fn (mut e WebKitEngine) add_menu_items(menu voidptr, items []MenuItem, start_id int) int {
	mut next_id := start_id
	for item in items {
		if item.separator {
			C.wk_host_menu_add_separator(menu)
			continue
		}
		if item.children.len > 0 {
			sub := C.wk_host_menu_add_submenu(menu, item.label.str)
			if sub != unsafe { nil } {
				next_id = e.add_menu_items(sub, item.children, next_id)
			} else {
				eprintln('vshell: could not add the submenu "${item.label}"')
			}
			continue
		}
		id := next_id
		next_id++
		e.menu_commands[id] = item.command
		C.wk_host_menu_add_item(menu, id, item.label.str)
	}
	return next_id
}

// run_menu_command is the one place a chosen item turns into behaviour. Called
// from pump(), never from the WM_COMMAND handler (see wk_on_menu).
fn (mut e WebKitEngine) run_menu_command(command string) {
	match command {
		'app.quit' {
			C.wk_host_close_window(e.host)
		}
		'view.reload' {
			C.wk_page_reload(e.page)
		}
		'view.devtools' {
			if !e.show_inspector(false) {
				eprintln('vshell: this engine has no inspector')
			}
		}
		'help.about' {
			C.wk_host_message_box(e.host, c'About vshell', about_text.str)
		}
		else {
			// Everything else belongs to the workbench: it is the side that knows
			// what the command means (the extension listens for it on the
			// bootstrap BroadcastChannel).
			e.eval_js('window.__codebunMenu ? window.__codebunMenu(${json2.encode(command)}) : undefined') or {
				eprintln('vshell: could not deliver the menu command "${command}": ${err}')
			}
		}
	}
}

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
	C.wk_user_content_controller_add_user_script(e.ucc, e.build_user_script().str)
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

	// Title/URL arrive as push events from here on. If this build of the engine
	// cannot install the client, fall back to the sparse poll in pump().
	e.poll_title = C.wk_host_enable_state_notifications(e.host) == 0

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
		// The wait wakes on any message; the timeout only matters when the page is
		// silent. It has to be short while the shell itself has queued work — page
		// not ready, CLI evals pending, or the title-poll fallback — and can be long
		// otherwise: user input arrives as a Win32 message, which wakes
		// MsgWaitForMultipleObjectsEx immediately, so a slow tick costs no
		// responsiveness. Measured before this: 8 ms forever = 125 wakeups/s and
		// ~4.5 % of a core on an idle window.
		idle := !e.page_ready || e.pending.len > 0 || e.poll_title
		C.wk_host_wait(e.host, if idle { 8 } else { 200 })
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

// eval_error_marker prefixes a result that came back from eval_js_checked() as a
// caught exception. A control byte, so it cannot collide with a real string a
// caller would want.
const eval_error_marker = '\u0001'

// eval_js_checked is eval_js with the two things a human running `--eval` needs:
// exceptions become errors (WebKit will not tell us — see wk_on_eval), and a
// non-string value is JSON-encoded instead of silently arriving as ''.
//
// The wrapping is also why the script must be passed as ONE argument: on Windows
// a value with spaces is split by the command line, so the shell only receives the
// first word and the wrapper then reports a syntax error that names the fragment.
fn (mut e WebKitEngine) eval_js_checked(script string) !string {
	wrapped := "(function(){try{var v=eval(${json2.encode(script)});" +
		"if(typeof v==='string')return v;" +
		"if(v===undefined)return 'undefined';" +
		"try{return JSON.stringify(v)}catch(e2){return String(v)}}" +
		"catch(err){return '\\u0001'+String((err&&err.name?err.name+': '+(err.message||''):'')||err)}})()"
	rv := e.eval_js(wrapped)!
	if rv.starts_with(eval_error_marker) {
		return error(rv[eval_error_marker.len..])
	}
	return rv
}

pub fn (mut e WebKitEngine) queue_eval(script string) {
	e.pending << script
}

// pump is the per-iteration bridge tick, driven from V (see run()).
fn (mut e WebKitEngine) pump() {
	if e.page == unsafe { nil } {
		return
	}

	// A menu item chosen since the last tick. Dispatched here rather than in the
	// WM_COMMAND handler because run_menu_command evaluates JS, and doing that
	// from inside a Win32 callback re-enters the engine.
	if e.pending_menu != '' {
		command := e.pending_menu
		e.pending_menu = ''
		e.run_menu_command(command)
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
	// Second chance for the bridge. A page served with a strict CSP blocks the
	// document-start user script (the injection is inline and carries no nonce), so
	// the page would come up with no `window.vshell`, no bootstrap and no error
	// collector — which is exactly what vscode-reh-web did. Evaluating the same
	// script is not subject to CSP. The script returns early if it already ran, so
	// the normal case pays one cheap call and nothing else.
	//
	// This runs BEFORE the queued evals below on purpose: those are the user's
	// `--eval` scripts and they should be able to see the bridge.
	if e.page_ready && !e.bridge_injected {
		e.bridge_injected = true
		if res := e.eval_js(e.build_user_script()) {
			_ := res
		} else {
			eprintln('vshell: bridge injection failed: ${err}')
			e.bridge_injected = false
		}
	}
	if e.page_ready && e.pending.len > 0 {
		e.eval_ticks++
		// readyState completes on the bare host page, long before the workbench
		// exists, so the CLI evals wait for a page that has both content and a title
		// of its own. For this shell that moment is "the workbench mounted", which is
		// what `--eval 'document.title'` is supposed to observe. A page without a
		// title would never satisfy it (--url can point at any page now), so time is
		// also an escape hatch: 4 s after the body appeared, run them anyway.
		//
		// The probe returns a STRING on purpose: eval_js only converts WKString
		// results (wk_type_to_utf8), so a bare boolean or `.length` would come
		// back as '' and the check could never pass — it would silently fall
		// through to the tick cap, which is what made `--eval` look like it did
		// nothing for a minute.
		body := e.eval_js('document.body && document.body.innerHTML.length > 0 && (document.title || ' +
			'((window.__vshellEvalDeadline = window.__vshellEvalDeadline || Date.now() + 4000) && Date.now() > window.__vshellEvalDeadline)' +
			') ? "1" : "0"') or { '0' }
		if body.int() > 0 || e.eval_ticks > 1200 {
			for script in e.pending {
				if rv := e.eval_js_checked(script) {
					println('vshell: eval -> ${rv}')
				} else {
					// The script goes into the message: on Windows a `--eval` value
					// with spaces is split by the command line, so what arrives here
					// is often the first word only ("typeof"). Printing it turns a
					// mystifying empty result into an obvious one.
					eprintln('vshell: eval failed: ${err} (script: ${script})')
				}
			}
			e.pending = []
		}
	}

	// Drain what page script pushed through vshell.post().
	//
	// The inbox is swapped out before it is walked, not walked and then cleared:
	// handle_call() evaluates JS, and evaluating JS pumps messages, which can run
	// wk_on_message() again and push NEW entries onto e.inbox.msgs. Iterating the
	// live array while it grows is the kind of bug that shows up later as a skipped
	// or duplicated call, so the snapshot is taken first.
	if e.inbox != unsafe { nil } && e.inbox.msgs.len > 0 {
		msgs := e.inbox.msgs
		e.inbox.msgs = []
		for m in msgs {
			if m.name == 'vshell.call' {
				e.handle_call(m.payload)
			} else {
				eprintln('vshell: js->v ${m.name} ${m.payload}')
			}
		}
	}

	// Keep the frame's title bar in sync with the page (the workbench sets
	// document.title, so this is what makes the window say something useful
	// instead of a fixed "vshell"). With the state client the change arrives as a
	// push event; without it, poll every ~250 ms. Either way the value is read
	// HERE, on the pump tick, never inside the WebKit callback.
	flags := C.wk_host_take_state_flags(e.host)
	mut title_dirty := flags & wk_state_title != 0
	if e.poll_title {
		if e.title_ticks > 0 {
			e.title_ticks--
		} else {
			e.title_ticks = title_poll_ticks
			title_dirty = true
		}
	}
	if title_dirty {
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
	if flags & wk_state_url != 0 {
		u := e.page_url()
		if u != '' && u != e.shown_url {
			// Logged on purpose: a page that silently reloads itself is the failure
			// mode that cost the most time in Phase 2, and this is the cheapest
			// signal that it is happening.
			eprintln('vshell: url -> ${u}')
			e.shown_url = u
			// New document: the by-evaluation injection has to happen again.
			e.bridge_injected = false
		}
	}
}

// handle_call answers one request/response call from the page.
//
// It runs on the pump tick, never inside a WebKit callback: showing a modal
// dialog or evaluating JS from wk_on_message would re-enter the UI process and
// hang — the rule the whole bridge follows. By the time this runs the message has
// already been queued and the callback has returned.
fn (mut e WebKitEngine) handle_call(payload string) {
	call := json2.decode[VsCall](payload) or {
		eprintln('vshell: ignoring malformed call payload: ${payload}')
		return
	}
	match call.method {
		'dialog.openFolder' {
			// Owned by the frame now that there is one, so it is modal to it.
			path := pick_folder_owned(e.hwnd) or { '' }
			e.resolve_call(call.id, json2.encode(path))
		}
		else {
			eprintln('vshell: unknown vshell call "${call.method}"')
			// Resolve with null so the caller's promise does not hang: a Promise
			// that never settles is worse than one that resolves to "unsupported".
			e.resolve_call(call.id, 'null')
		}
	}
}

// resolve_call hands a result back to the page's pending promise. Both the id
// and the value are JSON-encoded: a JSON string is also a valid JS string
// literal, so a Windows path's backslashes arrive escaped correctly, which the
// hand-quoting this replaced would have got wrong.
fn (mut e WebKitEngine) resolve_call(id string, value_json string) {
	script := 'window.vshell.__resolve(${json2.encode(id)}, ${value_json})'
	e.eval_js(script) or { eprintln('vshell: could not resolve call ${id}: ${err}') }
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
