#!/usr/bin/env bun
// Codebun backend service.
//
// The other half of extensions/codebun-backend: the extension asks, this answers.
// It is mounted by web/serve.js on the same origin as the served workbench, so the
// page's requests are same-origin and no CORS handling is needed.
//
//   GET  /codebun/backend/hello                      -> { ok, pid, cwd, version }
//   GET  /codebun/backend/stat?path=<abs>            -> { type, size, mtime }
//   GET  /codebun/backend/readdir?path=<abs>         -> [ { name, type } ]
//   GET  /codebun/backend/read?path=<abs>            -> bytes
//   POST /codebun/backend/write?path=<abs>           -> body written to path
//   POST /codebun/backend/mkdir?path=<abs>
//   POST /codebun/backend/delete?path=<abs>          -> 501, on purpose (see below)
//   WS   /codebun/backend/terminal?cols=&rows=&cwd=  -> one PTY (bun-pty) per socket,
//        JSON frames: in {t:'data',d}|{t:'resize',cols,rows}; out {t:'data',d}|{t:'exit'}|{t:'error'}
//
// --------------------------------------------------------------------------
// SECURITY — a token now gates every request, with one caveat stated plainly.
//
// The shell generates a random token per run (main.v, new_token), exports it as
// VSHELL_TOKEN before it spawns this process, and delivers it to the page
// out-of-band: the engine injects it as a document-start user script, so unlike
// anything this server sends it never appears in an HTTP response a local
// process could fetch. The page re-broadcasts it on a same-origin
// BroadcastChannel and the extension sends it back on every call as
// `X-Codebun-Token`. When TOKEN is set below, a request without the matching
// header is rejected with 401 before it is even routed.
//
// The caveat: the token is only as secret as the channel that carries it to the
// extension host worker. That channel is a browser BroadcastChannel (origin
// scoped, not network reachable), which is the point — but it means the boundary
// is "the engine delivered the page", not cryptography against a local
// adversary. It is a real improvement over the Origin-only check that used to be
// the only filter (which any local process could forge), and it is what lets the
// next milestone add a destructive endpoint safely.
//
// When VSHELL_TOKEN is absent — a standalone `bun run web/serve.js`, or a run
// with no shell — the service is OPEN. That is deliberate for development, and
// is why nothing destructive ships against it yet.
//
// `delete` still returns 501: the milestone that needs it ("open a folder, save
// a file") does not, and it should land together with a test that the 401 path
// actually fires, not merely with the token being present.
// --------------------------------------------------------------------------

import { mkdir, readdir, readFile, stat, writeFile } from 'node:fs/promises'
import * as path from 'node:path'

export const BACKEND_PREFIX = '/codebun/backend'

// Set by the shell (inherited through the environment) and required back in the
// X-Codebun-Token header on every request when present. Empty => open (dev only).
const TOKEN = process.env.VSHELL_TOKEN ?? ''
const TOKEN_HEADER = 'x-codebun-token'

// One connection is one terminal. The PTY is tunneled over a WebSocket because
// both halves are continuous (keystrokes in, output out), which the
// request/response shape of the file endpoints cannot express.
export const TERMINAL_ROUTE = '/terminal'

// Returned by handleBackend after a WebSocket handshake was accepted: serve.js
// must then return undefined from fetch (that is how Bun completes the upgrade),
// not fall through to the static handler.
export const UPGRADED = Symbol('codebun:upgraded')

/*
 * bun-pty is loaded lazily so the server still starts when it is not installed —
 * the file endpoints do not need it and a missing terminal must not take down
 * `open a folder`. It is native: Rust `portable-pty` (ConPTY on Windows) through
 * Bun FFI, with the DLL shipped in the npm package. Verified on this machine
 * before it was wired in: a spawn echoed `hello-from-pty` back with the real
 * console banner and ANSI escapes.
 */
let ptyModule
function loadPty() {
  ptyModule ??= import('bun-pty').catch(error => {
    console.error('vshell-web: bun-pty is not available:', error?.message ?? error)
    return undefined
  })
  return ptyModule
}

/* The shell to run: VSHELL_SHELL wins (pick pwsh, bash, wsl…), then the platform
 * default (ComSpec on Windows, $SHELL elsewhere). */
function resolveShell() {
  if (process.env.VSHELL_SHELL) {
    return process.env.VSHELL_SHELL
  }
  if (process.platform === 'win32') {
    return process.env.ComSpec || 'cmd.exe'
  }
  return process.env.SHELL || '/bin/bash'
}

function sendJson(ws, value) {
  try {
    ws.send(JSON.stringify(value))
  } catch {
    /* peer already gone */
  }
}

/* The WebSocket handlers Bun.serve() needs. Exported so web/serve.js can hand
 * them straight to its server; the terminal's whole lifecycle lives here. */
export const websocket = {
  async open(ws) {
    const pty = await loadPty()
    if (!pty) {
      sendJson(ws, { t: 'error', message: 'bun-pty is not installed on the server (run: bun install)' })
      ws.close()
      return
    }
    try {
      const term = pty.spawn(resolveShell(), [], {
        name: 'xterm-256color',
        cols: ws.data.cols,
        rows: ws.data.rows,
        cwd: ws.data.cwd,
        // bun-pty REPLACES the environment (as node-pty does), so spreading
        // process.env is what keeps PATH, PATHEXT, SystemRoot… alive.
        env: { ...process.env, TERM: 'xterm-256color' },
      })
      ws.data.pty = term
      // Lifecycle logging on purpose: the access log in web/serve.js only sees
      // HTTP requests, so a terminal that opens (WS upgrade) and then produces
      // nothing is indistinguishable from one that works. These two lines are
      // what make "the PTY really spawned" observable in the shell's output.
      console.log(`vshell-web: terminal opened pid=${term.pid} ${ws.data.cols}x${ws.data.rows} cwd=${ws.data.cwd ?? '(default)'}`)
      term.onData(data => sendJson(ws, { t: 'data', d: data }))
      term.onExit(event => {
        console.log(`vshell-web: terminal exited code=${event.exitCode}`)
        sendJson(ws, { t: 'exit', code: event.exitCode, signal: event.signal })
        try { ws.close() } catch { /* already closing */ }
      })
    } catch (error) {
      // Both places on purpose: the editor shows one, the shell's output has the
      // other. A spawn failure is otherwise invisible in the run log.
      console.error('vshell-web: terminal spawn failed:', error?.message ?? error)
      sendJson(ws, { t: 'error', message: `${error?.message ?? error}` })
      ws.close()
    }
  },

  message(ws, raw) {
    const term = ws.data?.pty
    if (!term) {
      return
    }
    let msg
    try {
      msg = JSON.parse(typeof raw === 'string' ? raw : raw.toString())
    } catch {
      return
    }
    if (msg?.t === 'data' && typeof msg.d === 'string') {
      term.write(msg.d)
    } else if (msg?.t === 'resize') {
      term.resize(Number(msg.cols) || ws.data.cols, Number(msg.rows) || ws.data.rows)
    }
  },

  close(ws) {
    const term = ws.data?.pty
    if (term) {
      // Closing the editor pane must not leave a shell running: this is the only
      // place the child is reaped.
      try { term.kill() } catch { /* already gone */ }
      ws.data.pty = null
    }
  },
}

/** Refuse anything that is not a plain absolute path. */
const MAX_PATH_LENGTH = 4096

const json = (body, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json; charset=utf-8' } })

const jsonError = (status, message) => json({ error: message }, status)

/**
 * `codebun:/C:/Users/x` and `codebun:C:/Users/x` must resolve to the same place,
 * and both must work on Windows and POSIX. VS Code's `Uri.path` for a custom
 * scheme is not normalised the way `file://` is, so the '/C:/' form is real.
 */
function toFsPath(raw) {
  if (!raw || raw.length > MAX_PATH_LENGTH || raw.includes('\0')) {
    return undefined
  }
  const withoutLeadingSlash = /^\/[A-Za-z]:/.test(raw) ? raw.slice(1) : raw
  return path.resolve(withoutLeadingSlash)
}

// `Origin` is kept as a coarse second filter, not as the boundary. It stops a
// random web page in a browser from reaching the port; it never was protection
// against a local process (which can send `Origin` too). The token above is what
// actually authenticates a caller; this only narrows who gets that far.
//
//   * A browser omits `Origin` on same-origin requests, and the extension host
//     runs on the same origin as the workbench, so this must allow a missing
//     header (requiring it rejects the GETs the editor needs).
//   * Anything can send `Origin`, so a present one must at least match `Host`.
function callerLooksLikeThePage(req) {
  const origin = req.headers.get('origin')
  if (!origin) {
    return true
  }
  try {
    return new URL(origin).host === req.headers.get('host')
  } catch {
    return false
  }
}

/*
 * Accepts the terminal WebSocket handshake, or returns the error to send instead.
 *
 * The token is accepted from the header OR the query string: the extension runs
 * in a worker and constructs the socket with `new WebSocket(url)`, which cannot
 * carry headers, so `?token=` is the only carrier available. Same secret, same
 * check — just the one transport a WebSocket makes possible.
 *
 * `cwd` and the initial size come from the query too (they are known when the
 * terminal pane opens, before the socket exists) and are stashed in `ws.data`,
 * which the websocket handler reads when it spawns the PTY.
 */
function handleTerminalUpgrade(req, url, server) {
  const provided = req.headers.get(TOKEN_HEADER) ?? url.searchParams.get('token')
  if (TOKEN && provided !== TOKEN) {
    return jsonError(401, 'missing or invalid backend token')
  }
  if (!server || typeof server.upgrade !== 'function') {
    return jsonError(500, 'server does not support websocket upgrades')
  }

  const data = {
    pty: null,
    cols: Number(url.searchParams.get('cols')) || 80,
    rows: Number(url.searchParams.get('rows')) || 24,
    cwd: toFsPath(url.searchParams.get('cwd') ?? ''),
  }

  // server.upgrade() returns true once the handshake is accepted. On false the
  // request was not a valid upgrade (e.g. no Upgrade header), so report it.
  return server.upgrade(req, { data }) ? UPGRADED : jsonError(400, 'websocket upgrade failed')
}

export async function handleBackend(req, pathname, server) {
  if (!pathname.startsWith(BACKEND_PREFIX)) {
    return undefined
  }

  const route = pathname.slice(BACKEND_PREFIX.length)
  const url = new URL(req.url)

  // The terminal is a WebSocket, so it is handled before the token/origin checks
  // below: a browser cannot set request headers on `new WebSocket()`, so the
  // token arrives in the query string instead (checked inside, same value).
  if (route === TERMINAL_ROUTE) {
    return handleTerminalUpgrade(req, url, server)
  }

  // Token first: without it nothing else about the request matters. Checked
  // before routing so every endpoint (present and future) inherits it.
  if (TOKEN && req.headers.get(TOKEN_HEADER) !== TOKEN) {
    return jsonError(401, 'missing or invalid backend token')
  }
  if (!callerLooksLikeThePage(req)) {
    return jsonError(403, 'origin check failed')
  }

  const rawPath = url.searchParams.get('path') ?? ''
  const target = toFsPath(rawPath)

  if (route === '/hello') {
    return json({ ok: true, pid: process.pid, cwd: process.cwd(), version: 'codebun-backend/0.0.1' })
  }

  if (route !== '/hello' && !target) {
    return jsonError(400, `missing or unusable path (got ${JSON.stringify(rawPath)})`)
  }

  try {
    switch (route) {
      case '/stat': {
        const s = await stat(target)
        return json({ type: s.isDirectory() ? 'directory' : 'file', size: s.size, mtime: s.mtimeMs })
      }

      case '/readdir': {
        const entries = await readdir(target, { withFileTypes: true })
        return json(
          entries.map(e => ({ name: e.name, type: e.isDirectory() ? 'directory' : 'file' }))
        )
      }

      case '/read': {
        const data = await readFile(target)
        return new Response(data, { headers: { 'content-type': 'application/octet-stream' } })
      }

      case '/write': {
        if (req.method !== 'POST') return jsonError(405, 'POST required')
        const body = new Uint8Array(await req.arrayBuffer())
        await writeFile(target, body)
        return json({ ok: true, bytes: body.length })
      }

      case '/mkdir': {
        if (req.method !== 'POST') return jsonError(405, 'POST required')
        await mkdir(target, { recursive: false })
        return json({ ok: true })
      }

      case '/delete':
        return jsonError(
          501,
          'delete is not implemented: it is destructive and this service has no real authentication yet'
        )

      default:
        return jsonError(404, `unknown backend route ${route}`)
    }
  } catch (error) {
    // The message is passed through on purpose: "ENOENT" vs "EACCES" is the
    // difference between a typo and a permissions problem, and the extension
    // surfaces it in the editor.
    return jsonError(500, `${error?.code ?? 'ERROR'}: ${error?.message ?? String(error)}`)
  }
}
