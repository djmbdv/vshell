# vshell

A **V-native desktop shell** for the **web** build of VS Code.

- **Renderer:** WebKit + JavaScriptCore (via Ultralight). **No V8.**
- **Server** (extension host, FS, PTY): **Bun**, which also runs on JavaScriptCore.
- **Bridge:** native V ↔ JS, both directions.

```
vshell (V, built with mingw-w64)
 ├─ Renderer: Ultralight C API  → WebKit + JavaScriptCore
 └─ Server:   Bun (child proc)  → JavaScriptCore
                     ↕ HTTP/WS   (no shared heap: V8 appears nowhere)
```

## Status

| | |
|---|---|
| Ultralight binding | ✅ real window on WebKit/JSC; `create_window`/`load_url`/`run`/`quit`, clean shutdown |
| Web build | ✅ `vscode-web` built on Bun, no node and no npm |
| Workbench | ✅ boots inside the engine (themes, keybindings, extension host worker) |
| JS ↔ V bridge | ✅ native `window.vshell` (frozen object) + `--eval` |
| Out of scope for now | DevTools (see *Inspector*), remote extension host (Phase 2 in the [ROADMAP](./ROADMAP.md)) |

## Requirements

| piece | why | how |
|---|---|---|
| **V 0.5.2** | builds the shell | `setup/install_v.ps1` |
| **MSYS2 + gcc (ucrt64)** | links the C binding | `setup/install_toolchain.ps1` |
| **Bun** | builds and serves the web artifact | [bun.sh](https://bun.sh) |
| **Ultralight SDK 2.0.0-beta.2 (free, win-x64)** | the WebKit/JSC engine | download and extract into `.work/ul-sdk` |

The SDK must end up like this (this is what `engine/ultralight.v` and the build's
staging step expect):

```
.work/ul-sdk/
├── include/     (AppCore/CAPI.h, Ultralight/CAPI/*.h)
├── lib/         (AppCore.lib, Ultralight.lib, UltralightCore.lib, WebCore.lib)
└── resources/   (icudt67l.dat, cacert.pem)
```

Check the rest with `setup/check_env.ps1`.

> **From PowerShell, always go through Git bash** rather than calling the scripts
> directly: `& 'C:\Program Files\Git\bin\bash.exe' -lc 'sh scripts/run.sh'`.
> PowerShell mangles `$(...)`, `|` and nested quotes, which has cost several
> debugging sessions already.

## Quickstart

```sh
# 0) one time only: toolchain and the Ultralight SDK (see Requirements)

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
| `--engine <name>` | engine to use (`ultralight`) |
| `--port <n>` | Bun server port |
| `--web-root <dir>` | directory to serve (defaults to `web/public`) |
| `--devtools` | developer mode + attempt the remote inspector |
| `--eval '<js>'` | evaluate JS once the page is live (repeatable) |

### JS ↔ V bridge

The page sees `window.vshell`, a **frozen** object holding real native functions
(no polling, no injected shim):

```js
vshell.version                                 // "vshell-bridge-2"  (constant)
vshell.post('name', JSON.stringify({a: 1}))    // JS -> V call
```

On the V side it lands in the engine's inbox, which the run loop drains:

```
vshell: js->v name {"a":1}
```

In the other direction, `engine.eval_js('<js>')` returns the value as a string
(`--eval` is the CLI version). The payload **crosses as a string**: pass
`JSON.stringify(obj)` from the page.

API details, plus the origin and timing gotchas: `docs/ARCHITECTURE.md`.

## Layout

```
vshell/
├── main.v                     entrypoint: starts the server, opens the window, runs the loop
├── server.v                   launches and watches the Bun child process
├── engine/
│   ├── engine.v               Engine interface (keeps the shell decoupled from the engine)
│   └── ultralight.v           Ultralight binding + JS↔V bridge  ← the core
├── web/
│   ├── serve.js               Bun server; renders the workbench host page
│   └── public/                vscode-web artifact (generated; not versioned)
├── scripts/                   see scripts/README.md
├── docs/ARCHITECTURE.md       engines, IPC, licensing, risks
└── ROADMAP.md                 phases and acceptance criteria
```

## Inspector / DevTools

`ulStartRemoteInspectorServer()` is **not available in the Free edition** of
Ultralight (verified at runtime: it returns `false`). The **local** inspector does
exist, but using it means replicating the `ULPanelDesc`/`ULLayoutSize` structs in
V, docking a second panel and copying `inspector/` into `assets/inspector/` —
out of proportion for now. `--devtools` turns developer mode on and probes the
remote inspector, reporting the result.

## Design notes

- **No V8.** Ultralight is a WebKit port with JavaScriptCore, and Bun also uses
  JSC: a single engine family across the whole stack.
- **`vscode` is not a submodule.** It is consumed as a *build input*: cloned at a
  pinned SHA into `.work/vscode`, patched, and the web assets are built from it.
  The tree is regenerated, never edited.
- **The patches live in one place:** `scripts/lib/configure_vscode_for_bun.sh`,
  idempotent and re-applied on every build. Do not edit `.work/vscode/**` by hand.
- **Licensing:** Ultralight's WebKit fork is partly LGPL, but the complete source
  is Enterprise. Review before distributing (see `docs/ARCHITECTURE.md`).

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
