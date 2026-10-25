module main

// Process-tree lifetime for everything the shell spawns.
//
// The C lives in engine/wk_host.h (the only translation unit where we compile
// Win32 glue) and the reason is documented there: `WebServer.stop()` handles the
// graceful exit, but a crash or a killed shell leaves the Bun child running with
// its port and its memory. A job object with KILL_ON_JOB_CLOSE hands that cleanup
// to the OS, and because children of a process inside a job join the job too, one
// assignment on the direct child covers the whole tree (proxy → none today, but
// also any future `--reh-run`, and the extension host / pty host / watchers that
// the REH spawns if the shell ever owns it).
fn C.wk_job_init() int
fn C.wk_job_assign(pid u32) int

// process_job_init creates the job the shell's children will belong to. Returns
// false when the process is already inside a job that forbids nesting (Windows 8+
// allows nested jobs, but some launchers do not) — callers continue either way,
// they just fall back to `stop()` on the graceful path.
pub fn process_job_init() bool {
	return C.wk_job_init() != 0
}

// process_job_assign puts `pid` (and everything it spawns later) under the job.
pub fn process_job_assign(pid int) bool {
	if pid <= 0 {
		return false
	}
	return C.wk_job_assign(u32(pid)) != 0
}
