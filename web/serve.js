#!/usr/bin/env bun
// vshell web server: a static root, an optional upstream proxy, and a plugin
// slot for the embedder. Launched by the V shell as a child process, or
// standalone:
//
//   bun run web/serve.js --port 8123 --root ./public --backend ./backend.js
//
// The shell knows three things about HTTP and nothing else:
//   * serve files from --root
//   * when --upstream is set, be the ORIGIN and forward everything to it,
//     including the WebSocket upgrade (see web/proxy.js for why the shell
//     terminates the socket instead of letting the upstream do it)
//   * consult the embedder plugin first, for routes only it understands
//
// The plugin (--backend) is an ES module:
//   export const websocket            Bun.serve websocket handlers (optional)
//   export const UPGRADED             the sentinel handle() returns after it has
//                                     started an upgrade itself (optional)
//   export async function handle(ctx) ctx = { req, url, pathname, server, root,
//                                     noCache }; return a Response to answer, the
//                                     UPGRADED sentinel to let Bun finish an
//                                     upgrade, or undefined to fall through.
// That is the whole contract. Everything an application needs to know about
// itself lives in that file, not here.

import { isAbsolute, join } from 'node:path'
import { pathToFileURL } from 'node:url'

import { handleProxyUpgrade, isUpgrade, proxyRequest, proxyWebsocket, UPGRADED as PROXY_UPGRADED } from './proxy.js'

const argv = process.argv.slice(2)
const opt = (name, def) => {
  const i = argv.indexOf(`--${name}`)
  return i !== -1 && argv[i + 1] ? argv[i + 1] : def
}

const port = Number(opt('port', process.env.VSHELL_PORT ?? '8123'))
const host = opt('host', process.env.VSHELL_HOST ?? '127.0.0.1')
const root = opt('root', process.env.VSHELL_WEB_ROOT ?? join(import.meta.dir, 'public'))
const base = root.replace(/[\\/]+$/, '')
// When set, this server becomes the origin of an upstream it fronts
// (--upstream, or --proxy from the shell): everything not answered by the
// plugin or by --root is forwarded. See web/proxy.js.
const upstream = opt('upstream', process.env.VSHELL_UPSTREAM ?? '')
// Some builds mark their bundles as immutable and send no validator, which is
// right for a released build and wrong while iterating: the page keeps the old
// copy and every change looks like it did nothing. `--no-cache` answers
// `no-store` from then on; an entry already in the cache needs a different
// origin (a different --port) to be replaced.
const noCache = argv.includes('--no-cache') || process.env.VSHELL_NO_CACHE === '1'
// VSHELL_ACCESS_LOG=1 logs every request: handy to watch the embedded engine
// load a page (the V shell inherits the env and passes it to this child).
const accessLog = process.env.VSHELL_ACCESS_LOG === '1'

// The embedder plugin. A relative path resolves against the working directory,
// which is the shell's, so `--backend server/backend.js` behaves the same as the
// absolute form a launcher passes.
const backendOpt = opt('backend', process.env.VSHELL_BACKEND ?? '')
const backendPath = backendOpt === '' ? '' : isAbsolute(backendOpt) ? backendOpt : join(process.cwd(), backendOpt)
// A Windows path is not a module specifier: it has to become a file:// URL or
// the import fails with ERR_UNSUPPORTED_ESM_URL_SCHEME.
const plugin = backendPath === '' ? undefined : await import(pathToFileURL(backendPath).href)

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.ico': 'image/x-icon',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.ttf': 'font/ttf',
  '.otf': 'font/otf',
  '.wasm': 'application/wasm',
  '.map': 'application/json; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8',
}

const extOf = (p) => {
  const i = p.lastIndexOf('.')
  return i === -1 ? '' : p.slice(i).toLowerCase()
}

const server = Bun.serve({
  hostname: host,
  port,
  // Bun needs the websocket handlers up front, so the plugin supplies them when
  // it wants one; the upgrade itself is decided in the fetch below.
  websocket: plugin?.websocket ?? (upstream ? proxyWebsocket : undefined),
  async fetch(req) {
    const url = new URL(req.url)
    // Collapse repeated slashes: the host page computes its file root from its
    // own URL, which yields '//out/...'.
    const pathname = decodeURIComponent(url.pathname).replace(/\/{2,}/g, '/')
    if (accessLog) console.log(`vshell-web: ${req.method} ${pathname}`)

    // The embedder first, before both the proxy and the static root: its routes
    // are the ones a file or an upstream path could otherwise shadow. On a
    // successful upgrade it returns its own UPGRADED and this fetch must yield
    // undefined so Bun completes the handshake itself.
    if (plugin?.handle) {
      const answer = await plugin.handle({ req, url, pathname, server, root: base, noCache })
      if (answer === plugin.UPGRADED) return undefined
      if (answer) return answer
    }

    if (upstream) {
      if (isUpgrade(req)) {
        const r = handleProxyUpgrade(req, url, server, upstream)
        if (r === PROXY_UPGRADED) return undefined
        return r
      }
      return proxyRequest(req, url, upstream, { noCache })
    }

    const filePath = base + (pathname.endsWith('/') ? pathname + 'index.html' : pathname)
    const file = Bun.file(filePath)

    if (!(await file.exists())) {
      console.log(`vshell-web: 404 ${pathname}`)
      return new Response(`404 ${pathname}\n`, { status: 404 })
    }

    return new Response(file, {
      headers: {
        'content-type': MIME[extOf(filePath)] ?? file.type ?? 'application/octet-stream',
        'cache-control': 'no-cache',
      },
    })
  },
})

console.log(`vshell-web: root=${base}`)
if (plugin) console.log(`vshell-web: backend=${backendPath}`)
if (upstream) console.log(`vshell-web: proxying to ${upstream}`)
console.log(`vshell-web: listening on http://${host}:${server.port}/`)
