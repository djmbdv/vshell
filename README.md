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
| DevTools | ✅ real **Web Inspector** with the WebKit backend (`--devtools`) |
| Next | our own backend — web extension + Bun service (Phase 2 in the [ROADMAP](./ROADMAP.md)) |
| Out of scope for now | Node-based extensions and the remote extension host (Phase 2b) |

## Requirements

| piece | why | how |
|---|---|---|
| **V 0.5.2** | builds the shell | `setup/install_v.ps1` |
| **MSYS2 + gcc (ucrt64)** | links the C binding | `setup/install_toolchain.ps1` |
| **Bun** | builds and serves the web artifact | [bun.sh](https://bun.sh) |
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
# 0) one time only: toolchain (V + MSYS2/gcc) and the WebKit build (see Requirements)

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

With the WebKit backend, `window.vshell` is injected as a `WKUserScript` that posts
through `window.webkit.messageHandlers.vshell`, and `eval_js` is **asynchronous**
underneath (the V side pumps messages until the callback arrives, 3 s timeout).
For any value that is not a string, return `JSON.stringify(...)` from the page: only
strings come back directly.

API details, plus the origin and timing gotchas: `docs/ARCHITECTURE.md`.

## Layout

```
vshell/
├── main.v                     entrypoint: starts the server, opens the window, runs the loop
├── server.v                   launches and watches the Bun child process
├── engine/
│   ├── engine.v               Engine interface (keeps the shell decoupled from the engine)
│   ├── webkit.v               WebKit (WinCairo) backend + JS↔V bridge  ← the core
│   ├── wk_host.h              C glue: the Win32 window + WKViewCreate (RECT by value)
│   └── ultralight.v           Ultralight binding (legacy backend)
├── web/
│   ├── serve.js               Bun server; renders the workbench host page
│   └── public/                vscode-web artifact (generated; not versioned)
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
