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
//
// --------------------------------------------------------------------------
// SECURITY — this is NOT a boundary yet.
//
// The only check below is that `Origin` matches the request's own `Host`. That
// stops a random web page in a browser from reaching it, and nothing else: any
// local process can send both headers and look identical to it. The intended
// design is a token delivered out-of-band (shell -> page -> extension), which is
// not implemented. Until it is, treat everything this service exposes as
// reachable by any process running as this user, and do not add anything to it
// that you would not hand to an unauthenticated local caller.
//
// That is also why `delete` returns 501 instead of deleting: a destructive,
// recursive, unauthenticated endpoint is a footgun, and the milestone that needs
// it ("open a folder, save a file") does not. Implement it together with the
// token, not before.
// --------------------------------------------------------------------------

import { mkdir, readdir, readFile, stat, writeFile } from 'node:fs/promises'
import * as path from 'node:path'

export const BACKEND_PREFIX = '/codebun/backend'

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

// `Origin` cannot do the job this check was written for, in either direction:
//
//   * A browser omits `Origin` on same-origin requests, and the extension host
//     runs in a worker on the same origin as the workbench. Requiring the header
//     (the first version of this function did) rejects the GETs the editor needs,
//     which is how it was caught: readdir/read/stat would all have failed.
//   * Anything can send `Origin`, so it never was a boundary against a local
//     process either. It only filters a random web page that reaches the port.
//
// So this is a coarse filter and is documented as such: when the header is absent
// the caller is not a browser, and when it is present it must match the host. That
// is NOT authentication — the token described in the header comment is, and it is
// required before anything destructive is added. `delete` stays 501 until then.
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

export async function handleBackend(req, pathname) {
  if (!pathname.startsWith(BACKEND_PREFIX)) {
    return undefined
  }
  if (!callerLooksLikeThePage(req)) {
    return jsonError(403, 'origin check failed')
  }

  const route = pathname.slice(BACKEND_PREFIX.length)
  const url = new URL(req.url)
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
