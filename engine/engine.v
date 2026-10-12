module engine

// Engine abstracts the HTML/JS rendering backend so the shell logic never
// depends on a concrete runtime.
//
//   ultralight.v      -> WebKit + JavaScriptCore (Ultralight C API)  [objetivo]
//   system_webview.v  -> system webview fallback (WebKitGTK / WKWebView / WebView2)
//
// TODO: refine the surface once the Ultralight binding is real (events, JS eval,
// custom scheme handlers, CSD/titlebar hooks).
pub interface Engine {
mut:
	// create_window opens the top-level window pointing at `url`. dev_mode turns
	// on the engine's developer diagnostics (and is needed for the inspector).
	create_window(title string, url string, width int, height int, dev_mode bool) !
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
	// start_remote_inspector starts the DevTools server; false when unsupported.
	start_remote_inspector(port int) bool
}

// new_engine returns an Engine implementation by name.
//
// The system-webview fallback (engine/system_webview.v.disabled) is disabled:
// `ttytm.webview` v0.7.0 still uses the legacy `src/` layout, which V 0.5.2 no
// longer supports, and building its C library needs a C++ toolchain.
pub fn new_engine(kind string) !Engine {
	if kind == 'ultralight' {
		mut e := UltralightEngine{}
		return Engine(e)
	}
	return error('unknown engine "${kind}" (available: ultralight)')
}
