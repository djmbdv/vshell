#!/usr/bin/env bash
# Build-if-needed, then run the shell.
#
#   sh scripts/run.sh [--rebuild] [vshell args...]
#
# Anything that is not --rebuild is forwarded to vshell.exe. With no arguments it
# supplies the defaults that make a bare `web/public` tree viewable:
#   --engine webkit --port 8123 --serve web/public
#
# Must run from the project root (it cd's there itself): main.v resolves
# web/serve.js relative to the working directory when it is there.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"

# --- bun on PATH -------------------------------------------------------------
# The shell spawns `bun run web/serve.js` as its child, so bun must be findable.
# The Windows installer drops it in %USERPROFILE%\.bun\bin, which a fresh login
# shell does not always pick up.
for candidate in "${BUN_BIN_DIR:-}" "${HOME:-}/.bun/bin" "/c/Users/${USER:-}/.bun/bin" "/c/Users/Lenovo/.bun/bin"; do
	case "${candidate}" in
		"" | "/.bun/bin" | "/c/Users//.bun/bin") continue ;;
	esac
	if [ -x "${candidate}/bun" ] || [ -x "${candidate}/bun.exe" ]; then
		PATH="${candidate}:${PATH}"
		export PATH
		break
	fi
done
if ! command -v bun >/dev/null 2>&1; then
	echo "ERROR: 'bun' not found in PATH (tried BUN_BIN_DIR, \$HOME/.bun/bin)." >&2
	exit 1
fi

# --- the shell binary --------------------------------------------------------
rebuild=0
args=()
for a in "$@"; do
	case "$a" in
		--rebuild) rebuild=1 ;;
		--) ;;
		*) args+=("$a") ;;
	esac
done

if [ "$rebuild" = "1" ] || [ ! -x "bin/vshell.exe" ]; then
	echo "==> building bin/vshell.exe"
	sh scripts/build_vshell.sh
fi

# --- run ---------------------------------------------------------------------
# The shell is generic: it serves a directory and opens a window on it. With no
# arguments, serve the tree next to this repo's web/ (an embedder normally passes
# its own --serve, --proxy, --inject, --script, --menu and --backend instead).
# `--open-folder` is the shell's native dialog; it only records a folder in the
# payload, so a bare page simply ignores it.
if [ "${#args[@]}" -eq 0 ]; then
	if [ -d "web/public" ]; then
		args=(--engine webkit --port 8123 --serve web/public)
	else
		args=(--engine webkit --port 8123 --eval 'document.title')
	fi
fi

echo "==> vshell ${args[*]}"
exec ./bin/vshell.exe "${args[@]}"
