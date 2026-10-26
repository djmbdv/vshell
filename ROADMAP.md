# Roadmap — vshell

Goal: a **desktop shell of our own, written in V**, as an alternative to Electron:
a window with **WebKit + JavaScriptCore** (no V8) around any web application, plus a
**Bun** server that can act as the page's origin.

Overall success criterion: an application can be *driven* by this shell — folder,
editor, language server, integrated terminal — without a single line of that
application's policy living in this repository.

---

## Boundary (read before the phases)

The phases below were written while the shell and its first application lived in the
same repo. That is no longer true, and the split is now a rule:

| | owns |
|---|---|
| **vshell** (this repo) | the window, the engine, the static root, the HTTP/WS proxy that terminates sockets, the job object that owns children, the `window.vshell` bridge, menus and payloads as data, and the HTTP **plugin slot** (`--backend`) |
| **codebun** (separate repo) | the VS Code checkout and its Bun patches, the web/REH builds, the browser extension (file system provider, terminal, menu mapping), the session-token protocol, the launcher |

Consequences for the history below: `scripts/build_web.sh`, `scripts/build_reh.sh`,
`scripts/lib/*`, `scripts/tools/*`, `extensions/codebun-backend/`, `web/backend.js`,
the root `package.json` and `docs/perf-trim.md` **moved to the codebun repo**. The
shell flags they used are now data flags: `--reh <url>` became `--proxy <url>`,
`--reh-run <dir>` became `--run bun --run-arg …/server-main.js --proxy …`, and the
token/folder bootstrap became `--inject` + `--script`. Phases 0-3 are kept verbatim
as the record of what was measured; read them with that mapping in mind.

---

## Phase 0 — Risk probe (1-2 days) ⬅ *start here*

> **Historical record.** Phases 0 and 1 were done with the Ultralight backend, which
> **Phase 1b** then replaced. They are kept because the page-level findings still
> hold (vscode-web boots, 18 requests, 0 404s); what changed is the engine.

**Question to answer:** does the VS Code web workbench run correctly inside an
embedded WebKit?

- [x] `scripts/lib/fetch_vscode_web.sh` produces `web/public` with `vscode-web`.
- [x] The Bun server serves the assets (`bun run web/serve.js`).
- [x] Open `http://127.0.0.1:8123/` in the SDK's Ultralight **Browser sample** (Windows).
- [x] Verify: workbench boot, Monaco, theme, keybindings, DevTools.

**Note:** Phase 0 was validated **directly on the Phase 1 binding** (`vshell.exe`
opens the Ultralight window against the Bun server), not with the Browser sample:
18 requests, 0 404s, "Code - OSS" workbench rendered.

---

## Phase 1 — Ultralight binding in V (1-2 weeks) ✅ *done; kept as the legacy backend*

- [x] Install V (`scripts/setup/install_v.ps1`).
- [x] Copy the real signatures from `AppCore/CAPI.h` and `Ultralight/CAPI/*.h` into `engine/ultralight.v`.
- [x] `create_window` / `load_url` / `run` / `quit` working.
- [x] Callbacks (close) in V with the correct convention.
- [x] Build: `sh scripts/build_vshell.sh` (absolute `-I`/`-L` paths, DLLs +
      `assets/resources/` next to the exe).

**Acceptance:** `vshell.exe` opens a window showing the workbench served by Bun. ✅

**Still open in this phase:** resize callbacks and `load_html`.

### Inspector / DevTools

- [x] Probe the remote inspector (`ulStartRemoteInspectorServer`).
- **Ruled out for now:** the remote server is **not available in the Free edition**
  (verified at runtime: it returns false). The **local** inspector does exist
  (`ulViewCreateLocalInspectorView`), but it requires replicating the
  `ULPanelDesc`/`ULLayoutSize` structs in V, docking a second panel and copying
  `inspector/` into `assets/inspector/` — out of proportion compared to the bridge.
  `--devtools` enables developer mode and probes the remote inspector, reporting
  the result.

### JS ↔ V bridge

- [x] V → JS: `ulViewEvaluateScript` (`engine.eval_js()`).
- [x] JS → V, **native** (`ULJSAPI`): `ulCreateJSAPI("vshell")` +
      `ulJSAPIBindFunction(api, "post", …)` + `ulViewAttachJSAPI(...)`. The page sees
      a **frozen** `window.vshell` object with real native functions
      (`vshell.post(name, payloadJson)`, the `vshell.version` constant) — no polling
      and no injected shim.
- [x] Explicit origin rule: by default the API only reaches `file://` pages, so the
      `http://` workbench needs `http://127.0.0.1:<port>` in `ulViewAttachJSAPI`
      (otherwise the namespace never appears and **no error is raised at all**).
- [x] Bridge tick driven by `ulAppRunOnce()` from V (not from the engine's update
      callback, which deadlocks when evaluating JS).
- [x] `--eval '<js>'` to exercise the bridge from the CLI.
- [ ] Strong typing on the bindings (declare parameters/types and let the library
      validate instead of converting to string) and a namespace with more than one
      method (`vshell.window.*`).

---

## Phase 1b — WebKit (WinCairo) backend — *the engine we ship*

Decided after Phase 1: Ultralight is a beta **fork** with a commercial-only complete
source and no usable DevTools in the Free edition. The upstream **WinCairo** port of
WebKit gives the same JavaScriptCore family with LGPL/BSD terms and a real Web
Inspector. Background: `docs/ARCHITECTURE.md` §2 and §5.

- [x] Confirm the embedding API exists: `UIProcess/API/C/win/WKView.h`
      (`WKViewCreate(RECT, WKPageConfigurationRef, HWND)`). Verified against `main`.
- [x] `engine/webkit.v` + `engine/wk_host.h` behind the **same** `Engine` interface:
      window, `load_url`, async `eval_js`, JS↔V bridge, `show_inspector()`.
- [x] `scripts/stage_runtime.sh`: headers + MinGW import library + runtime, with a
      nine-symbol probe (`WKViewCreate`, `WKPageEvaluateJavaScriptInMainFrame`, …).
- [x] `scripts/build_vshell.sh` stages the engine on demand and checks that
      `WebKit2.dll` + `WebKitWebProcess.exe` + `WebKitNetworkProcess.exe` land in
      `bin/`.
- [x] Checks: `v -check .` passes (interface conformance included) and the C glue
      compiles (`gcc -fsyntax-only` against minimal stubs of the WebKit headers).
      ⚠️ **This turned out to prove far less than it looked.** Against the *real*
      headers three interop bugs appeared at once that stubs could not show:
      `WKGetTypeID`/`WKRelease`/`WKRetain` live in `WKType.h`, not `WKBase.h`; the
      generic getter is `WKGetTypeID(ref)` and `WKTypeGetTypeID` does not exist;
      and `WKBaseWin.h` does an unguarded `typedef int pid_t;` that collides with
      mingw-w64's `long long pid_t` (reached via libgc). Stubs authored by the same
      hand as the glue can only confirm the assumptions of that hand.
- [x] **Built the engine** (`build-webkit --release`): `WebKit2.dll` (17.9 MB),
      `WebCore.dll` (56 MB), `MiniBrowser.exe` and the three helper processes.
      They land in `WebKitBuild/Release/bin` — **not** `bin64`, which is what
      docs.webkit.org states and what `stage_runtime.sh` first assumed.
- [x] **Linked vshell against it** and got the workbench to load. The link needed
      `#flag -lWebKit2` in `engine/webkit.v`: `WK_EXPORT` expands to
      `__declspec(dllimport)`, so without it every API call fails with
      `undefined reference to __imp_WKRelease` — confusing, because `WKRelease` *is*
      present in the import library.
- [x] Retired `engine/ultralight.v` and its branch in `new_engine()`. Done as
      `ultralight.v.disabled` rather than `git rm`, matching the existing
      `system_webview.v.disabled` convention, so it stays one `mv` away.
- [x] Resize/DPI, title/URL push events, menus.
      - **Resize:** the child `WKView` HWND is moved from `WM_SIZE`, sized from
        `GetClientRect` (a minimized window reports 0×0 in `lParam`, and resizing
        the view to zero makes WebKit throw its backing store away).
      - **DPI:** the process is per-monitor-v2 aware, and `WM_DPICHANGED` applies
        Windows' suggested rect, so dragging the window to a monitor with another
        scale keeps the same visual size and re-lays the page out.
      - **Title/URL:** pushed by `WKPageSetPageStateClient`, not polled. Polling
        `WKPageCopyTitle` every 250 ms was one synchronous IPC round-trip per
        tick; a poll remains only as a fallback if the client cannot be installed.
        `url -> …` is logged on change, which is what makes a self-reloading page
        visible instead of looking like a page that never finishes.
      - **Menus:** a real Win32 menu bar built from `engine.MenuItem` (label +
        command, no callbacks). The engine handles `app.quit`, `view.reload`,
        `view.devtools` and `help.about`; everything else goes to the page as
        `window.__codebunMenu(command)` and the extension maps it to a VS Code
        command. Verified end to end by posting `WM_COMMAND` to the live window:
        `view.reload` re-fetched the workbench, and `terminal.new` reached the
        PTY (`vshell-web: terminal opened pid=…`).
        ⚠️ Win32 detail that cost a build: the bar must come from `CreateMenu()`;
        `CreatePopupMenu()` makes `SetMenu` fail with `ERROR_INVALID_PARAMETER`
        (87) and the window silently gets no menu.
- [ ] Tray icon, `vscode://` deep links and file associations (Phase 3).

**Acceptance:** ✅ met. `sh scripts/run.sh` opens the workbench in our own Win32
window with the WebKit engine, and the two probes answer on stdout:

```
vshell: eval -> Welcome - Code - OSS     # WebKit loaded the page and ran JS
vshell: eval -> vshell-bridge-wk         # the WKUserScript bridge is injected
```

---

## Phase 2 — Our own backend: web extension + Bun service (2-4 weeks)

What the web build cannot do on its own, and what `web/serve.js` does not provide
today (it only serves static files and renders the host page template):

- [x] `FileSystemProvider` for a `codebun://` scheme mapped to real paths
      (`extensions/codebun-backend/src/extension.ts`: stat/readdir/read/write/mkdir).
      `delete` is still `501` and `rename` still throws — both destructive, both gated
      on the token test that has not been written yet.
- [x] `Pseudoterminal` backed by **`bun-pty`** (`sursaone/bun-pty`) instead of
      `node-pty`. Verified on Windows/ConPTY under Bun: a spawn echoed
      `hello-from-pty` back with the real console banner and ANSI escapes, and the
      service logs `terminal opened pid=… cols x rows` / `terminal exited code=…`.
      The PTY is tunneled over a WebSocket (`/codebun/backend/terminal`), one PTY per
      socket, JSON frames both ways.
- [ ] Workspace search.
- [x] A Bun service over HTTP/WS — `web/backend.js`, mounted by `web/serve.js` on the
      same origin as the workbench, so no CORS handling. The token the shell generates
      is **not** in the URL: it is delivered out of band in the injected user script
      and re-broadcast on a same-origin `BroadcastChannel` (§3.3 of
      `docs/ARCHITECTURE.md`). The security model is written down there, including
      what the boundary is *not*.
- [x] A folder dialog, because the web build's "Open Folder" does not use the native
      one. `dialog.openFolder` over the bridge → `IFileOpenDialog` in
      `engine/wk_host.h`; `--open-folder` asks for it at startup, `--folder <path>`
      skips it. This was the **first** vshell API function, ahead of menus.
- [ ] Persist the last folder and add it back after activation, so a reload does not
      lose it. It must **not** go back into the URL: that is the reload path that
      cannot register the provider in time (`docs/ARCHITECTURE.md` §3.2).

**Acceptance:** open a folder, edit and save a file, and run a command in the
integrated terminal — from `vshell.exe`. ✅ measured in the embedded engine: the
extension activates, `GET /codebun/backend/{stat,readdir,read}` populate the explorer,
`json`/`typescript` language features start, and the terminal PTY echoes. One caveat,
and it is the workbench's, not the shell's: adding the **first** folder to an empty
window makes the workbench reload once (desktop VS Code does the same), so the window
title goes `Welcome` → `Welcome - Untitled (Workspace)` after a single reload. It does
not loop, because the second activation finds the folder already in the window.

**Deliberately out of scope:** Node-based extensions. Only web extensions can run in
this route; that is the trade-off, and Phase 2b exists because of it.

---

## Phase 2b — `vscode-reh-web` on Bun (case by case) ⚠ high risk

Only if the web-extension route proves too narrow. The deciding factor is the
**extension ecosystem**: Python, C++, ESLint and friends need an extension host that
can run Node code.

Status after the first spike (`scripts/build_reh.sh`, 2026-10-25):

- [x] Build `vscode-reh-web-<plat>-<arch>` alongside `vscode-web`:
      `bun build/next/index.ts bundle --target server-web` works unchanged, and
      `scripts/build_reh.sh` assembles the layout the server expects
      (`out/` + `node_modules/` + `extensions/`). The flat bundle on its own serves
      the host page and 404s every asset — measured.
- [x] Start the REH with **Bun** (not Node): it binds, prints
      `Web UI available at http://localhost:8137` and `Extension host agent started`,
      and serves the workbench (`workbench.js`, 37 MB, 200). Our own WebKit window
      then loads it: `document.title` → `Welcome - Code - OSS`,
      `.monaco-workbench` → 1. So the missing piece was never the engine.
- [x] Inventory the natives against **Bun's N-API**: Bun loads N-API addons
      (verified with a prebuilt `.node`), and `node-pty` 1.2.0-beta.15 is
      `node-addon-api` (N-API), so the pty host is no longer the blocker it was
      when it was NAN-based. `spdlog`, `@vscode/deviceid` and
      `@vscode/windows-registry` are N-API as well.
- [x] Fixed an upstream robustness bug found on the way: `src/vs/base/node/id.ts`
      imported `@vscode/windows-registry` **outside** its `try`, so any Windows
      build without that native killed the server with an unhandled rejection
      before it served anything. Patched in `configure_vscode_for_bun.sh`; worth
      reporting upstream.
- [x] Build the natives. `scripts/build_reh.sh --natives` drives `node-gyp` **on Bun**
      (pinned as a devDependency; npm and Node are not involved, which also matters
      because `bunx node-gyp` on Windows silently re-executes `node.exe`). It first
      stopped with node-gyp's own diagnosis — `missing any Windows SDK` plus **MSB8040**
      (the `binding.gyp` files ask for Spectre-mitigated libs) — so the missing pieces
      were VS components, not code. With the Windows SDK and the Spectre CRT libs
      installed, they build (`spdlog.node`, `windows.node`, `winregistry.node`,
      `sqlite3.node`) and **load in Bun**.
      `node-pty` is *excluded* on purpose: it ships prebuilds (N-API, so Bun-ready)
      that also carry `conpty/{conpty.dll, OpenConsole.exe}` in the layout its native
      module looks for. Building it from source shadows those prebuilds with a
      `build/Release` that has no `conpty/` folder — that was the terminal bug, not
      Bun and not a missing pty implementation.
- [x] Verify the extension host process actually spawns under Bun when a client
      connects. **It does**, once the socket survives: `[ExtensionHostConnection] New
      connection established`, `Launched Extension Host Process`, and the child (a
      `bun.exe`, since the server forks `process.execPath`) ran for the whole session
      and exited with code 0. Reaching that point needed the WS proxy described below.
- [x] Make the socket work. The REH's own server (VS Code's `ws` on `node:http`,
      running under Bun) completes the WebSocket handshake — the `101` and its
      `Sec-WebSocket-Accept` were verified byte for byte — but our WebKit never fires
      `open` and dies with `1006`. WebKit ↔ `Bun.serve` works, and Bun *as a client*
      of the REH works. So the shell now owns the origin and pipes the socket
      (`web/proxy.js`, `--proxy`). It also forwards `x-forwarded-host`, because the REH
      derives the workbench's `remoteAuthority` from it — without that header the page
      sends the client straight to the REH and the socket breaks again.
- [x] Activate a real Node extension — the point of the whole route. Two Bun gaps had
      to be closed first, and both failed silently (no error anywhere the shell could
      see), which is why this took instrumentation rather than debugging:
      - **The transport.** `child.send(msg, socket)` reaches the child as a message
        with `hasHandle: false`: Bun carries fork IPC messages and drops the socket
        handle. The extension host waited for its socket, hit the 60 s timeout and
        exited with code 0 having activated nothing. VS Code's other transport — a
        named pipe the child connects to itself — works, because Bun's `node:net`
        supports Windows named pipes; `configure_vscode_for_bun.sh` selects it under
        Bun. (Corollary for the item below: what Bun cannot listen on is a named pipe
        through `node:http`, not through `node:net`.)
      - **`require('vscode')`.** The interceptor uses `module.registerHooks` (absent in
        Bun) or a `module._load` patch (ignored by Bun), so every extension threw
        `MODULE_NOT_FOUND` at its first line. The host now writes a real `vscode`
        package into each extensions root and hands the requiring file name back via a
        global, keeping the API instance per extension.
      Measured with ESLint 3.0.34 in `.work/reh-data/extensions`: the probe logs
      `module-load` **and** `activate`, from `bun.exe`, `versions.bun = 1.4.3`.
- [ ] Windows **named pipes** for `node:http`: the agent host gives up after five
      restarts with `ENOENT: no such file or directory, listen '\\.\pipe\vscode-ipc-…'`.
      Narrower than it first looked — `net.createServer().listen('\\\\.\\pipe\\x')`
      works in Bun, so this is specifically the HTTP server's pipe listener, and it is
      what keeps the Copilot agent host out of this build.
- [x] Terminal through the REH (`ptyHost` child under Bun + `node-pty`). It works, and
      the last blocker was not Bun at all: `node-pty` ships Microsoft's ConPTY
      (`conpty.dll` + `OpenConsole.exe`) under `third_party/`, but the native module
      looks for it next to itself in `build/Release/conpty/`, and a from-source
      `node-gyp rebuild` does not copy it there. VS Code's default is to *use* that
      DLL (`terminal.integrated.experimental.windowsUseConptyDll`), so every spawn
      died with `Cannot find conpty.dll at …` — visible only in the terminal UI, which
      is why the pty host looked healthy: it starts, then the spawn fails.
      The fix is to *not build node-pty*: its prebuilds already contain `conpty/`, so
      the build script leaves it alone (`install_conpty_dlls` stays as a guard for
      anyone who builds it anyway). Measured afterwards, with nothing compiled for
      node-pty: the pty host (a `bun.exe`) has `OpenConsole.exe` + `powershell.exe`
      children, so the terminal is a real ConPTY shell running off Bun.
- [ ] Build `@vscode/sqlite3` as well: the agent host logs
      `Cannot find module '../build/Release/vscode-sqlite3.node'` and falls back.
- [ ] Judge case by case whether it stays on Bun. **Plan B is an embedded Node
      server, and activating it breaks "everything on Bun" — decide that
      explicitly, never by drift.**

**Acceptance:** ✅ met on Windows. A real third-party extension (ESLint 3.0.34) loads
and activates inside the remote extension host running on Bun, and the workbench
terminal spawns a real ConPTY shell (`OpenConsole.exe` + `powershell.exe`) under a
pty host that is itself `bun.exe`.

---

## Phase 2c — Performance (measured, not guessed)

The first honest numbers, and what fixed them:

| | before | after | why |
|---|---|---|---|
| bundle shipped to the client | 38 MB unminified | 19 MB | `bun build/next/index.ts bundle` is `--minify`-optional and we were not passing it |
| workbench ready | 19-32 s of CPU before the page could even open its socket | 3.3-5 s | the WebKit web process was parsing twice the code |
| boot RAM (web process) | ~700 MB | ~400-480 MB | same |
| idle wakeups | 125/s (8 ms tick forever) | ~5/s, adaptive | the message loop now waits 200 ms unless the shell has queued work (page not ready, evals pending, title-poll fallback); input arrives as a message, so responsiveness is unaffected |
| orphaned processes | 4 proxies + 4 file watchers ≈ 340 MB after a dozen runs | 0 | a **job object** with `KILL_ON_JOB_CLOSE`: one assignment on the child covers the whole tree, and it is what `--run` relies on to own an upstream |

Measured idle, workbench mounted, no folder open: shell 0.3 %, web 1.9 %, GPU 0.8 %,
network 0.6 %.

**Open, and the honest state of it:** with a folder open the idle cost jumps — 10-160 %
of a core depending on the run, spread across a single hot thread of the web process
(54 %, `Wait` state, i.e. a loop of short waits), the network process and the UI
process. It is not a HTTP loop (0 requests in 10 s), not a WebSocket flood (fewer than
200 messages), not CSS animation (`document.getAnimations()` empty), not `rAF` (2
frames in 3.3 s) and not visibility (identical when minimised). `WEBKIT_DISABLE_
COMPOSITING_MODE=1` happened to measure 10x lower once, which has not reproduced.
Next step is a native profile (WPA/xperf) of that thread; guessing further without one
is how the last few hours went.

---

## Phase 3 — Shell (what the web build does NOT give you) (4-8 weeks)

- [ ] Single instance.
- [ ] Native menus + tray.
- [ ] `vscode://` deep links and file associations.
- [ ] Secure credential store (DPAPI on Windows).
- [ ] Native notifications.
- [ ] Auto-update (signing + delta).
- [ ] JS ↔ V bridge (minimal subset; the native API already exists in Phase 1).

**Acceptance:** reasonable parity with VSCodium in OS integration.

---

## Phase 4 — "Electron-like" surface (optional, high risk)

- [ ] Shim for `process.versions.electron` / `require('electron')` **only if** some
      consumer demands it. Document the limits; do not chase full compatibility.

---

## Phase 5 — Packaging and CI (continuous)

- [ ] Bundle: `vshell.exe` + `bun.exe` + the web build (which carries the `codebun`
      backend extension) + assets. `vscode-reh-web` joins the bundle **only** if
      Phase 2b ends up being adopted.
- [ ] Installers (MSI), signing, notarization.
- [ ] Windows CI (GitHub Actions), reusing ideas from `codebun/.github`.

---

## Risks (ordered by impact)

| # | Risk | Mitigation |
|---|---|---|
| 1 | WinCairo is built with MSVC/clang-cl while we link with mingw-w64 gcc | Both target UCRT; the C API is `extern "C"` with undecorated names, and the import library is generated from the DLL. `stage_runtime.sh` probes the symbols before anything else. |
| 2 | The engine is not an SDK: building WebKit takes hours and ~60 GB | Documented build path; `build_vshell.sh` stages automatically afterwards. Prebuilt artefacts for CI come in Phase 5. |
| 3 | A missing WebKit2 helper DLL or `*Process.exe` gives a **blank page** and no error | `build_vshell.sh` checks the three required files in `bin/` and warns loudly. |
| 4 | `eval_js` is asynchronous and re-entrant if called from a WebKit callback | Pump from `pump()`, never from a callback; 3 s timeout. |
| 5 | Natives incompatible with Bun | `node-pty` is replaced by `bun-pty`; the rest is judged case by case. Plan B (embedded Node) **breaks "everything on Bun"**, so it is a deliberate decision, not a silent fallback |
| 6 | Maintaining the C binding in V | Keep the binding isolated in `engine/` |
