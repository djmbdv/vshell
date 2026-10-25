# vshell

A **V-native desktop shell** for the **web** build of VS Code.

- **Renderer:** **WebKit upstream** (the *WinCairo* port, WebKit2 C API). **No V8.**
- **Server** (extension host, FS, PTY): **Bun**, which also runs on JavaScriptCore.
- **Bridge:** native V ↔ JS, both directions.

```
vshell (V, built with mingw-w64)
 ├─ Renderer: WebKit2 / WinCairo  → WebKit + JavaScriptCore
 └─ Server:   Bun (child proc)    → JavaScriptCore
                     ↕ HTTP/WS   (no shared heap: V8 appears nowhere)
```

## Status

| | |
|---|---|
| **WebKit binding (WinCairo)** | ✅ **built, linked and verified running**: boots the workbench inside our own WebKit2 build. `--eval 'document.title'` → `Welcome - Code - OSS`, `--eval 'window.vshell.version'` → `vshell-bridge-wk`, with `WebKitWebProcess` / `WebKitNetworkProcess` / `WebKitGPUProcess` all alive. |
| Ultralight binding (legacy) | ⏸️ archived as `engine/ultralight.v.disabled`. It carried unconditional `#flag -lAppCore -lUltralight -lUltralightCore -lWebCore` lines, so merely having the file inside the module made *every* link require the Ultralight SDK, even with the WebKit engine in use (see *ROADMAP*, Phase 1b). |
| Web build | ✅ `vscode-web` built on Bun, no node and no npm |
| Workbench | ✅ boots inside the engine (themes, keybindings, extension host worker) |
| JS ↔ V bridge | ✅ native `window.vshell` (frozen object) + `--eval` |
| Native chrome | ✅ Win32 **menu bar** (File/View/Help) with a real command path into both the engine and the workbench; per-monitor DPI; title/URL **pushed** by WebKit instead of polled |
| DevTools | ✅ real **Web Inspector** with the WebKit backend (`--devtools`) |
| Backend (Phase 2) | ✅ our own: web extension (`extensions/codebun-backend`) + Bun service (`web/backend.js`) — folder picker, `codebun:` file system, and the integrated terminal (PTY over WebSocket, `bun-pty`). Workspace search and last-folder persistence are still open |
| Next | workspace search, persisted last folder, then the shell's own UI (Phase 3 in the [ROADMAP](./ROADMAP.md)) |
| Out of scope for now | Node-based extensions and the remote extension host (Phase 2b) |

## Requirements

| piece | why | how |
|---|---|---|
| **V 0.5.2** | builds the shell | `setup/install_v.ps1` |
| **MSYS2 + gcc (ucrt64)** | links the C binding | `setup/install_toolchain.ps1` |
| **Bun** | **the only JavaScript interpreter in the project** — builds and serves the web artifact, runs the backend service, *and* stands in for `node` at build time (`scripts/tools/node`, because some third-party `binding.gyp` files shell out to `node -p`). Also installs `node-gyp` as the compile driver for the REH's native addons | [bun.sh](https://bun.sh) |
| **VS Build Tools** *(only to build the REH's natives)* | `node-gyp` compiles `node-pty`, `spdlog`, `deviceid`, `windows-registry`, `sqlite3` with it: needs **Desktop development with C++**, a **Windows SDK** and the **Spectre-mitigated libs**. No Node, no npm | [VS installer](https://visualstudio.microsoft.com/downloads/) |
| **WebKit (WinCairo), Windows x64** | the engine | `perl Tools/Scripts/build-webkit --release` in a `WebKit/WebKit` checkout, then stage it (below). There is no SDK to download. |
| *Optional:* Ultralight SDK 2.0.0-beta.2 (free, win-x64) | only to re-enable the archived backend: `mv engine/ultralight.v.disabled engine/ultralight.v` and restore its branch in `new_engine()` | download and extract into `.work/ul-sdk` |

The engine is normalised into `.work/wk/` by `scripts/stage_runtime.sh`:

```
.work/wk/
├── include/WebKit/*.h   public C API headers, flattened like a real install
├── lib/libWebKit2.a     MinGW import library (gendef + dlltool over WebKit2.dll)
└── runtime/             WebKit2.dll, WebKitWebProcess.exe, WebKitNetworkProcess.exe
                         + the WebKitRequirements DLLs (cairo, libcurl, ICU, ...)
```

`WK_SRC` and `WK_BUILD` point at the checkout and its `WebKitBuild/Release`; both
default to `C:\Users\Lenovo\projects\WebKit`. `scripts/build_vshell.sh` runs the
staging itself the first time, so after the engine is built a plain
`sh scripts/run.sh --rebuild` is enough.

Check the rest with `setup/check_env.ps1`.

> **From PowerShell, always go through Git bash** rather than calling the scripts
> directly: `& 'C:\Program Files\Git\bin\bash.exe' -lc 'sh scripts/run.sh'`.
> PowerShell mangles `$(...)`, `|` and nested quotes, which has cost several
> debugging sessions already.

## Quickstart

```sh
# 0) one time only: toolchain (V + MSYS2/gcc), the WebKit build (see Requirements)
#    and the service's own dependencies (bun-pty, for the terminal)
bun install

# 1) build the web artifact (slow the first time, see below)
sh scripts/build_web.sh

# 2) build the shell and run it
sh scripts/run.sh --rebuild
```

`run.sh` tells you if step 1 is missing. While iterating, the shell rebuilds in
seconds: `sh scripts/build_vshell.sh`.

### How long the web build takes

| mode | time | when |
|---|---|---|
| `sh scripts/build_web.sh` | ~15-40 min | first time, or when switching commits |
| `VSHELL_FAST=1 sh scripts/build_web.sh` | **~40 s** | while iterating: reuses `.work/vscode` and its dependencies |

The first build clones the VS Code fork at a pinned SHA into `.work/vscode`,
installs what the web build needs and bundles everything. `VSHELL_FAST=1` skips
the fetch and the install but **still re-applies the patches**, so it is the
normal mode while working on the engine.

Each script, its environment variables and why every patch exists:
[`scripts/README.md`](./scripts/README.md).

## Usage

```sh
sh scripts/run.sh                                  # 1280x800, port 8123
sh scripts/run.sh --devtools                       # developer mode + inspector probe
sh scripts/run.sh --eval 'document.title'          # run JS in the page and print the result
sh scripts/run.sh -- --port 9000 --web-root web/public
```

| flag | effect |
|---|---|
| `--engine <name>` | engine to use: `webkit`. It is the only one; the Ultralight backend is archived as `engine/ultralight.v.disabled` |
| `--port <n>` | Bun server port |
| `--web-root <dir>` | directory to serve (defaults to `web/public`) |
| `--devtools` | developer mode + open the engine's inspector |
| `--eval '<js>'` | evaluate JS once the page is live (repeatable) |
| `--open-folder` | ask for the workspace with the shell's **native** folder dialog before the window opens (what `scripts/run.sh` does by default) |
| `--folder <path>` | open that folder directly, no dialog |
| `--url <url>` | load a server this process does **not** start (any static host). `--port`/`--web-root` are then ignored |
| `--reh <url>` | load a `vscode-reh-web` **through the shell**: the Bun server becomes the origin and proxies to it, terminating the WebSocket itself (see *Remote extension host* below) |

### JS ↔ V bridge

The page sees `window.vshell`, a **frozen** object holding real native functions
(no polling, no injected shim):

```js
vshell.version                                 // "vshell-bridge-wk" (WebKit) / "vshell-bridge-2" (Ultralight)
vshell.post('name', JSON.stringify({a: 1}))    // JS -> V call
```

On the V side it lands in the engine's inbox, which the run loop drains:

```
vshell: js->v name {"a":1}
```

In the other direction, `engine.eval_js('<js>')` returns the value as a string
(`--eval` is the CLI version). The payload **crosses as a string**: pass
`JSON.stringify(obj)` from the page.

`--eval` (the CLI) goes through `eval_js_checked()`, which is friendlier than the
engine call: exceptions are reported instead of silently turning into an empty
line, and a non-string value is JSON-encoded for you.

```sh
sh scripts/run.sh --eval '"document.title"'          # strings: quote it, see below
sh scripts/run.sh --eval '"({a:1})"'                 # -> {"a":1}
sh scripts/run.sh --eval '"null.x"'                  # -> eval failed: TypeError: ...
```

> Pass the script as **one** shell argument. On Windows the command line is split on
> spaces, so `--eval 'typeof window.showDirectoryPicker'` arrives as `typeof` and the
> rest is silently dropped — the failure message now names the fragment that was
> actually evaluated.

With the WebKit backend, `window.vshell` is injected as a `WKUserScript` that posts
through `window.webkit.messageHandlers.vshell`, and `eval_js` is **asynchronous**
underneath (the V side pumps messages until the callback arrives, 3 s timeout).
For any value that is not a string, return `JSON.stringify(...)` from the page: only
strings come back directly.

Next to `post`, the injected script exposes a request/response call and the shell's
session data (details in `docs/ARCHITECTURE.md` §3.3):

```js
await vshell.call('dialog.openFolder')         // -> absolute path, or '' if cancelled
window.__codebunBootstrap                      // { token, folder }  (out of band, not a URL)
```

### Native menu

`main.v#build_menu` declares the bar as `engine.MenuItem`s (label + command).
`engine/webkit.v#run_menu_command` handles the four commands the shell owns
(`app.quit`, `view.reload`, `view.devtools`, `help.about`) and forwards every
other one to the page as `window.__codebunMenu(command)`, which re-broadcasts
`{ type: "codebun:menu", command }` on the bootstrap channel. The extension maps
those to VS Code commands (`MENU_COMMANDS` in `extensions/codebun-backend`), so
adding a menu item for an existing workbench command costs no V change.

API details, plus the origin and timing gotchas: `docs/ARCHITECTURE.md`.

### Remote extension host (experimental)

```sh
sh scripts/build_reh.sh --natives   # once: the native addons (needs VS C++ + SDK + Spectre libs)
sh scripts/build_reh.sh --run       # serves the REH on 127.0.0.1:8137
bin/vshell.exe --reh http://127.0.0.1:8137/
```

`--reh` makes the shell the origin: its Bun server serves and proxies everything to
the REH and **terminates the WebSocket itself**, piping messages to it. That is not
decoration — measured: WebKit's `WebSocket` against the REH's own server (VS Code's
`ws` on `node:http`, under Bun) completes the handshake, receives a valid `101`, and
then never fires `open` (1006 after ~10 s). WebKit ↔ `Bun.serve` works, and Bun *as a
client* of the REH works, so the proxy is the seam that sidesteps it.

The proxy also forwards `x-forwarded-host`, which is where the REH builds the
workbench's `remoteAuthority` from; without it the page would send the client
straight to the REH and the socket would break again.

Verified: the remote extension host starts on Bun (`Launched Extension Host Process`,
exit code 0 on shutdown) with zero page errors.

## Layout

```
vshell/
├── main.v                     entrypoint: starts the server, opens the window, runs the loop;
│                              build_menu() is the shell's menu bar
├── server.v                   launches and watches the Bun child process
├── engine/
│   ├── engine.v               Engine interface + MenuItem (keeps the shell engine-agnostic)
│   ├── webkit.v               WebKit (WinCairo) backend + JS↔V bridge  ← the core
│   ├── wk_host.h              C glue: the Win32 window, DPI, menu bar, WKViewCreate
│   └── ultralight.v           Ultralight binding (legacy backend)
├── web/
│   ├── serve.js               Bun server; renders the workbench host page
│   ├── backend.js             Bun service behind the codebun: FS + terminal (token gated)
│   └── public/                vscode-web artifact (generated; not versioned)
├── extensions/codebun-backend web extension: FileSystemProvider, terminal, shell calls
├── scripts/                   see scripts/README.md
├── docs/ARCHITECTURE.md       engines, IPC, licensing, risks
└── ROADMAP.md                 phases and acceptance criteria
```

## Inspector / DevTools

With the **WebKit backend**, `--devtools` opens the **real Web Inspector**
(`WKPageGetInspector` + `WKInspectorDetach/Show`) in its own window.

That is exactly what Ultralight's Free edition could not give:
`ulStartRemoteInspectorServer()` returns `false` there (verified at runtime), and
using its local inspector would mean replicating `ULPanelDesc`/`ULLayoutSize` in V,
docking a second panel and copying `inspector/` into `assets/inspector/`.

## Design notes

- **No V8.** The renderer is WebKit (the WinCairo port, JavaScriptCore) and Bun also
  uses JSC: a single engine family across the whole stack.
- **No Node either, and that is enforced.** Bun is the only JavaScript interpreter in
  the project, at runtime *and* at build time. The two places Node used to leak in are
  closed: `node-gyp` is invoked as `bun node_modules/node-gyp/bin/node-gyp.js` (it
  reports `using node@26.x` because Bun emulates `process.versions`), and the few
  third-party `binding.gyp` files that shell out to `node -p "require(…)"` are answered
  by `scripts/tools/node`, a two-line shim that forwards to Bun. `build_reh.sh` also
  removes any `nodejs` directory from `PATH`, so a system Node cannot be picked up even
  by accident (`VSHELL_ALLOW_NODE=1` opts out). Verified by deleting a built addon and
  rebuilding it with Node off the path.
  The addons themselves are N-API: compiled once against the N-API headers, loaded by
  Bun, no Node runtime involved.
- **`vscode` is not a submodule.** It is consumed as a *build input*: cloned at a
  pinned SHA into `.work/vscode`, patched, and the web assets are built from it.
  The tree is regenerated, never edited.
- **The patches live in one place:** `scripts/lib/configure_vscode_for_bun.sh`,
  idempotent and re-applied on every build. Do not edit `.work/vscode/**` by hand.
- **Licensing:** the default engine is **WebKit upstream (WinCairo)**: LGPL-2.1 +
  BSD, with no commercial edition. Shipping `WebKit2.dll` as a separate DLL is the
  standard way to comply; if you patch the engine, publish those patches. The
  Enterprise-licence question belongs to the legacy Ultralight backend.

## Repository and workspace

Repo: **https://github.com/djmbdv/vshell**

`vshell` is a **standalone project** that *consumes* the VS Code fork, which is
why it has its own git repo instead of being versioned alongside the fork:

- The fork's `.gitignore` ignores any `VS*` directory (and on Windows that match is
  case-insensitive), so `vshell` would be **invisible** inside that repo. Depending
  on it was ruled out.
- `vshell.code-workspace` (in this folder) opens both folders at once — the fork and
  `vshell` — so each keeps its own git in the Source Control view. Open it with
  *File → Open Workspace from File…*.

Building **the shell** only needs this repo cloned (the fork is only needed for the
web artifact, and `scripts/build_web.sh` fetches it by SHA):

```sh
git clone https://github.com/djmbdv/vshell
cd vshell
```
