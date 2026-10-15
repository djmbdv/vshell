# Trimming vshell: WebKit features and the web bundle

Two independent sources of weight, measured before touching anything:

| Metric | Baseline (2026-10-15) |
| --- | --- |
| Runtime in `bin/` (63 files) | 177.9 MB |
| RAM, 4 processes | 724 MB total |
| — `WebKitWebProcess` | 507 MB |
| — `WebKitGPUProcess` | 150 MB |
| — `WebKitNetworkProcess` | 32 MB |
| — `vshell` | 35 MB |
| `document.readyState` | 263 ms |
| Workbench usable (title set) | 2709 ms |

The timing marks are permanent: `engine/webkit.v` prints both, reusing probes it
already makes (the `readyState` poll and the title poll), so measuring costs no
extra IPC.

**Read the 507 MB honestly.** That process is the JavaScript heap and DOM of the
web app, not optional WebKit features. Trimming WebKit makes the DLLs smaller and
can remove helper processes; it will not move that number. The only thing that
does is a smaller web bundle.

### Measured results

| Build | Artefact | RAM (4 processes) | web process | `readyState` | Workbench usable |
| --- | --- | --- | --- | --- | --- |
| Baseline | 265.1 MB / 2135 files | 723.8 MB | 507.0 MB | 263 ms | 2709 ms |
| mermaid excluded | 206.5 MB / 2124 files | 671.3 MB | 458.0 MB | 242 ms | 2749 ms |
| + `VSHELL_MINIFY=1` | 150.1 MB / 2124 files | 602.7 MB | 399.9 MB | 217 ms (n=4) | 2468 ms (n=4) |

Totals from baseline: **−43 % artifact size, −17 % RSS, and a slightly faster
start**. Both figures come from the same `vshell.exe`: only the served web files
changed.

> **Caveat added later, after measuring variance:** the RSS column above was
> sampled *immediately* after the workbench set its title, whereas the numbers in
> "Corrected results" below are sampled 5 s later, once it has settled. The two
> methods differ by ~80 MB, so the RSS column above is only comparable with
> itself, not with anything measured afterwards. The startup column stood up to
> re-measurement; see below.

Two measurement warnings, because both nearly produced a wrong conclusion here:

- **The first run after a build is misleadingly slow.** The minified build first
  measured 289 / 3096 ms, which looked like a regression. It was a cold file
  cache: the next four runs gave 2365–2589 ms. Use `measure-runs.sh N` and look at
  the spread, never a single reading.
- **The unminified side of the startup comparison is n=2** (single readings before
  each rebuild), so the startup delta is directional, not precise. However, both
  unminified readings (2709, 2749 ms) are slower than *every* minified run
  (2365–2589 ms), so the direction is not in doubt.

What each change actually bought:

- **mermaid removal**: artifact and RSS only. It is a lazily loaded markdown
  preview bundle, so it never affected startup — removing it just stops the
  extension host from registering it at boot.
- **minification**: all three at once. Smaller files on disk, much less source
  text retained in memory by JavaScriptCore, and less to parse at startup.
  `--mangle-privates` ran 1431 edits over 41 classes and the bundle step reported
  "Syntax check passed", so the risk that mangling breaks property access did not
  materialise.


## Part 1 — WebKit feature trims (build time)

Driven by one variable, `WK_TRIM` in `build-wincairo-console.bat`. It is used
from two places (the `full` flow and the `reconfig` flow) so they cannot drift
apart: two lists that disagree produce two different binaries, and any
performance comparison between them is meaningless.

```bat
build-wincairo-console.bat reconfig    REM re-apply WK_TRIM and build
```

`reconfig` runs `cmake <WK_TRIM> .` in the existing build directory, which reuses
the cached generator/toolchain/vcpkg configuration, and then `ninja -j %WK_JOBS%`.
Do **not** use `full` for a flag change: on Windows `build-webkit` runs
`system("ninja")` with no `-j`, i.e. cores+2 jobs. On a 12 core / 15.5 GB machine
that is 14 `clang-cl` processes and ~21 GB of peak RSS: the system pages and the
desktop freezes. `WK_JOBS=4` keeps the peak near 6 GB.

What the trim turns off, and why each is safe for a desktop shell wrapping a code
editor:

| Flag | Why it is off |
| --- | --- |
| `ENABLE_VIDEO` | Removes the whole media stack (also disables `ENABLE_VIDEO_USES_ELEMENT_FULLSCREEN`). No video playback. |
| `ENABLE_GEOLOCATION` | Not a map application. |
| `ENABLE_MATHML` | Not a scientific document viewer. |
| `ENABLE_NOTIFICATIONS` | No OS notification integration. |
| `ENABLE_XSLT` | No XSLT processing. |
| `ENABLE_WEBDRIVER` | Drops `WebDriver.exe`; nothing drives the shell over WebDriver. |
| `ENABLE_RESOURCE_USAGE` | Debug/inspection feature. |
| `ENABLE_REMOTE_INSPECTOR` | `vshell`'s `start_remote_inspector()` already returns false on this port; the local inspector (`--devtools`) is unaffected. |
| `ENABLE_MEDIA_STATISTICS` | Media telemetry. |
| `ENABLE_APPLICATION_MANIFEST` | No PWA install support. |
| `ENABLE_JAVASCRIPT_SHELL` | Drops `jsc.exe`, a test tool. |
| `USE_JPEGXL` | Drops `jxl.dll` (3 MB); JPEG XL has no browser support anyway. |

Deliberately **kept**:

- `USE_WOFF2` and `USE_HARFBUZZ` — the workbench's fonts are woff2 and need shaping.
- `ENABLE_MINIBROWSER` — this is the control experiment. When something renders
  wrong, `MiniBrowser.exe` is what distinguishes "WebKit bug" from "bug in our
  glue". It costs build time, not runtime.
- `ENABLE_WEBGL`, `ENABLE_GPU_PROCESS` — untouched. They change the compositing
  path, and this round was scoped to features the shell provably does not use.

Confirmed from CMake's own summary after configuring:

```
ENABLE_VIDEO .......... OFF     ENABLE_GEOLOCATION ..... OFF
ENABLE_MATHML ......... OFF     ENABLE_MEDIA_STATISTICS  OFF
ENABLE_XSLT ........... OFF     ENABLE_MINIBROWSER ..... ON   (control)
ENABLE_WEBGL .......... ON      (unchanged on purpose)
```

### `ENABLE_VIDEO=OFF` does not compile upstream

This is a genuine bug in WebKit, not something this project introduced.
`Source/WebCore/page/text-extraction/TextExtraction.cpp` does:

```cpp
if (RefPtr media = dynamicDowncast<HTMLMediaElement>(element)) {
    .type = is<HTMLVideoElement>(*media) ? MediaType::Video : MediaType::Audio,
```

with no `#if ENABLE(VIDEO)` guard. With video off, `HTMLVideoElement.h` takes its
`#else` branch: it does not include `HTMLMediaElement.h` at all, and defines
`HTMLVideoElement` as a stub that does **not** derive from `HTMLMediaElement`. The
check therefore cannot compile.

Because it fails inside a WTF type trait, every diagnostic points somewhere other
than the cause — the file and line that matter are only the last `note:`:

```
TypeCasts.h(62):    static assertion failed: "Unnecessary type check"
TypeCasts.h(46):    static assertion failed: "Missing TypeCastTraits specialization"
type_traits(1387):  incomplete type 'const WebCore::HTMLMediaElement' used in type trait expression
TextExtraction.cpp(966): note: in instantiation of ... 'WTF::is<WebCore::HTMLVideoElement, WebCore::HTMLMediaElement>'
```

The fix is a one-line guard around the block. It is a correct fix rather than a
cosmetic one: with video disabled there is no video media element to report.

That was not the only one. `ENABLE_VIDEO=OFF` surfaced three separate defects,
each in a different layer, none of them this project's fault:

| # | Where | Symptom | Cause |
| --- | --- | --- | --- |
| 1 | `WebCore/page/text-extraction/TextExtraction.cpp` | compile error buried in WTF type-trait diagnostics | `is<HTMLVideoElement>()` unguarded; with video off `HTMLVideoElement` is a stub that does not derive from `HTMLMediaElement` |
| 2 | `WebCore/PlatformWin.cmake` | **link** error after WebCore compiled cleanly: `undefined symbol: DWriteCreateFactory` | `dwrite` is only linked inside the `ENABLE_VIDEO` block, but the Skia font backend calls `DWriteCreateFactory()` unconditionally |
| 3 | `WebKit/GPUProcess/GPUProcess.cpp` | compile error: `no member named 'NowPlayingOwnerDidChange' in namespace 'Messages::GPUProcessProxy'` | the IPC message is declared under `#if ENABLE(VIDEO) \|\| ENABLE(WEB_AUDIO)` in `GPUProcessProxy.messages.in`; the send site has no guard. WinCairo already ships `ENABLE_WEB_AUDIO=OFF`, so turning video off is enough |

Keep this in mind when adding more trims: a configuration upstream never builds
is not maintained, so a flag like this can surface unguarded code anywhere. Each
occurrence is a small guard, but the cost per iteration is high in two ways — the
error location is buried (defect 1's real line is the *last* `note:`), and the
failure can appear at the *link* stage (defect 2) where it looks unrelated to the
feature that was disabled.

**Decision rule:** if a fourth defect appears, drop `ENABLE_VIDEO` from `WK_TRIM`
and keep the other eleven flags. The media stack's contribution to size and
startup is modest, and past three unmaintained-config bugs the tree starts to
diverge from upstream for less benefit than the churn costs. The three guards are
correct and harmless with video **on**, so they can stay either way.

### The build must run with the symlink privilege

WebKit creates ~4794 **real symlinks**. Without the privilege ninja stops at
roughly 191/1459 with:

```
CMake Error: failed to create symbolic link ...: A required privilege is not held by the client.
```

Copies and hard links do **not** work: `#pragma once` deduplicates by *canonical
path*, not by file identity (measured with `fsutil hardlink list` and a minimal
reproduction). Either enable Developer Mode
(`HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock` →
`AllowDevelopmentWithoutDevLicense=1`) or run the build from an elevated shell.

The configure step itself needs no privilege, so it succeeds first and the failure
arrives later, looking like a code error. It is not.

## Part 2 — the web bundle (`web/public`)

`vshell/web/public` was 265 MB across 2135 files: `out/` 127 MB,
`extensions/` 103 MB, `node_modules/` 35 MB.

### It ships unminified by default

`scripts/lib/fetch_vscode_web.sh` documents it: the default gulp task
(`vscode-web-ci`) skips `--minify` because that step is most of the bundler's
cost, and the default is tuned for iterating on the shell. Set
`VSHELL_MINIFY=1` to switch to `vscode-web-min-ci` (`--minify` +
`--mangle-privates`).

How to tell, without reading the build: a minified file has few lines and
thousands of characters per line.

| File | Lines | Avg chars/line | Verdict |
| --- | --- | --- | --- |
| `out/vs/code/browser/workbench/workbench.js` | 917,399 | 41 | unminified |
| `out/vs/workbench/workbench.web.main.internal.js` | 916,993 | 41 | unminified |
| `extensions/mermaid-markdown-features/markdown-preview-out/index.js` | 382,955 | 67 | unminified |
| `extensions/typescript-language-features/.../extension.js` | 67 | 43,140 | minified |

This matters for more than disk: in JavaScriptCore the 36 MB source has to be
parsed, and its text occupies memory. Minifying improves size, startup and RSS
together.

### mermaid: 22 % of the whole payload

`extensions/mermaid-markdown-features` was ~58 MB of the 265 MB (four bundles:
`notebook-out`, `markdown-preview-out`, `chat-webview-out`). Excluded here, in two
places, because one is not enough:

1. `excludedExtensions` in `build/lib/extensions.ts` (VS Code's own mechanism,
   already used upstream to skip `copilot`).
2. The **static** `esbuildMediaScripts` list in the same file — it is not covered
   by `excludedExtensions`, and leaving the entry means esbuild still tries to
   build it and needs its dependencies back.

`scripts/lib/configure_vscode_for_bun.sh` applies both, plus dropping the folder
from `VSCODE_INSTALL_DIRS`. The patches live there, not in the checkout, because
the build does a `git reset --hard` before configuring.

### Extension gallery: Open VSX, not the Microsoft marketplace

Without an `extensionsGallery` in `product.json`, `build/lib/builtInExtensions.ts`
falls back to downloading built-in extensions from **GitHub releases**, and the
workbench has no marketplace at all — nothing can be installed from the UI.

`configure_vscode_for_bun.sh` now writes the Open VSX block (values taken from
VSCodium's `prepare_vscode.sh`, not invented) plus the matching
`linkProtectionTrustedDomains` entry.

#### Why not the Microsoft marketplace, and why that rules out GitHub Copilot

This was investigated thoroughly and is a licensing limit, not a technical one:

- **`extensions/copilot` cannot be bundled into the web build.** For web, the
  build requires `esbuild.browser.mts` (the fallback to `.esbuild.mts` is
  disabled by `if (!hasEsbuild && !forWeb)`), a `browser` field and
  `tsconfig.browser.json`. None exists. Its manifest declares
  `main: ./dist/extension` with no `browser` entry, and it depends on
  `@github/copilot` (a native CLI), `express`, `undici`, `xterm-headless`.
  Its only `platform: 'browser'` entry builds `vscode-worker/extension.ts`, a
  partial worker variant, not a complete Copilot Chat for the browser.
- **VS Code excludes `copilot` upstream**, not this project: it is the first
  entry in `excludedExtensions`.
- **Open VSX does not host it.** `https://open-vsx.org/api/GitHub/copilot-chat`
  returns HTTP 404, and a search for "copilot" (836 results) only returns
  third-party extensions that *use* Copilot.
- **The Microsoft marketplace is its only source**, and its terms restrict
  distribution to Visual Studio products, which a fork is not. This is exactly
  why VSCodium points at Open VSX.

So: Open VSX gives a working Extensions view with licence-clean extensions
(including AI assistants such as Copilot Delegate or TokenGuard Copilot), but not
GitHub Copilot Chat itself.

## Commands

```bash
# web bundle (uses Git's bash: MSYS2 bash has no git on PATH)
& 'C:\Program Files\Git\bin\bash.exe' -lc 'cd /c/Users/Lenovo/codebun/vshell && VSHELL_FAST=1 bash scripts/build_web.sh'
# add VSHELL_MINIFY=1 for the minified bundle

# WebKit, from an ELEVATED shell
cd C:\Users\Lenovo\projects\WebKit
cmd /c build-wincairo-console.bat reconfig    # after changing WK_TRIM
cmd /c build-wincairo-console.bat             # plain ninja -j WK_JOBS

# re-stage the runtime and relink vshell after a WebKit build
bash /c/Users/Lenovo/projects/wk-tools/archive-and-build.sh
```

Measure with `measure-startup.ps1` (launch → workbench mounted, plus RSS), or
just read the two timing lines the engine prints on every start.
`measure-all.sh N` adds RSS sampling and prints mean/min/max, which is the only
way to tell a real difference from noise.

## Corrected results: the WebKit side, and what actually moved the artifact

Measured after the whole trim was working, with the artefact pipeline fixed. All
runtime figures below are n=3 with a 5 s settle before sampling.

| Metric | Value | Range |
| --- | --- | --- |
| `readyState` | 206 ms | 153 – 272 |
| Workbench usable | 2267 ms | 2168 – 2406 |
| RSS, 4 processes | 684 MB | 680 – 687 |
| RSS, web process | 481 MB | 477 – 484 |

**The WebKit feature trims themselves are worth very little.** Measured directly
on the DLLs they produce:

| File | Before | After | Δ |
| --- | --- | --- | --- |
| `WebCore.dll` | 56.1 MB | 53.67 MB | **−2.43 MB** |
| `WebKit2.dll` | 17.9 MB | 16.5 MB | **−1.4 MB** |
| `JavaScriptCore.dll` | 31.9 MB | 31.76 MB | −0.14 MB |

About 4 MB, i.e. under 5 % of WebCore, for three patched upstream bugs. The
startup figures are **inconclusive**: the trimmed build measured 2267 ms
(2168–2406) against 2468 ms (2365–2589) for the minified build on the untrimmed
engine, and those ranges overlap. Do not claim a startup win from the trim.

**Most of the artifact reduction came from not shipping things at all**, which
needs no rebuild:

| Change | Saving |
| --- | --- |
| WebKit feature trims (DLL text) | ~3.8 MB |
| Non-runtime binaries excluded at staging (`test*.exe`, `LLInt*Extractor.exe`, `jsc.exe`, `WebDriver.exe`, `jxl*.dll` — three files, not one) | ~11.6 MB |
| `bin/` wiped before copying instead of accumulating leftovers | ~7 MB (not individually attributed) |
| **Total** | **177.9 MB → 155.0 MB / 63 → 46 files (−12.9 %)** |

Worth internalising: excluding `jsc.exe`, `WebDriver.exe` and the three `jxl*.dll`
files is possible *because* the features were disabled, but it is a `cp` fix, not
a compiler fix. And the same binaries would have been removable before touching a
single WebKit flag.

## Three pipeline traps found the hard way

Each of these silently produced a wrong or stale artifact. They are the reason
the first "the trim changed nothing" measurement was wrong.

1. **`archive-and-build.sh` did not re-stage.** It only archived `ultralight.v`,
   ran `v check` and called `build_vshell.sh`, which copies whatever is already in
   `.work/wk/runtime`. So after rebuilding WebKit it kept serving the old runtime:
   `vshell/bin/WebCore.dll` was 56.14 MB and 155 minutes old while the build that
   had just finished produced 53.67 MB. The script now runs `stage_runtime.sh`
   first and **aborts** if staging fails, rather than linking against a stale
   runtime.
2. **"Stage only if missing" is the same bug in a different place.**
   `build_vshell.sh` staged only when `WebKit2.dll` was absent, so once staged it
   was never refreshed. It now re-stages when the build's `WebKit2.dll` is *newer*
   than the staged one. Comparing the same file in two places is the right
   criterion; comparing every file against `WebKit2.dll` was tried and discarded
   because it flagged `JavaScriptCore.dll`, `icudt77.dll` and `harfbuzz.dll`,
   which legitimately are not relinked.
3. **Neither `stage_runtime.sh` nor `build_vshell.sh` cleaned their destination.**
   Copying into a directory that already has files means whatever you *exclude*
   survives from the previous run: the first version of the exclusion list had no
   effect at all because `.work/wk/runtime` still held the previous `test*.exe`.
   Both now wipe before copying (`bin/` is in `.gitignore`, so this is safe).

`include/WebKit` is still copied without cleaning. It does not inflate anything,
but it does mean a header deleted upstream would linger.

## Measuring honestly

Two lessons that cost real time here:

- **When you sample matters as much as what you sample.** RSS measured right
  after the title is set differs from RSS measured five seconds later by ~80 MB,
  because the workbench keeps loading. Comparing numbers taken at different points
  is meaningless, and that is exactly how a 78 MB "regression" appeared out of a
  change that could not cause one.
- **One sample per configuration proves nothing.** Within a single configuration
  the spread is small (RSS 680–687 MB, n=3), but the first run after a build is
  reliably slower (2912 ms vs 2147–2244 ms) because the file cache is cold. Always
  use `measure-all.sh N` and quote the range.

