# `codebun-backend`

The workbench side of the Codebun backend: file system, and later terminal and
search. It is an ordinary **web extension**, with three requirements that are not
optional in this build:

| piece | why |
| --- | --- |
| `"browser": "./dist/browser/extension"` in `package.json` | without it the web extension host treats the extension as desktop-only and never activates it |
| `esbuild.browser.mts` | `build/lib/extensions.ts` looks for **exactly** this name for the web target, and the fallback to `.esbuild.mts` is disabled for web (`if (!hasEsbuild && !forWeb)`) |
| `tsconfig.browser.json` | the web typecheck step uses it; it extends `tsconfig.json` |

It also has to be a **direct child of `extensions/`**, because
`esbuild.browser.mts` imports `../esbuild-extension-common.mts`.

## Two traps that cost real time here

**The folder must not be opened through the URL.** `vscode.openFolder` reloads the
page with `?folder=<uri>`, and the workbench resolves that folder *before* the web
extension host has started, so the provider is missing every time: it logs "Unable to
resolve filesystem provider", discards the folder, reloads again, and the page ends
up blank. The folder is added to the running window with `updateWorkspaceFolders`
instead. Measured details and the reasoning are in `docs/ARCHITECTURE.md` §3.2.

**`fetch` needs an absolute URL.** The extension host runs in a Web Worker
(`WorkerGlobalScope`), where a relative path such as `/codebun/backend/hello` has
nothing to resolve against and fails with "Failed to parse URL". The base comes from
the worker's own `location.origin`.

## Where the source lives, and why it is copied

The source is kept **here**, in the shell repo, and `scripts/lib/configure_vscode_for_bun.sh`
copies it into the checkout on every configure. The checkout is disposable —
`fetch_vscode_web.sh` runs `git reset --hard` — so anything written directly there
disappears on the next build. Copying it in on each configure is what makes the two
survive each other.

## Why this extension exists at all

The VS Code **web** build has no access to the real file system and no terminal.
`web/serve.js` only serves static files and renders the host page template, so
"open folder" cannot work without a backend. The desktop build gets this from
Electron; the web build gets it from a server (`vscode-reh-web`) or from a web
extension like this one. See `docs/ARCHITECTURE.md` §3.1 for the trade-off: this
route keeps everything on Bun but only runs **web** extensions, so Python, C++ or
ESLint (Node extensions) stay out until Phase 2b.

## Native menu commands

`main.v#build_menu` builds the shell's Win32 menu bar; the engine handles the four
commands it owns (`app.quit`, `view.reload`, `view.devtools`, `help.about`) and
forwards the rest to the page as `window.__codebunMenu(command)`. That lands here as
`{ type: "codebun:menu", command }` on the bootstrap channel, and `MENU_COMMANDS`
maps it to a VS Code command:

| shell command | VS Code command |
| --- | --- |
| `file.openFolder` | `codebun.openFolder` |
| `terminal.new` | `codebun.terminal.new` |

Unlike the request/response helpers, this channel stays open for the whole session:
it waits for events, not for a reply.

## Security
The Bun service listens on `127.0.0.1` and is gated by a **per-run token**, not only
by `Origin`. The shell generates 256 random bits at startup (`main.v`, `new_token`),
exports them as `VSHELL_TOKEN` before spawning the Bun child, and delivers them to
the page **out of band**: the engine injects them as a document-start user script
(`engine/webkit.v`, `build_user_script`), so the token never travels in a URL and
never appears in an HTTP response a local process could fetch.

The page re-broadcasts `{ token, folder }` on a same-origin `BroadcastChannel`
(`codebun-bootstrap`); the extension host worker answers with the same channel, and
from then on sends the token on every call as `X-Codebun-Token`. A WebSocket cannot
carry request headers, so the terminal passes the same secret as `?token=` (the
server accepts either carrier, it is the same check). The service answers `401`
before routing when the token is missing or wrong, and `403` when a request carries
an `Origin` that does not match `Host`.

What that boundary *is*: “the engine delivered the page”. The token's secrecy rests
on the BroadcastChannel being origin-scoped and not network reachable — not on
cryptography against a local process that can already inject script into that
origin. Do not describe it as isolation. When no token is set (standalone
`bun run web/serve.js`, the dev case) the service is **open**, which is why
destructive endpoints are gated behind an explicit decision:

| endpoint | state |
| --- | --- |
| `stat`, `readdir`, `read`, `write`, `mkdir` | implemented, token required when the shell runs |
| `delete` | **501** on purpose: destructive, lands together with a test that the 401 path fires |
| `rename` (extension) | throws: a wrong rename loses data, so it is not faked |
