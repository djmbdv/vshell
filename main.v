module main

import os
import rand
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
	// folder is the workspace to open. --folder sets it directly; --open-folder
	// asks the OS for it with the native dialog. Both feed the page bootstrap,
	// so the workbench opens the folder without a reload.
	folder      string
	open_folder bool
	// url points the window at a server this process did NOT start (an
	// already-running `vscode-reh-web`, a remote workspace, a static host). When
	// set, no Bun child is spawned and --port/--web-root are ignored.
	url         string
	// reh is the base URL of a `vscode-reh-web` to proxy. The shell then owns the
	// origin (serving everything and terminating the WebSocket) and forwards to it —
	// the REH's own `node:http` upgrade does not survive under Bun with our WebKit.
	reh         string
	// evals are JS snippets run in the page once it is live (a way to poke the
	// bridge from the CLI without any UI).
	evals       []string
}

// new_token returns a 256-bit session token as hex. It gates the Bun backend so
// a process other than this shell cannot drive the file-system service (see
// web/backend.js). rand.intn is used instead of a dedicated CSPRNG call so this
// keeps working across V versions; 32 uniform bytes are well past enough for a
// loopback token that only lives for one run.
fn new_token() string {
	hex_digits := '0123456789abcdef'
	mut out := []u8{cap: 64}
	for _ in 0 .. 32 {
		n := rand.intn(256) or { 0 }
		out << hex_digits[n >> 4]
		out << hex_digits[n & 0xf]
	}
	return out.bytestr()
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

	// The session token gates the Bun backend. The Bun child is spawned from this
	// process (start_web_server), so it inherits the value through the
	// environment; the page then receives it out-of-band, in the engine's user
	// script (see set_bootstrap). It is never written to disk and never put in a
	// URL.
	token := new_token()
	os.setenv('VSHELL_TOKEN', token, true)

	// Pick the workspace before the window exists: the engine injects it into the
	// page as a document-start user script, so it must be known up front. A
	// native dialog with no owner still works, it is just not docked modally.
	mut folder := opts.folder
	if folder == '' && opts.open_folder {
		if chosen := engine.pick_folder() {
			folder = chosen
		} else {
			println('vshell: no folder chosen (starting without a workspace)')
		}
	}

	mut server := WebServer{}
	if opts.url == '' {
		extra := if opts.reh != '' { ['--upstream', opts.reh] } else { []string{} }
		server = start_web_server(serve_script, opts.web_root, opts.port, extra)!
		println('vshell: web server pid=${server.pid} port=${server.port}')
		if opts.reh != '' {
			println('vshell: proxying to ${opts.reh}')
		}

		// The view must not load before Bun accepts connections, or the host page
		// 404s and the workbench never mounts.
		if !server.wait_until_listening(10_000) {
			return error('the web server never started listening on port ${opts.port}')
		}
	} else {
		// Nothing to wait for: --url means somebody else owns the server.
		println('vshell: loading ${opts.url} (no server started)')
	}
	defer {
		server.stop()
	}

	mut eng := engine.new_engine(opts.engine_kind)!
	eng.set_bootstrap(token, folder)
	url := if opts.url != '' { opts.url } else { 'http://127.0.0.1:${opts.port}/' }
	eng.create_window('vshell', url, 1280, 800, opts.dev_mode)!

	// The shell's own chrome: a real Win32 menu bar, drawn and owned by the OS.
	// The engine dispatches what it can handle itself (quit, reload, inspector,
	// about) and forwards the rest to the workbench (see engine.MenuItem).
	if !eng.set_menu_bar(build_menu()) {
		println('vshell: this engine has no native menu bar')
	}

	if folder != '' {
		println('vshell: folder ${folder}')
	}

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

// build_menu is the shell's chrome, written in the shell's vocabulary: a label
// and a command per item, never a callback. Which side handles a command is
// documented on engine.MenuItem — the short version is that the engine owns
// quit/reload/inspector/about and everything else goes to the workbench, which
// maps it to a VS Code command (extensions/codebun-backend).
//
// The `&` is the Win32 mnemonic (Alt+F). There is no accelerator table yet, so no
// item advertises a shortcut it does not have.
fn build_menu() []engine.MenuItem {
	return [
		engine.MenuItem{
			label:    '&File'
			children: [
				engine.MenuItem{
					label:   'Open Folder...'
					command: 'file.openFolder'
				},
				engine.MenuItem{
					label:   'New Terminal'
					command: 'terminal.new'
				},
				engine.MenuItem{
					separator: true
				},
				engine.MenuItem{
					label:   'Exit'
					command: 'app.quit'
				},
			]
		},
		engine.MenuItem{
			label:    '&View'
			children: [
				engine.MenuItem{
					label:   'Reload'
					command: 'view.reload'
				},
				engine.MenuItem{
					label:   'Web Inspector'
					command: 'view.devtools'
				},
			]
		},
		engine.MenuItem{
			label:    '&Help'
			children: [
				engine.MenuItem{
					label:   'About vshell'
					command: 'help.about'
				},
			]
		},
	]
}

fn parse_args(args []string) Options {	mut opts := Options{}
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
			'--folder' {
				if i + 1 < args.len {
					opts.folder = args[i + 1]
					i += 2
				} else {
					i++
				}
			}
			'--open-folder' {
				opts.open_folder = true
				i++
			}
			'--url' {
				if i + 1 < args.len {
					opts.url = args[i + 1]
					i += 2
				} else {
					i++
				}
			}
			'--reh' {
				if i + 1 < args.len {
					opts.reh = args[i + 1]
					i += 2
				} else {
					i++
				}
			}
			'--eval' {
				// Take EVERY following token that is not another flag. On Windows the
				// command line splits on spaces, so `--eval 'typeof window.x'` arrives as
				// ["typeof", "window.x"] and quietly evaluating just "typeof" produced a
				// blank answer with no hint of why — three debugging sessions in a row.
				// Joining until the next flag makes the unquoted form work; a properly
				// quoted script is a single token and is unaffected.
				mut script := ''
				mut j := i + 1
				for j < args.len && !args[j].starts_with('--') {
					if script != '' {
						script += ' '
					}
					script += args[j]
					j++
				}
				if script != '' {
					opts.evals << script
				}
				i = j
			}
			else {
				i++
			}
		}
	}
	return opts
}
