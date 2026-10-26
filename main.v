module main

import os
import json2
import engine

// vshell entrypoint.
//
// The shell is an Electron alternative, nothing more: it owns a window with a
// real engine inside, a local HTTP server that can also act as the origin of an
// upstream it proxies (HTTP and WebSocket), and the lifetime of whatever it
// starts. It knows nothing about what the page *is*.
//
// Everything application-specific enters through data:
//   --inject   an opaque JSON payload the page reads as window.vshell.host
//   --script   extra JS injected by the embedder, before the page's own code
//   --menu     the native menu bar, as JSON
//   --run      the upstream program to launch (an app server, a dev server...)
//
// Flow:
//   1. put the process job in place (nothing the shell starts may outlive it)
//   2. optionally start the upstream (--run) and wait for it
//   3. start the server that serves the static root and/or proxies the upstream
//   4. open the window, hand the page its payload, install the menu
//   5. run the engine loop, then tear everything down
//
// See ROADMAP.md. Phases 0/1 were validated on the Ultralight backend, which
// Phase 1b replaced: the page now boots inside WebKit (the WinCairo port), same
// JavaScriptCore family, no V8 anywhere.

const default_port = 8123
const serve_script = 'web/serve.js'

// shell_root is the directory the shell was shipped in (the one holding web/ and
// bin/). Everything the shell starts must not depend on the working directory:
// an embedder points the cwd at its own tree so its children inherit it, and
// `bun run web/serve.js` would then fail with ENOENT.
fn shell_root() string {
	exe_dir := os.dir(os.executable())
	if os.exists(os.join_path(exe_dir, serve_script)) {
		return exe_dir
	}
	if os.exists(os.join_path(exe_dir, '..', serve_script)) {
		return os.join_path(exe_dir, '..')
	}
	return os.getwd()
}

// serve_script_path is the shell's web server: the working directory first
// (running from the repo root), then the layout next to the executable.
fn serve_script_path() string {
	if os.exists(serve_script) {
		return serve_script
	}
	return os.join_path(shell_root(), serve_script)
}

// default_web_root is what --serve falls back to: the tree the shell ships next
// to itself, or the working directory when there is none. It only matters when
// no upstream answers, because the proxy is consulted before the static root.
fn default_web_root() string {
	shipped := os.join_path(shell_root(), 'web', 'public')
	if os.exists(shipped) {
		return shipped
	}
	return '.'
}

struct Options {
mut:
	engine_kind string = 'webkit'
	port        int    = default_port
	// web_root is the directory the shell's server serves. It may be empty when
	// the shell only fronts an upstream (--proxy): then every request is forwarded.
	// Empty means "the tree the shell ships next to itself" (see default_web_root).
	web_root    string
	dev_mode    bool
	// url points the window at a server this process did NOT start. When set, no
	// server and no upstream are spawned and --port/--web-root are ignored.
	url         string
	// proxy is the base URL of an upstream the shell fronts: it becomes the origin
	// (serving everything and terminating the WebSocket) and forwards to it. The
	// indirection exists because not every upstream's own WebSocket upgrade
	// survives every engine; see web/proxy.js for the measurement.
	proxy       string
	// run_cmd/run_args launch that upstream as a child, inside the shell's job
	// object, so closing (or killing) the shell takes the whole tree with it.
	run_cmd     string
	run_args    []string
	// no_cache tells the proxy to answer Cache-Control: no-store. Long-lived
	// caching of a build you are iterating on is how a rebuild ends up looking like
	// it did nothing. Development flag; the default keeps the cache.
	no_cache    bool
	// backend is a JS module the shell's server loads as a plugin: it gets first
	// refusal on every request, which is how an embedder mounts its own routes
	// (rendered pages, APIs, WebSockets) without the shell knowing them. Its
	// websocket handlers are what Bun.serve gets when set. See web/serve.js.
	backend     string
	// inject is the embedder's payload: inline JSON or @file. Delivered out of band
	// (injected user script), never through a URL the page could be tricked into
	// re-fetching.
	inject      string
	// scripts are JS files injected after the bridge, in order (repeatable).
	scripts     []string
	// menu_file is a JSON menu description (@file, path or inline). Empty means the
	// shell's own three-item default.
	menu_file   string
	// folder/open_folder are a convenience for embedders whose payload wants a
	// directory: the chosen path is merged into the payload as "folder".
	folder      string
	open_folder bool
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
	mut opts := parse_args(os.args)
	if opts.web_root == '' {
		opts.web_root = default_web_root()
	}

	// Pick the folder before the window exists: the payload is injected as a
	// document-start user script, so it must be known up front. A native dialog
	// with no owner still works, it is just not docked modally.
	mut folder := opts.folder
	if folder == '' && opts.open_folder {
		if chosen := engine.pick_folder() {
			folder = chosen
		} else {
			println('vshell: no folder chosen')
		}
	}

	mut server := WebServer{}
	mut upstream := WebServer{}
	if opts.url == '' {
		// Before any child exists: the job has to be in place to contain them, and it
		// is what guarantees nothing survives the shell (see proc_job.v).
		if !process_job_init() {
			eprintln('vshell: could not create the job object; children may outlive the shell')
		}

		if opts.run_cmd != '' {
			upstream = start_child(opts.run_cmd, opts.run_args)!
			if !process_job_assign(upstream.pid) {
				eprintln('vshell: could not put the upstream in the job object')
			}
			println('vshell: upstream pid=${upstream.pid} (${opts.run_cmd})')
		}

		mut extra := if opts.proxy != '' { ['--upstream', opts.proxy] } else { []string{} }
		if opts.no_cache {
			extra << '--no-cache'
		}
		if opts.backend != '' {
			extra << '--backend'
			extra << opts.backend
		}
		server = start_web_server(serve_script_path(), opts.web_root, opts.port, extra)!
		if !process_job_assign(server.pid) {
			eprintln('vshell: could not put the web server in the job object')
		}
		println('vshell: web server pid=${server.pid} port=${server.port}')
		if opts.proxy != '' {
			println('vshell: proxying to ${opts.proxy}')
		}

		// The view must not load before the server accepts connections, or the host
		// page 404s and nothing mounts.
		if !server.wait_until_listening(10_000) {
			return error('the web server never started listening on port ${opts.port}')
		}
		// Same for the upstream: serving the page while it is still binding would
		// hand the client a 502 and an empty window.
		if opts.run_cmd != '' && opts.proxy != '' {
			if port := host_port_of(opts.proxy) {
				if !WebServer{ port: port }.wait_until_listening(60_000) {
					return error('the upstream never started listening on ${opts.proxy}')
				}
			}
		}
	} else {
		// Nothing to wait for: --url means somebody else owns the server.
		println('vshell: loading ${opts.url} (no server started)')
	}
	defer {
		server.stop()
		upstream.stop()
	}

	mut eng := engine.new_engine(opts.engine_kind)!
	eng.set_host(build_payload(opts.inject, folder), opts.scripts)
	url := if opts.url != '' { opts.url } else { 'http://127.0.0.1:${opts.port}/' }
	eng.create_window('vshell', url, 1280, 800, opts.dev_mode)!

	// The shell's own chrome: a real Win32 menu bar, drawn and owned by the OS.
	// The engine handles the handful of commands that are its own (quit, reload,
	// inspector, about) and forwards every other one to the page as a `menu`
	// event, because only the embedder knows what "open a folder" means.
	if !eng.set_menu_bar(load_menu(opts.menu_file)) {
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

// host_port_of extracts the port from a base URL (http://127.0.0.1:8137/). It
// exists so --run knows what to wait for without the shell knowing what the
// upstream is.
fn host_port_of(url string) ?int {
	scheme_end := url.index('://') or { return none }
	rest := url[scheme_end + 3..]
	host_port := rest.split('/')[0]
	colon := host_port.last_index(':') or { return none }
	return host_port[colon + 1..].int()
}

// build_payload returns the JSON object the page sees as window.vshell.host.
//
// The base comes from --inject (inline JSON or @file) and the shell only adds
// "folder" when one was chosen, because that is the one thing the shell can
// produce itself. The merge is textual for a reason: the payload's shape is the
// embedder's business, and round-tripping it through a decoder here would
// silently drop every field this build does not know about.
fn build_payload(inject string, folder string) string {
	mut base := if inject == '' {
		'{}'
	} else if inject.starts_with('@') {
		os.read_file(inject[1..]) or {
			eprintln('vshell: could not read ${inject[1..]}: ${err}')
			'{}'
		}
	} else {
		inject
	}
	base = base.trim_space()
	if base == '' {
		base = '{}'
	}
	if folder == '' {
		return base
	}
	entry := '"folder":"${json_escape(folder)}"'
	if base == '{}' {
		return '{${entry}}'
	}
	if !base.starts_with('{') {
		eprintln('vshell: --inject is not a JSON object; ignoring it')
		return '{${entry}}'
	}
	inner := base[1..].trim_left(' \t\r\n')
	if inner == '}' {
		return '{${entry}}'
	}
	return '{${entry},${inner}'
}

// json_escape escapes a value for a JSON string literal. Paths are the reason it
// exists: on Windows every one of them carries backslashes, which are illegal
// unescaped in JSON.
fn json_escape(s string) string {
	mut out := []u8{cap: s.len + 8}
	for c in s.bytes() {
		match c {
			34 {
				out << u8(92)
				out << u8(34)
			}
			92 {
				out << u8(92)
				out << u8(92)
			}
			10 {
				out << u8(92)
				out << u8(110)
			}
			13 {
				out << u8(92)
				out << u8(114)
			}
			9 {
				out << u8(92)
				out << u8(116)
			}
			else {
				if c < 0x20 {
					out << u8(92)
					out << u8(117)
					out << u8(48)
					out << u8(48)
					out << hex_digit(c >> 4)
					out << hex_digit(c & 0xf)
				} else {
					out << c
				}
			}
		}
	}
	return out.bytestr()
}

fn hex_digit(n u8) u8 {
	return if n < 10 { u8(48) + n } else { u8(97) + (n - 10) }
}

// --- menu as data -----------------------------------------------------------

// MenuItemSpec is one node of a --menu description. It mirrors engine.MenuItem,
// which carries what the engine needs (a label and a command, never a callback):
// a callback from inside a Win32 message handler would re-enter the engine.
struct MenuItemSpec {
	label     string
	command   string
	separator bool
	items     []MenuItemSpec
}

struct MenuSpec {
	menus []MenuItemSpec
}

// load_menu turns the --menu description into engine items. The argument may be
// inline JSON, a path, or @path; empty returns the shell's own minimal bar, which
// is deliberately about the shell and nothing else.
fn load_menu(spec string) []engine.MenuItem {
	if spec == '' {
		return [
			engine.MenuItem{
				label:    '&File'
				children: [
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
						label:   'Developer Tools'
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

	raw := if spec.starts_with('@') {
		os.read_file(spec[1..]) or {
			eprintln('vshell: could not read menu ${spec[1..]}: ${err}')
			return []
		}
	} else if spec.contains('{') {
		spec
	} else {
		os.read_file(spec) or {
			eprintln('vshell: could not read menu ${spec}: ${err}')
			return []
		}
	}

	decoded := json2.decode[MenuSpec](raw) or {
		eprintln('vshell: invalid --menu JSON: ${err}')
		return []
	}
	mut items := []engine.MenuItem{cap: decoded.menus.len}
	for m in decoded.menus {
		items << to_engine_menu(m)
	}
	return items
}

fn to_engine_menu(spec MenuItemSpec) engine.MenuItem {
	mut children := []engine.MenuItem{cap: spec.items.len}
	for child in spec.items {
		children << to_engine_menu(child)
	}
	return engine.MenuItem{
		label:     spec.label
		command:   spec.command
		separator: spec.separator
		children:  children
	}
}
// --- argument parsing -------------------------------------------------------

// parse_args reads the CLI. The vocabulary is deliberately about the shell:
// `--proxy` fronts an upstream, `--run` starts one, `--inject`/`--script`/`--menu`
// hand the embedder's own data to the page. Nothing here names an application.
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
			'--serve', '--web-root' {
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
			'--url' {
				if i + 1 < args.len {
					opts.url = args[i + 1]
					i += 2
				} else {
					i++
				}
			}
			'--proxy' {
				if i + 1 < args.len {
					opts.proxy = args[i + 1]
					i += 2
				} else {
					i++
				}
			}
			'--run' {
				if i + 1 < args.len {
					opts.run_cmd = args[i + 1]
					i += 2
				} else {
					i++
				}
			}
			'--run-arg' {
				if i + 1 < args.len {
					opts.run_args << args[i + 1]
					i += 2
				} else {
					i++
				}
			}
			'--no-cache' {
				opts.no_cache = true
				i++
			}
			'--backend' {
				if i + 1 < args.len {
					opts.backend = args[i + 1]
					i += 2
				} else {
					i++
				}
			}
			'--inject' {
				if i + 1 < args.len {
					opts.inject = args[i + 1]
					i += 2
				} else {
					i++
				}
			}
			'--script' {
				if i + 1 < args.len {
					opts.scripts << args[i + 1]
					i += 2
				} else {
					i++
				}
			}
			'--menu' {
				if i + 1 < args.len {
					opts.menu_file = args[i + 1]
					i += 2
				} else {
					i++
				}
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
			'--eval' {
				// Take EVERY following token that is not another flag. On Windows the
				// command line splits on spaces, so `--eval 'typeof window.x'` arrives as
				// ["typeof", "window.x"] and quietly evaluating just "typeof" produced a
				// blank answer with no hint of why. Joining until the next flag makes the
				// unquoted form work; a properly quoted script is a single token.
				mut script := ''
				i++
				for i < args.len && !args[i].starts_with('--') {
					if script != '' {
						script += ' '
					}
					script += args[i]
					i++
				}
				if script != '' {
					opts.evals << script
				}
			}
			else {
				eprintln('vshell: ignoring unknown argument ${args[i]}')
				i++
			}
		}
	}
	return opts
}