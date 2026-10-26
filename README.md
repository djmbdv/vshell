# vshell

A **desktop shell written in V**, on **WebKit**, as an alternative to Electron.
**No V8, no Node**: the renderer is WebKit (the *WinCairo* port, WebKit2 C API,
JavaScriptCore), and the one JavaScript interpreter the shell ever starts is
**Bun**, as a child process.

```
vshell (V, built with mingw-w64)
 ├─ Renderer:  WebKit2 / WinCairo  → WebKit + JavaScriptCore
 ├─ Origin:    Bun (child)         → static root, HTTP + WS proxy, embedder plugin
 └─ Bridge:    window.vshell       → native V ↔ JS, both directions
```

## What this is (and what it is not)

vshell owns **mechanisms**. It has no idea what application is inside the window:

| the shell provides | the embedder decides |
|---|---|
| a native window + DPI + title/URL sync | what URL to load |
| a static HTTP server, an HTTP/WS reverse proxy that acts as the origin | what the app is, and what it stores where |
| a job object that kills every child the shell started | which child to start (`--run`) and with which arguments |
| `window.vshell` (frozen): `post`, `call`, `host`, `on`, `dialog.openFolder` | what the payload means, what a menu command is called |
| a Win32 menu bar built from JSON, dispatched as `menu` events | every command that is not the shell's own |
| an HTTP **plugin slot** for routes only the embedder knows | the routes themselves |

**codebun** (a VS Code distribution on Bun) is the reference embedder: it lives in
its own repository and owns everything VS Code-shaped — the checkout, the Bun
patches, the REH and web builds, the browser extension, the session-token
protocol, the menu vocabulary, the launcher. Nothing VS Code-specific lives here.
See [codebun](https://github.com/djmbdv/codebun).

## Status

| | |
|---|---|
| **WebKit binding (WinCairo)** | ✅ built, linked, running: boots a real page inside our own WebKit2 build, with `WebKitWebProcess` / `WebKitNetworkProcess` / `WebKitGPUProcess` all alive |
| JS ↔ V bridge | ✅ frozen `window.vshell` + `--eval`, `--inject`, `--script` |
| Native chrome | ✅ Win32 menu bar from `--menu` JSON, per-monitor DPI, title/URL pushed by WebKit |
| Server | ✅ static root + HTTP/WS proxy + `--backend` plugin (`--serve`, `--proxy`, `--run`) |
| Child lifetime | ✅ one job object per shell; killing the shell leaves nothing behind |
| DevTools | ✅ the real Web Inspector (`--devtools`) |
| Ultralight binding (legacy) | ⏸️ archived as `engine/ultralight.v.disabled` (see *ROADMAP*, Phase 1b) |

## Requirements

| piece | why | how |
|---|---|---|
| **V 0.5.2** | builds the shell | `scripts/setup/install_v.ps1` |
| **MSYS2 + gcc (ucrt64)** | links the C binding | `scripts/setup/install_toolchain.ps1` |
| **Bun** | the origin/plugin child, and the only JS interpreter in the stack | [bun.sh](https://bun.sh) |
| **WebKit (WinCairo), Windows x64** | the engine | `perl Tools/Scripts/build-webkit --release` in a `WebKit/WebKit` checkout, then stage it |

The engine is normalised into `.work/wk/` by `scripts/stage_runtime.sh`:

```
.work/wk/
├── include/WebKit/*.h   public C API headers, flattened like a real install
├── lib/libWebKit2.a     MinGW import library (gendef + dlltool over WebKit2.dll)
└── runtime/             WebKit2.dll, WebKitWebProcess.exe, WebKitNetworkProcess.exe
                         + the WebKitRequirements DLLs (cairo, libcurl, ICU, ...)
```

`WK_SRC` and `WK_BUILD` point at the checkout and its `WebKitBuild/Release`.
`scripts/build_vshell.sh` runs the staging itself the first time, so after the
engine is built a plain `sh scripts/build_vshell.sh` is enough.

> **From PowerShell, always go through Git bash** rather than calling the scripts
> directly: `& 'C:\Users\Lenovo\msys64\usr\bin\bash.exe' -lc 'sh scripts/run.sh'`.
> PowerShell treats a backtick and `$(...)`/`|`/nested quotes as its own syntax,
> which has cost several debugging sessions already.

## Build and run

```sh
sh scripts/build_vshell.sh          # build the shell (+ stage the engine if needed)
sh scripts/run.sh                   # build if missing, then run against web/public
sh scripts/run.sh -- --port 9000    # anything after -- is passed to the shell
```

## CLI

| flag | effect |
|---|---|
| `--engine <name>` | `webkit` (the only one; Ultralight is archived) |
| `--url <url>` | load a page from a server this process does **not** start. No server, no upstream |
| `--port <n>` | the shell's own server port (default 8123) |
| `--serve <dir>` | static root to serve (default: the `web/public` next to the executable, else `.`) |
| `--proxy <base>` | become the **origin** and forward everything (HTTP and the WebSocket upgrade) to `<base>`; see `web/proxy.js` for why the shell terminates the socket |
| `--run <exe>` `--run-arg <a>` | start a child (repeatable args), inside the job object, and wait until its port answers |
| `--backend <file>` | JS module the server mounts as a plugin (routes + websocket handlers); contract in `web/serve.js` |
| `--inject '<json>'` / `--inject @file` | opaque payload, delivered to the page as `window.vshell.host` |
| `--script <file>` | extra JS injected after the bridge, in order (repeatable) |
| `--menu '<json>'` / `--menu @file` | native menu bar as data (`{ "menus": [ { "label", "items": [...] } ] }`); no `--menu` = the shell's own File/View/Help |
| `--folder <path>` / `--open-folder` | merge (or ask for) a folder into the payload as `"folder"` |
| `--eval '<js>'` | evaluate JS once the page is live (repeatable) |
| `--devtools` | developer mode + open the inspector |
| `--no-cache` | proxy/plugin answer `Cache-Control: no-store` while iterating |
| `--serve`/`--web-root` | aliases |

`VSHELL_WS_DEBUG=1` prints a line every 200 WebSocket messages the proxy relays —
the quickest way to tell "the app is busy" from "the shell is talking to itself".

## The bridge

The page sees `window.vshell`, a **frozen** object with real native functions
(no polling, no injected shim):

```js
vshell.version                                  // "vshell-bridge-wk"
vshell.host                                     // the --inject payload, as parsed JSON
vshell.post('name', JSON.stringify({ a: 1 }))   // JS -> V, one way
await vshell.call('dialog.openFolder')          // -> absolute path, or '' if cancelled
vshell.on('menu', command => { /* native menu item chosen */ })
vshell.errors                                   // page errors + rejections, collected for --eval
```

In the other direction `engine.eval_js('<js>')` returns the value as a string;
`--eval` is the CLI form of it. Payloads **cross as strings**: return
`JSON.stringify(obj)` from the page.

> Pass an `--eval` script as **one** shell argument. On Windows the command line is
> split on spaces, so `--eval 'typeof window.x'` arrives as two tokens; the shell
> joins everything up to the next flag, and the failure message names the fragment
> it actually evaluated.

With the WebKit backend the bridge is injected as a `WKUserScript` that posts
through `window.webkit.messageHandlers.vshell`, and `eval_js` is asynchronous
underneath (the V side pumps messages until the callback arrives). A page with a
strict CSP blocks that inline injection, so the pump injects the same script again
after the load — it is idempotent, and it also carries `--script` files.

`--script` files run **after** the bridge and before the page's own code, which is
exactly where an embedder translates its payload into whatever it needs (codebun's
`integration/bridge.js` republishes the session token on a BroadcastChannel, for
instance).

## Server and plugin slot

`web/serve.js` is deliberately small: a static root, an optional upstream proxy,
and one plugin hook. Everything application-shaped belongs to the embedder:

```js
// --backend module
export const websocket = { open() {}, message() {} }   // optional: Bun ws handlers
export const UPGRADED = Symbol('mine:upgraded')        // optional sentinel
export async function handle({ req, url, pathname, server, root, noCache }) {
  // return a Response to answer, UPGRADED to let Bun finish an upgrade you
  // started, or undefined to fall through to the proxy / static root
}
```

The plugin is consulted **first** — before the proxy and before the static root —
so no file and no upstream path can shadow its routes. In `--proxy` mode it still
runs, which is how an embedder keeps its own endpoints when the page comes from
somebody else's server.

## Layout

```
vshell/
├── main.v                 entrypoint: server, window, menu, payload, CLI
├── server.v               launches and watches the Bun child
├── proc_job.v             one Win32 job object per shell (no orphans)
├── engine/
│   ├── engine.v           Engine interface + MenuItem (engine-agnostic shell)
│   ├── webkit.v           WebKit (WinCairo) backend + JS↔V bridge  ← the core
│   ├── wk_host.h          C glue: Win32 window, DPI, menu bar, WKViewCreate
│   └── ultralight.v.disabled  archived backend
├── web/
│   ├── serve.js           static root + proxy + plugin slot
│   └── proxy.js           reverse proxy that terminates the WebSocket
├── scripts/               build/stage/run — see scripts/README.md
├── docs/ARCHITECTURE.md    engines, IPC, licensing, risks
└── ROADMAP.md              phases and acceptance criteria
```

## Design notes

- **No V8.** The renderer is WebKit (WinCairo, JavaScriptCore) and Bun also uses
  JSC: one engine family across the whole stack.
- **No Node.** Bun is the only JavaScript interpreter the shell starts. An embedder
  that needs Node-only build steps is the embedder's business, not the shell's.
- **The shell never re-enters itself.** A Win32 message handler only records what
  happened; the run loop dispatches it. Menu items carry a label and a command,
  never a callback.
- **Child lifetime is not a promise, it is a job object**
  (`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`): whatever the shell starts dies with it,
  including a hard kill with Task Manager.
- **Licensing:** WebKit upstream (WinCairo) is LGPL-2.1 + BSD, with no commercial
  edition. Shipping `WebKit2.dll` as a separate DLL is the standard way to comply;
  if you patch the engine, publish those patches. The Enterprise-licence question
  belongs to the archived Ultralight backend.

## Inspector / DevTools

`--devtools` opens the **real Web Inspector** (`WKPageGetInspector` +
`WKInspectorDetach/Show`) in its own window. That is exactly what Ultralight's
Free edition could not give: `ulStartRemoteInspectorServer()` returns `false`
there (verified at runtime).

## Repository

Repo: **https://github.com/djmbdv/vshell** — the shell only. The application that
consumes it lives in its own repository, so the two can be versioned, built and
released independently.
