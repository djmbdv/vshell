#!/usr/bin/env sh
# Build vshell.exe (the V shell) and stage the Ultralight DLLs next to it.
#
#   sh scripts/build_vshell.sh [--run]
#
# Needs: v on PATH (C:\Users\Lenovo\v) and a mingw-w64 gcc
# (C:\Users\Lenovo\msys64\ucrt64\bin). Both are added below if missing.
set -eu

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"

V_HOME="${V_HOME:-/c/Users/Lenovo/v}"
MSYS="${MSYS:-/c/Users/Lenovo/msys64}"
export PATH="$V_HOME:$MSYS/ucrt64/bin:$PATH"

SDK=".work/ul-sdk"
[ -d "$SDK" ] || { echo "missing $SDK (extract ul-sdk-*.7z there)"; exit 1; }

echo "==> v     : $(command -v v || echo MISSING)"
echo "==> gcc   : $(command -v gcc || echo MISSING)"

# The #flag lines in engine/ultralight.v add the SDK dirs (via @VMODROOT); we
# also pass them absolutely here because V runs the linker from a temp dir, so a
# relative -L resolves against that temp dir and `-lAppCore` is not found.
v -cc gcc \
	-cflags "-I$HERE/$SDK/include" \
	-ldflags "-L$HERE/$SDK/lib" \
	-o vshell.exe .

# Runtime layout follows the SDK's own install convention (samples/cmake/Common.cmake):
# DLLs next to the exe, and resources/ under <exe dir>/assets/ — Ultralight loads
# `file:///resources/icudt67l.dat` relative to that asset root and fails to init
# ("Failed to load ICU data") if it is missing.
mkdir -p bin/assets/resources
cp -f "$SDK"/bin/*.dll bin/
cp -f "$SDK"/resources/* bin/assets/resources/
cp -f vshell.exe bin/vshell.exe

echo "==> built $HERE/bin/vshell.exe"
find bin -maxdepth 2 -type f | sort

if [ "${1:-}" = "--run" ]; then
	exec ./bin/vshell.exe --engine ultralight --port 8123 --web-root web/public
fi
