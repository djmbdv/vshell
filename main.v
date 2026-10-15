module main

import os
import engine

// vshell entrypoint.
//
// Flow:
//   1. start the Bun web server (serves the vscode-web build)
//   2. wait until it is actually listening
//   3. open the engine window pointing at http://127.0.0.1:<port>/
//   4. run the engine loop
//   5. tear everything down on exit (including the Bun child)
//
// See ROADMAP.md. Phases 0/1 were validated on the Ultralight backend, which
// Phase 1b replaced: the workbench now boots inside WebKit (the WinCairo port),
// same JavaScriptCore family, no V8 anywhere.

const default_port = 8123
const default_web_root = 'web/public'
const serve_script = 'web/serve.js'

struct Options {
mut:
	engine_kind string = 'webkit'
	port        int    = default_port
	web_root    string = default_web_root
	dev_mode    bool
	// evals are JS snippets run in the page once it is live (a way to poke the
	// bridge from the CLI without any UI).
	evals       []string
}

fn main() {
	// Keep the exit-code dance out of main so the `defer` below actually runs on
	// error paths too (exit() would skip it).
	code := run() or {
		eprintln('vshell: ${err}')
		1
	}
	exit(code)
}

fn run() !int {
	opts := parse_args(os.args)

	mut server := start_web_server(serve_script, opts.web_root, opts.port)!
	defer {
		server.stop()
	}
	println('vshell: web server pid=${server.pid} port=${server.port}')

	// The view must not load before Bun accepts connections, or the host page
	// 404s and the workbench never mounts.
	if !server.wait_until_listening(10_000) {
		return error('the web server never started listening on port ${opts.port}')
	}

	mut eng := engine.new_engine(opts.engine_kind)!
	url := 'http://127.0.0.1:${opts.port}/'
	eng.create_window('vshell', url, 1280, 800, opts.dev_mode)!

	if opts.dev_mode {
		// Ultralight Free has no remote inspector, and WebKit/WinCairo has no remote
		// server either — but it does have the real Web Inspector.
		if eng.start_remote_inspector(9222) {
			println('vshell: remote inspector on inspector://127.0.0.1:9222')
		} else if eng.show_inspector(false) {
			println('vshell: Web Inspector opened in its own window')
		} else {
			println('vshell: no inspector available for this engine')
		}
	}

	// Deferred: run() blocks until the window closes, so these run from the
	// per-frame bridge tick once the page is live.
	for script in opts.evals {
		eng.queue_eval(script)
	}

	eng.run()!
	eng.quit()

	println('vshell: bye')
	return 0
}

fn parse_args(args []string) Options {
	mut opts := Options{}
	mut i := 1
	for i < args.len {
		match args[i] {
			'--engine' {
				if i + 1 < args.len {
					opts.engine_kind = args[i + 1]
					i += 2
				} else {
					i++
				}
			}
			'--port' {
				if i + 1 < args.len {
					opts.port = args[i + 1].int()
					i += 2
				} else {
					i++
				}
			}
			'--web-root' {
				if i + 1 < args.len {
					opts.web_root = args[i + 1]
					i += 2
				} else {
					i++
				}
			}
			'--devtools' {
				opts.dev_mode = true
				i++
			}
			'--eval' {
				if i + 1 < args.len {
					opts.evals << args[i + 1]
					i += 2
				} else {
					i++
				}
			}
			else {
				i++
			}
		}
	}
	return opts
}
