module engine

// Engine abstracts the HTML/JS rendering backend so the shell logic never
// depends on a concrete runtime.
//
//   webkit.v                  -> WebKit upstream, WinCairo port (WebKit2 C API)  [objetivo]
//   ultralight.v.disabled     -> WebKit + JavaScriptCore (Ultralight C API)      [legacy, off]
//   system_webview.v.disabled -> system webview fallback (WebKitGTK / WKWebView / WebView2)
//
// TODO: refine the surface as the backends grow (resize/DPI, navigation events,
// custom scheme handlers, CSD/titlebar hooks).
pub interface Engine {
mut:
	// create_window opens the top-level window pointing at `url`. dev_mode turns
	// on the engine's developer diagnostics (and is needed for the inspector).
	create_window(title string, url string, width int, height int, dev_mode bool) !
	// set_bootstrap hands the page the shell's session data — the backend token
	// and the folder the user opened — before it loads. Out-of-band by design:
	// the WebKit backend injects it as a user script, never through a URL or an
	// HTTP response the page could be tricked into re-fetching. Both may be
	// empty, which is the standalone/dev case.
	set_bootstrap(token string, folder string)
	// load_url navigates the current window.
	load_url(url string) !
	// run blocks until the last window is closed.
	run() !
	// quit asks the engine to shut down cleanly.
	quit()
	// eval_js runs a script in the page and returns its value as a string.
	eval_js(script string) !string
	// queue_eval defers a script until the page is live (the run loop is blocking,
	// so scripts cannot be evaluated straight after create_window).
	queue_eval(script string)
	// start_remote_inspector starts a remote DevTools server; false when the
	// engine has none (the WebKit/WinCairo backend has no such server).
	start_remote_inspector(port int) bool
	// show_inspector opens the engine's built-in inspector. `attached` docks it
	// inside the page; false opens it in its own window. False when unsupported.
	show_inspector(attached bool) bool
}

// new_engine returns an Engine implementation by name.
//
// The system-webview fallback (engine/system_webview.v.disabled) is disabled:
// `ttytm.webview` v0.7.0 still uses the legacy `src/` layout, which V 0.5.2 no
// longer supports, and building its C library needs a C++ toolchain.
//
// The Ultralight backend is disabled for a mechanical reason, not a taste one:
// engine/ultralight.v declared unconditional `#flag -lAppCore -lUltralight
// -lUltralightCore -lWebCore` lines, so merely having the file inside the
// module made EVERY link require the Ultralight SDK, even when the WebKit
// engine was the one in use, and there is no way to make a #flag conditional on
// backend selection. Renaming it to .disabled (the same convention
// system_webview.v already uses) removes it from the build and keeps it one
// `mv` away if the SDK comes back.
pub fn new_engine(kind string) !Engine {
	if kind == 'webkit' {
		mut e := WebKitEngine{}
		return Engine(e)
	}
	return error('unknown engine "${kind}" (available: webkit)')
}
