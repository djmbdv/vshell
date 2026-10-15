# scripts

Everything needed to build and run `vshell`. The scripts are split by role: the
root holds the **entry points** you use, while `lib/` and `setup/` hold the ones
that are called by others or that you run once.

```
scripts/
├── run.sh                    ← shortcut: builds if needed, then runs the shell
├── build_web.sh              ← builds web/public (the vscode-web artifact)
├── build_vshell.sh           ← compiles bin/vshell.exe and stages the WebKit runtime
├── stage_runtime.sh          ← normalises a WinCairo build into .work/wk/ (run on demand)
├── extract_wk_api.sh         ← prints the WebKit C API declarations this repo binds
├── lib/                      ← internals (called by build_web.sh)
│   ├── fetch_vscode_web.sh       clones the fork at a pinned SHA and runs gulp
│   └── configure_vscode_for_bun.sh  patches the checkout so the build is 100% Bun
└── setup/                    ← initial install, Windows/PowerShell only
    ├── check_env.ps1            toolchain diagnostics
    ├── install_v.ps1            installs V (vlang)
    └── install_toolchain.ps1    installs MSYS2 + mingw-w64 gcc without admin rights
```

## `run.sh`

```sh
sh scripts/run.sh                      # builds if missing, then launches the shell
sh scripts/run.sh --rebuild            # rebuilds bin/vshell.exe before launching
sh scripts/run.sh --devtools           # developer mode + open the Web Inspector
sh scripts/run.sh --eval 'document.title'
sh scripts/run.sh -- --port 9000       # anything after -- goes to vshell.exe
```

It checks that `web/public/out/vs/...` (the web artifact) exists and tells you which
command to run if it does not. `bun` is looked up in `BUN_BIN_DIR`, `$HOME/.bun/bin`
and the usual Windows locations.

## `build_web.sh`

```sh
sh scripts/build_web.sh                 # full: fetch + install + gulp (~15-40 min)
VSHELL_FAST=1 sh scripts/build_web.sh   # reuses the checkout: ~40 s
```

This is the only script that needs `bun` on PATH, and it puts it there itself. It
validates the `lib/` scripts with `bash -n` before starting, so it does not die
minutes in on a syntax error. It copies the result into `web/public/`.

Useful variables (the full list is in the header of `lib/fetch_vscode_web.sh`):

| variable | effect |
|---|---|
| `VSHELL_FAST=1` | `SKIP_FETCH` + `SKIP_INSTALL`; iterates on the existing checkout |
| `VSHELL_MINIFY=1` | minified task (`vscode-web-min-ci`); the default avoids `--minify` |
| `VSHELL_NLS=1` | keeps i18n extraction (~5 min extra) |
| `MS_COMMIT` | which commit of the fork to build |
| `DEST` | artifact destination (defaults to `web/public`) |

## `build_vshell.sh`

```sh
sh scripts/build_vshell.sh          # compiles and prepares bin/
sh scripts/build_vshell.sh --run    # also runs it
```

Adds V and MSYS2's gcc to PATH if they are missing, compiles with `v -cc gcc`, and
replicates the runtime layout WebKit2 requires:

```
bin/
├── vshell.exe
├── WebKit2.dll   (+ the WebKitRequirements DLLs: cairo, libcurl, ICU, ...)
└── WebKitWebProcess.exe   WebKitNetworkProcess.exe
```

> WebKit2 is **multi-process**: the DLLs alone are not enough. A missing helper
> executable gives a blank page with no error anywhere, so the script checks all
> three files and warns loudly.

It stages the engine itself the first time: if `.work/wk/runtime/WebKit2.dll` is
missing it runs `stage_runtime.sh`. `WK_SRC` / `WK_BUILD` point at the WebKit
checkout and its `WebKitBuild/Release`; both default to
`C:\Users\Lenovo\projects\WebKit`.

Migration state: **done**. `engine/ultralight.v` used to carry unconditional
`#flag -lAppCore …` lines, so while that file existed `.work/ul-sdk/lib` had to be
present even when running the `webkit` engine. It is now archived as
`engine/ultralight.v.disabled` (same convention as `system_webview.v.disabled`)
and nothing in the build references the Ultralight SDK any more.

## `stage_runtime.sh`

```sh
WK_SRC=/c/.../WebKit WK_BUILD=/c/.../WebKit/WebKitBuild/Release sh scripts/stage_runtime.sh
```

Normalises a WinCairo build into `.work/wk/`:

| output | what |
|---|---|
| `include/WebKit/*.h` | the public C API headers, flattened like a real install |
| `lib/libWebKit2.a` | MinGW import library, generated with `gendef` + `dlltool` from `WebKit2.dll` |
| `runtime/` | the DLLs, the two helper `*Process.exe` and the WebKitRequirements DLLs |

The import library is the whole point: WinCairo is built with MSVC/clang-cl and we
link from mingw-w64 gcc. It then probes nine symbols (`WKViewCreate`,
`WKPageEvaluateJavaScriptInMainFrame`, …) and prints `OK`/`MISSING` for each — if one
is missing, stop and read that list before blaming the V code.

## `extract_wk_api.sh`

```sh
WK_SRC=/c/.../WebKit sh scripts/extract_wk_api.sh
```

Prints the verbatim declaration of every WebKit symbol the backend binds, next to its
source file, so moving to a newer WebKit revision is a diff instead of a debugging
session. It is the counterpart of the comments in `engine/wk_host.h`.

## `lib/`

- **`fetch_vscode_web.sh`** — clones the fork at a pinned SHA into `.work/vscode`,
  applies `configure_vscode_for_bun.sh`, installs dependencies with bun and runs the
  gulp task that produces `vscode-web`. It keeps a lock in `.work/build.lock` so two
  builds cannot run at once (and detects stale locks by looking at
  `/proc/<pid>/cmdline`).
- **`configure_vscode_for_bun.sh`** — **idempotent**; it is re-run on every build
  because `git reset --hard` reverts the checkout. This is where every patch to the
  VS Code build lives (gulp→bun, `tsgo`→`bun check`, excluding `ipynb`, adding the
  shell entry point to the `web` target, bundling the shell's CSS, pinning
  `glob@^7.2.3`…). **Do not edit `.work/vscode/**` by hand**: it gets lost.

## `setup/`

These are needed once. Details in the project README.

| script | what it does |
|---|---|
| `check_env.ps1` | prints what the toolchain has and what is missing |
| `install_v.ps1` | installs V into `%USERPROFILE%\v` |
| `install_toolchain.ps1` | installs portable MSYS2 + mingw-w64 gcc (ucrt64) |
