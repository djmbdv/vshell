# Roadmap — vshell

Goal: a **desktop shell of our own, written in V**, that shows the VS Code **web**
workbench using **WebKit + JavaScriptCore** (no V8), with a **Bun** server.

Overall success criterion: open a folder, edit code with LSP, use the integrated
terminal and see the test extension — all from `vshell.exe`.

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

- [ ] Build `vscode-reh-web-<plat>-<arch>` alongside `vscode-web`.
- [ ] Start the REH with **Bun** (not Node) and verify the web ↔ reh handshake.
- [ ] Inventory the natives against **Bun's N-API**: `@vscode/ripgrep`, `spdlog`,
      keytar, sqlite. (`node-pty` is already replaced by `bun-pty` in Phase 2.)
- [ ] Judge case by case whether it stays on Bun. **Plan B is an embedded Node
      server, and activating it breaks "everything on Bun" — decide that
      explicitly, never by drift.**

**Acceptance:** Node-based extensions activate and the terminal keeps working.

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
