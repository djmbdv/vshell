module main

import net
import os
import time

// WebServer is the Bun process that serves the shell's origin: the static root,
// the upstream proxy, and the embedder's `--backend` plugin.
// The shell launches it as a child and owns its lifetime: without stop() the
// server outlives the shell and keeps the port busy.
pub struct WebServer {
pub:
	pid  int
	port int
mut:
	p &os.Process = unsafe { nil }
}

// start_web_server launches `bun run web/serve.js` and returns its PID.
// `extra` are passed through to the script (`--upstream <url>`, `--no-cache`,
// `--backend <file>`).
pub fn start_web_server(script string, root string, port int, extra []string) !WebServer {
	bun := find_executable('bun') or {
		return error('bun not found in PATH (needed to run web/serve.js)')
	}

	mut p := os.new_process(bun)
	mut args := ['run', script, '--port', port.str(), '--root', root]
	args << extra
	p.set_args(args)
	p.run()

	if !p.is_alive() {
		return error('failed to start bun (${bun})')
	}
	return WebServer{
		p:    p
		pid:  p.pid
		port: port
	}
}

// stop terminates the Bun child (called from a defer in run()).
pub fn (mut s WebServer) stop() {
	if s.p == unsafe { nil } {
		return
	}
	if s.p.is_alive() {
		s.p.signal_kill()
	}
	s.p.wait()
	s.p = unsafe { nil }
}

// start_child launches an arbitrary process the shell owns. It exists for
// `--run`: an application server is very often not one process (a web IDE starts
// its extension host, its pty host and its file watchers), so having the shell
// start it inside its job object is what makes "close the window, everything is
// gone" true for the whole tree and not only for the proxy.
pub fn start_child(exe string, args []string) !WebServer {
	mut p := os.new_process(exe)
	p.set_args(args)
	p.run()
	if !p.is_alive() {
		return error('failed to start ${exe}')
	}
	return WebServer{
		p:   p
		pid: p.pid
	}
}

// wait_until_listening polls the TCP port so the window only loads once Bun is
// accepting connections. Returns false if it never comes up within timeout_ms.
pub fn (s WebServer) wait_until_listening(timeout_ms int) bool {
	deadline := time.now().add(time.millisecond * timeout_ms)
	for time.now() < deadline {
		mut conn := net.dial_tcp('127.0.0.1:${s.port}') or {
			time.sleep(50 * time.millisecond)
			continue
		}
		conn.close() or {}
		return true
	}
	return false
}

// find_executable resolves an executable name to an absolute path.
fn find_executable(name string) ?string {
	path := os.find_abs_path_of_executable(name) or { return none }
	if path == '' {
		return none
	}
	return path
}
