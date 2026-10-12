# scripts

Everything needed to build and run `vshell`. The scripts are split by role: the
root holds the **entry points** you use, while `lib/` and `setup/` hold the ones
that are called by others or that you run once.

```
scripts/
├── run.sh                    ← shortcut: builds if needed, then runs the shell
├── build_web.sh              ← builds web/public (the vscode-web artifact)
├── build_vshell.sh           ← compiles bin/vshell.exe and stages the DLLs + resources
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
sh scripts/run.sh --devtools           # developer mode + inspector probe
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
replicates the runtime layout Ultralight requires:

```
bin/
├── vshell.exe
├── AppCore.dll  Ultralight.dll  UltralightCore.dll  WebCore.dll
└── assets/resources/{icudt67l.dat,cacert.pem}
```

> Order matters: without `bin/assets/resources/` the engine aborts with
> *"Failed to load ICU data (icudt67l.dat)"*.

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
