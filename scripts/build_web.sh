#!/usr/bin/env bash
# Launcher for the vscode-web build.
#
# Why this exists: it puts `bun` on PATH (the Windows installer drops it in
# %USERPROFILE%\.bun\bin, which a login shell does not always pick up) and it
# keeps the invocation in a file, so the command never has to survive being
# quoted through PowerShell — which mangles `$(...)`, `|` and nested quotes.
#
#   scripts/build_web.sh [args passed to lib/fetch_vscode_web.sh]
#
# Override the bun location with BUN_BIN_DIR=/path/to/bun/bin.
set -euo pipefail

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

cd "$(dirname "$0")/.."

# Validate the scripts we are about to run (a module-level syntax error would
# otherwise abort the build minutes in, after the git fetch).
for s in ./scripts/lib/fetch_vscode_web.sh ./scripts/lib/configure_vscode_for_bun.sh; do
	if ! bash -n "$s"; then
		echo "ERROR: bash syntax error in $s" >&2
		exit 1
	fi
done

echo "==> toolchain"
echo "    bun  : $(command -v bun) ($(bun --version))"
echo "    npm  : $(command -v npm 2>/dev/null || echo 'MISSING (build/ normalisation will fail)')"
echo "    node : $(command -v node 2>/dev/null || echo 'MISSING (expected: the build does not use node)')"
echo

exec ./scripts/lib/fetch_vscode_web.sh "$@"
