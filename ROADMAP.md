# Roadmap — vshell

Goal: a **desktop shell of our own, written in V**, that shows the VS Code **web**
workbench using **WebKit + JavaScriptCore** (no V8), with a **Bun** server.

Overall success criterion: open a folder, edit code with LSP, use the integrated
terminal and see the test extension — all from `vshell.exe`.

---

## Phase 0 — Risk probe (1-2 days) ⬅ *start here*

**Question to answer:** does the VS Code web workbench run correctly on Ultralight's
WebKit fork?

- [x] `scripts/lib/fetch_vscode_web.sh` produces `web/public` with `vscode-web`.
- [x] The Bun server serves the assets (`bun run web/serve.js`).
- [x] Open `http://127.0.0.1:8123/` in the SDK's Ultralight **Browser sample** (Windows).
- [x] Verify: workbench boot, Monaco, theme, keybindings, DevTools.

**Note:** Phase 0 was validated **directly on the Phase 1 binding** (`vshell.exe`
opens the Ultralight window against the Bun server), not with the Browser sample:
18 requests, 0 404s, "Code - OSS" workbench rendered.

---

## Phase 1 — Ultralight binding in V (1-2 weeks)

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

## Phase 2 — Bun server on the vscode fork (2-6 weeks) ⚠ high risk

- [ ] Build `vscode-reh-web-<plat>-<arch>` alongside `vscode-web`.
- [ ] Start the REH with **Bun** (not Node) and verify the web ↔ reh handshake.
- [ ] Inventory the natives and their Bun (N-API) compatibility:
      `node-pty`, `@vscode/ripgrep`, `spdlog`, native keytar, sqlite.
- [ ] Plan B if Bun fails: embedded Node server; Bun only for tooling.

**Acceptance:** integrated terminal, search and extension host work end-to-end.

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

- [ ] Bundle: `vshell.exe` + `bun.exe` + assets + `vscode-reh-web`.
- [ ] Installers (MSI), signing, notarization.
- [ ] Windows CI (GitHub Actions), reusing ideas from `codibun/.github`.

---

## Risks (ordered by impact)

| # | Risk | Mitigation |
|---|---|---|
| 1 | VS Code web does not work well on Ultralight's WebKit fork | Phase 0 detects it; fall back to CEF |
| 2 | Ultralight licensing (part of WebCore is LGPL; full source is Enterprise) | Review price/terms **before** Phase 3 |
| 3 | Natives incompatible with Bun | Plan B with Node |
| 4 | Ultralight is *single-process*, with no multi-process sandbox | Document the security model |
| 5 | Maintaining the C binding in V | Keep the binding isolated in `engine/` |
