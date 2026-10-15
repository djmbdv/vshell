#!/usr/bin/env bun
// vshell web server.
//
// Serves the VS Code *web* build (the assets the workbench loads in a browser)
// to the embedded view. Launch by the V shell as a child process, or standalone:
//
//   bun run web/serve.js --port 8123 --root web/public

import { join } from 'node:path'

import { handleBackend } from './backend.js'

const argv = process.argv.slice(2)
const opt = (name, def) => {
  const i = argv.indexOf(`--${name}`)
  return i !== -1 && argv[i + 1] ? argv[i + 1] : def
}

const port = Number(opt('port', process.env.VSHELL_PORT ?? '8123'))
const host = opt('host', process.env.VSHELL_HOST ?? '127.0.0.1')
const root = opt('root', process.env.VSHELL_WEB_ROOT ?? join(import.meta.dir, 'public'))
const base = root.replace(/[\\/]+$/, '')
// VSHELL_ACCESS_LOG=1 logs every request: handy to watch the embedded engine
// load the workbench (the V shell inherits the env and passes it to this child).
const accessLog = process.env.VSHELL_ACCESS_LOG === '1'

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

// ---- workbench host page ---------------------------------------------------
//
// out/vs/code/browser/workbench/workbench.html is a TEMPLATE: VS Code's own
// server fills its {{...}} placeholders (see src/vs/server/node/webClientServer.ts).
// Two things differ in this build:
//   * the esbuild pipeline this fork builds with emits
//     out/vs/workbench/workbench.web.main.internal.{js,css}, while the template
//     still names the legacy out/vs/code/browser/workbench/workbench.{js,css}
//   * the build runs with NLS off (VSHELL_NLS), so no nls.messages.js exists and
//     the two NLS module scripts are dropped instead of 404ing
const TEMPLATE_PATH = base + '/out/vs/code/browser/workbench/workbench.html'
const CALLBACK_PATH = '/out/vs/code/browser/workbench/callback.html'

// product versions and the built-in extensions list are already compiled into the
// bundle (build/lib/gulpfile.vscode.web.ts replaces INSERT_PRODUCT_CONFIGURATION
// and INSERT_BUILTIN_EXTENSIONS), so the host only supplies what is read at runtime.
// The JSON goes inside an HTML attribute, so its quotes must be escaped — exactly
// what VS Code's asJSON() does (src/vs/server/node/webClientServer.ts).
const WORKBENCH_CONFIG = JSON.stringify({ callbackRoute: CALLBACK_PATH }).replace(/"/g, '&quot;')

// the bundle name is stable-ish but the suffix has changed once; probe the known ones
async function findMainBundle(ext) {
  for (const name of ['workbench.web.main.internal', 'workbench.web.main', 'workbench.web']) {
    const rel = `/out/vs/workbench/${name}${ext}`
    if (await Bun.file(base + rel).exists()) return rel
  }
  return undefined
}

async function renderHostPage() {
  let html = await Bun.file(TEMPLATE_PATH).text()

  html = html
    .replaceAll('{{WORKBENCH_WEB_BASE_URL}}', '')            // root-relative URLs
    .replaceAll('{{WORKBENCH_WEB_CONFIGURATION}}', WORKBENCH_CONFIG)
    .replaceAll('{{WORKBENCH_AUTH_SESSION}}', '')            // no auth session (the server passes '' too)

  // no NLS files were built: drop those two script tags instead of 404ing
  html = html.replace(/^.*\{\{WORKBENCH_NLS_(?:FALLBACK_)?URL\}\}.*\r?\n/gm, '')

  // The template names out/vs/code/browser/workbench/workbench.{js,css}. The JS
  // bootstrap is built (buildfile.codeWeb); that entry's CSS is not, so map only
  // the files that are actually missing onto the main bundle.
  for (const ext of ['.js', '.css']) {
    const legacy = `/out/vs/code/browser/workbench/workbench${ext}`
    if (await Bun.file(base + legacy).exists()) continue
    const found = await findMainBundle(ext)
    if (found) {
      html = html.replaceAll(legacy, found)
    } else {
      console.warn(`vshell-web: WARNING neither ${legacy} nor a workbench.web.main${ext} fallback exist`)
    }
  }

  return html
}

const server = Bun.serve({
  hostname: host,
  port,
  async fetch(req) {
    const url = new URL(req.url)
    // Collapse repeated slashes: the template computes its file root as
    // `new URL(<base>, origin) + '/out/'`, which yields '//out/...'.
    const pathname = decodeURIComponent(url.pathname).replace(/\/{2,}/g, '/')
    if (accessLog) console.log(`vshell-web: ${req.method} ${pathname}`)

    // The Codebun backend (filesystem for now, terminal and search later).
    // Mounted before the static handling so no file named like a route can
    // shadow it. See web/backend.js.
    const backend = await handleBackend(req, pathname)
    if (backend) return backend

    // The workbench host page (a rendered template, not a static file).
    if (pathname === '/' || pathname === '/index.html') {
      return new Response(await renderHostPage(), {
        headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' },
      })
    }

    // packageTask() copies resources/server/* to the root of the build, while the
    // template asks for them under /resources/server/.
    const alias = pathname.match(/^\/resources\/server\/(.+)$/)
    const filePath = alias ? `${base}/${alias[1]}` : base + pathname
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
console.log(`vshell-web: listening on http://${host}:${server.port}/`)
