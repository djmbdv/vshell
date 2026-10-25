#!/usr/bin/env bun
// Reverse proxy to a `vscode-reh-web` server, used when the shell is started with
// `--reh <url>`.
//
// WHY THIS EXISTS — measured, not theoretical:
//
// The REH's HTTP+WS server is VS Code's `ws` running on `node:http`. Under Bun that
// layer completes the WebSocket handshake and sends a valid 101
// (`Sec-WebSocket-Accept` verified byte for byte), but our WebKit never fires `open`
// and the client dies with 1006 after ~10 s. The same page opens a socket to a
// `Bun.serve` server instantly, and Bun *as a client* of the REH works too. So the
// broken pair is exactly "WebKit <-> node:http upgrade on Bun".
//
// The fix is not to touch VS Code and not to reimplement its protocol: the shell
// serves the origin and terminates the socket with `Bun.serve` (which works), then
// pipes messages to the REH over a second WebSocket (which also works).
//
// Messages are forwarded one by one, not frames: each side negotiates its own
// extensions, so deflate/`x-webkit-deflate-frame` never crosses the boundary.

export const UPGRADED = Symbol('vshell:upgraded')

// Hop-by-hop headers must not be forwarded (RFC 7230 §6.1), and the ones about
// framing or encoding must not either: `fetch` already decoded the body, so passing
// `content-encoding`/`content-length` through would make the browser decode twice.
const REQUEST_HOP_BY_HOP = [
  'connection',
  'keep-alive',
  'proxy-authenticate',
  'proxy-authorization',
  'te',
  'trailer',
  'transfer-encoding',
  'upgrade',
]

const RESPONSE_DROP = [...REQUEST_HOP_BY_HOP, 'content-encoding', 'content-length']

const isUpgrade = (req) => (req.headers.get('upgrade') ?? '').toLowerCase() === 'websocket'

// The client and the server talk over the tunnel this file terminates, so a message
// flood shows up here and nowhere else: the access log only sees the upgrade, and the
// proxy stays at 0 % CPU because forwarding is cheap. VSHELL_WS_DEBUG=1 prints a line
// every 200 client messages — the quickest way to tell "the workbench is busy" from
// "the shell is talking to itself".
const DEBUG_WS = process.env.VSHELL_WS_DEBUG === '1'

/** http(s) -> ws(s), keeping path and query. */
export function upstreamSocketUrl(target) {
  const u = new URL(target)
  u.protocol = u.protocol === 'https:' ? 'wss:' : 'ws:'
  return u.toString()
}

/**
 * Accepts the client socket and opens the upstream one.
 *
 * Messages from the client are queued until the upstream is open: the page sends its
 * `auth` frame immediately after `open`, which is almost always before the second
 * handshake completes, and dropping it would look exactly like "the server never
 * answers".
 */
export const proxyWebsocket = {
  open(ws) {
    ws.data.queue = []
    const up = new WebSocket(ws.data.upstreamUrl)
    up.binaryType = 'arraybuffer'
    ws.data.up = up

    up.addEventListener('open', () => {
      for (const m of ws.data.queue) {
        try { up.send(m) } catch { /* upstream died mid-flush */ }
      }
      ws.data.queue = []
    })
    up.addEventListener('message', (e) => {
      if (DEBUG_WS) {
        ws.data.downCount = (ws.data.downCount ?? 0) + 1
      }
      try { ws.send(e.data) } catch { /* client gone */ }
    })
    up.addEventListener('close', (e) => {
      try { ws.close(e.code || 1000, e.reason || '') } catch { /* already closed */ }
    })
    up.addEventListener('error', () => {
      // 1011 = internal error: the upstream is unreachable, which is worth telling
      // the client about instead of leaving it in CONNECTING for ten seconds.
      try { ws.close(1011, 'upstream unavailable') } catch { /* already closed */ }
    })
  },

  message(ws, msg) {
    if (DEBUG_WS) {
      ws.data.upCount = (ws.data.upCount ?? 0) + 1
      if (ws.data.upCount % 200 === 0) {
        console.log(`vshell-web: ws up=${ws.data.upCount} down=${ws.data.downCount}`)
      }
    }
    const up = ws.data.up
    if (up && up.readyState === WebSocket.OPEN) {
      try { up.send(msg) } catch { /* upstream gone */ }
    } else if (ws.data.queue) {
      ws.data.queue.push(msg)
    }
  },

  close(ws) {
    try { ws.data.up?.close() } catch { /* already closed */ }
  },
}

/** Decides an upgrade (returns UPGRADED so the caller yields to Bun) or an error. */
export function handleProxyUpgrade(req, url, server, upstreamBase) {
  if (!server || typeof server.upgrade !== 'function') {
    return new Response('server does not support websocket upgrades', { status: 500 })
  }
  const target = new URL(url.pathname + url.search, upstreamBase)
  const data = { upstreamUrl: upstreamSocketUrl(target.toString()), up: null, queue: [] }
  const ok = server.upgrade(req, { data })
  return ok ? UPGRADED : new Response('websocket upgrade failed', { status: 400 })
}

/**
 * Forwards one HTTP request.
 *
 * `origin`/`referer` are rewritten to the upstream so the REH sees a consistent
 * pair; VS Code's server compares them against its own host for some endpoints, and
 * a request arriving with our port in `Origin` and its own in `Host` is the kind of
 * mismatch that fails with a bare 403 and no explanation.
 */
export async function proxyRequest(req, url, upstreamBase, options = {}) {
  const target = new URL(url.pathname + url.search, upstreamBase)
  const headers = new Headers(req.headers)
  for (const h of REQUEST_HOP_BY_HOP) headers.delete(h)
  headers.delete('host')

  // The REH builds the workbench's `remoteAuthority` from
  //   x-original-host || x-forwarded-host || Host
  // (src/vs/server/node/webClientServer.ts). Without this header the page would
  // still say "127.0.0.1:8137" and the client would connect to the REH DIRECTLY,
  // bypassing this proxy — which is exactly the socket that fails under WebKit.
  // Announcing our own host here is what keeps the client talking to us.
  const clientHost = req.headers.get('host') ?? ''
  if (clientHost) {
    headers.set('x-forwarded-host', clientHost)
    headers.set('x-forwarded-proto', 'http')
  }

  // origin/referer follow the same story: the REH compares them against the host it
  // believes it is serving, so they are rewritten to the forwarded host rather than
  // to the upstream's own address.
  const publicOrigin = clientHost ? `http://${clientHost}` : new URL(upstreamBase).origin
  if (headers.has('origin')) headers.set('origin', publicOrigin)
  if (headers.has('referer')) {
    try {
      const ref = new URL(headers.get('referer'))
      headers.set('referer', publicOrigin + ref.pathname + ref.search)
    } catch { /* leave it */ }
  }

  const init = { method: req.method, headers, redirect: 'manual' }
  if (req.method !== 'GET' && req.method !== 'HEAD') init.body = req.body

  let response
  try {
    response = await fetch(target, init)
  } catch (error) {
    return new Response(`upstream ${upstreamBase} unreachable: ${error?.message ?? error}\n`, { status: 502 })
  }

  const out = new Headers(response.headers)
  for (const h of RESPONSE_DROP) out.delete(h)
  // The REH marks /static with a one-year max-age and sends no validator, so a stale
  // copy can never be revalidated away (see --no-cache in web/serve.js).
  //
  // Rewriting the HTML to version those URLs is NOT an option: the page's inline
  // scripts are pinned by sha256 in its Content-Security-Policy, so any edit to them
  // — including the one setting `_VSCODE_FILE_ROOT` — is blocked by the browser and
  // the workbench never boots. A fresh origin is what actually invalidates the cache,
  // so when iterating on the workbench itself, pick a different `--port`.
  if (options.noCache && (req.method === 'GET' || req.method === 'HEAD')) {
    out.set('cache-control', 'no-store')
  }
  // A redirect must send the page back to OUR origin, or the browser leaves the
  // proxy and lands on the REH directly (and the socket breaks again).
  const location = out.get('location')
  if (location) {
    try {
      const abs = new URL(location, upstreamBase)
      out.set('location', abs.pathname + abs.search + abs.hash)
    } catch { /* leave it */ }
  }

  return new Response(response.body, { status: response.status, statusText: response.statusText, headers: out })
}

export { isUpgrade }
