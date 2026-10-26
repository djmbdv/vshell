# scripts

Everything needed to build and run `vshell`. The root holds the **entry points**
you use, `setup/` the ones you run once.

```
scripts/
├── run.sh                 ← shortcut: builds if needed, then runs the shell
├── build_vshell.sh        ← compiles bin/vshell.exe and stages the WebKit runtime
├── stage_runtime.sh       ← normalises a WinCairo build into .work/wk/ (run on demand)
├── extract_wk_api.sh      ← prints the WebKit C API declarations this repo binds
└── setup/                 ← initial install, Windows/PowerShell only
    ├── check_env.ps1         toolchain diagnostics
    ├── install_v.ps1         installs V (vlang)
    └── install_toolchain.ps1 installs MSYS2 + mingw-w64 gcc without admin rights
```

There is no `build_web.sh` here: what to serve is the embedder's business, and the
shell only needs a directory (`--serve`) or an upstream to front (`--proxy`).

## `run.sh`

```sh
sh scripts/run.sh                          # builds if missing, then serves web/public
sh scripts/run.sh --rebuild                # rebuilds bin/vshell.exe before launching
sh scripts/run.sh --devtools               # developer mode + open the Web Inspector
sh scripts/run.sh --eval 'document.title'
sh scripts/run.sh -- --serve ../app/dist --backend ../app/server/plugin.js
```

With no arguments it serves `web/public` when that directory exists (a static tree
to look at during development) and otherwise just opens a window with an `--eval`.
An embedder passes its own `--serve`, `--proxy`, `--inject`, `--script`, `--menu`
and `--backend` instead; see the README for what each one means.

`bun` is looked up in `BUN_BIN_DIR`, `$HOME/.bun/bin` and the usual Windows
locations, because the shell starts it as the server child.

## `build_vshell.sh`

```sh
sh scripts/build_vshell.sh          # build + stage
sh scripts/build_vshell.sh --run    # build, then run against web/public
```

It compiles the V sources with `gcc` (mingw-w64, ucrt64) against the staged
WebKit import library and then assembles `bin/`: the executable plus the whole
runtime (`WebKit2.dll`, `WebKitWebProcess.exe`, `WebKitNetworkProcess.exe` and the
WebKitRequirements DLLs). A missing runtime file shows up as a **blank page with
no error anywhere**, which is the worst failure mode to debug — hence the explicit
`runtime OK/MISSING` lines at the end.

The staging is refreshed when the WebKit build is newer than what was staged, and
`WK_SRC` / `WK_BUILD` point at the checkout and its `WebKitBuild/Release`.

## `stage_runtime.sh`

```sh
WK_SRC=/c/WebKit WK_BUILD=/c/WebKit/WebKitBuild/Release sh scripts/stage_runtime.sh
```

Produces `.work/wk/{include,lib,runtime}`:

| directory | contents | why |
|---|---|---|
| `include/WebKit/*.h` | the public C API headers, flattened | `#include <WebKit/WK*.h>` resolves as it would from a real install |
| `lib/libWebKit2.a` | MinGW import library | `gendef` + `dlltool` over `WebKit2.dll`; without it the link fails with `undefined reference to __imp_WKRelease` |
| `runtime/` | the DLLs and the helper `.exe` files | WebKit2 is multi-process: the DLL alone renders nothing |

## `extract_wk_api.sh`

Prints the declarations this repo binds (function signatures, enum values) straight
from the headers, which is how `engine/webkit.v` was written without guessing at the
C API by hand.
