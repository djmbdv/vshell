#!/usr/bin/env sh
# Build vshell.exe (the V shell) and stage the WebKit (WinCairo) runtime next to it.
#
#   sh scripts/build_vshell.sh [--run]
#
# Needs: v on PATH (C:\Users\Lenovo\v), a mingw-w64 gcc
# (C:\Users\Lenovo\msys64\ucrt64\bin) and a staged WinCairo build:
#
#   WK_SRC=/c/.../WebKit WK_BUILD=/c/.../WebKit/WebKitBuild/Release \
#       sh scripts/stage_runtime.sh
#
# This replaces the Ultralight staging:
#   before  .work/ul-sdk/*                 -> bin/*.dll + bin/assets/resources/icudt67l.dat
#   now     .work/wk/{include,lib,runtime} -> bin/*.dll + the WebKit2 helper processes
#
# The layout changed because WebKit2 is multi-process: next to WebKit2.dll the
# shell needs WebKitWebProcess.exe / WebKitNetworkProcess.exe and the
# WebKitRequirements DLLs. A missing one shows up as a BLANK PAGE with no error
# anywhere, which is the worst failure mode to debug — hence the check below.
set -eu

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"

V_HOME="${V_HOME:-/c/Users/Lenovo/v}"
MSYS="${MSYS:-/c/Users/Lenovo/msys64}"
export PATH="$V_HOME:$MSYS/ucrt64/bin:$PATH"

WK="${WK:-$HERE/.work/wk}"
WK_SRC="${WK_SRC:-/c/Users/Lenovo/projects/WebKit}"
WK_BUILD="${WK_BUILD:-$WK_SRC/WebKitBuild/Release}"

echo "==> v     : $(command -v v || echo MISSING)"
echo "==> gcc   : $(command -v gcc || echo MISSING)"

# --- engine: stage on demand, and RE-stage when the build is newer -----------
#
# "Only if missing" is not enough, and the failure is silent: once staged, the
# runtime is reused forever even after WebKit is rebuilt, so vshell ends up
# linked against new headers and old DLLs. That is how a 155-minute-old
# WebCore.dll got measured: vshell/bin/WebCore.dll was 56.1 MB while the build
# that had just finished produced 53.7 MB.
#
# The correct criterion compares the SAME file in both places. (Comparing each
# file against WebKit2.dll was tried in stage_runtime.sh and discarded: it also
# flagged JavaScriptCore.dll, icudt77.dll and harfbuzz.dll, which legitimately
# are not relinked.)
STAGED="$WK/runtime/WebKit2.dll"
BUILT="$WK_BUILD/bin/WebKit2.dll"
needs_stage=0
[ -f "$STAGED" ] || needs_stage=1
if [ -f "$STAGED" ] && [ -f "$BUILT" ] && [ "$BUILT" -nt "$STAGED" ]; then
	echo "==> WebKit build is newer than the staged runtime: re-staging"
	needs_stage=1
fi

if [ "$needs_stage" = "1" ]; then
	echo "==> staging the WinCairo build into $WK"
	echo "    WK_SRC=$WK_SRC"
	echo "    WK_BUILD=$WK_BUILD"
	# `|| true`: if staging fails, fall through to the guidance below instead of
	# dying inside stage_runtime.sh under `set -e`.
	WK_SRC="$WK_SRC" WK_BUILD="$WK_BUILD" sh "$HERE/scripts/stage_runtime.sh" || true
fi

if [ ! -f "$WK/runtime/WebKit2.dll" ]; then
	echo "missing $WK/runtime/WebKit2.dll" >&2
	echo "  1) build the engine: perl Tools/Scripts/build-webkit --release" >&2
	echo "  2) stage it:        WK_SRC=... WK_BUILD=... sh scripts/stage_runtime.sh" >&2
	exit 1
fi

# --- migration guards --------------------------------------------------------
# engine/ultralight.v carries unconditional `#flag -lAppCore ...` lines, so gcc
# needs .work/ul-sdk/lib to exist even when the webkit engine is the one in use.
if [ -f engine/ultralight.v ] && [ ! -d .work/ul-sdk/lib ]; then
	echo "WARNING: engine/ultralight.v is still compiled but .work/ul-sdk is gone." >&2
	echo "         Its #flag lines (-lAppCore, -lUltralight, -lWebCore) will fail the link." >&2
	echo "         Either extract the Ultralight SDK into .work/ul-sdk again, or finish" >&2
	echo "         the migration: git rm engine/ultralight.v" >&2
fi

# `--engine webkit` needs the branch in new_engine(); catch it here instead of
# failing at runtime with `unknown engine "webkit"`.
if ! grep -q "webkit" engine/engine.v 2>/dev/null; then
	echo "WARNING: engine/engine.v does not register the webkit engine yet." >&2
	echo "         add: if kind == 'webkit' { return Engine(WebKitEngine{}) }" >&2
fi

# The #flag lines in engine/webkit.v add the engine dirs via @VMODROOT; we also
# pass them absolutely here because V runs the linker from a temp dir, so a
# relative -L resolves against that temp dir and `-lWebKit2` is not found.
# -I$HERE is what makes `#include "engine/wk_host.h"` resolvable: that header and
# the C it pulls in (windows.h + <WebKit/WK*.h>) end up in V's generated C.
# V runs gcc DIRECTLY, so the MSYS path-conversion layer never sees these
# arguments. A /c/... path therefore reaches gcc verbatim, gcc reads it as
# C:\c\Users\... and reports "WebKit/WKBase.h: No such file or directory".
# cygpath -m produces the C:/... form gcc actually understands.
# Note: testing `gcc -I/c/...` by hand "succeeds" and proves nothing, because
# there MSYS converts the argument before gcc is even started.
HERE_WIN="$(cygpath -m "$HERE")"
v -cc gcc \
	-cflags "-I$HERE_WIN -I$HERE_WIN/.work/wk/include" \
	-ldflags "-L$HERE_WIN/.work/wk/lib" \
	-o vshell.exe .

# Runtime layout: WebKit2 is multi-process, so the DLL is not enough — the helper
# executables and the WebKitRequirements DLLs must sit next to vshell.exe.
# (WebKit brings its own ICU and resources: there is no assets/resources/icudt67l.dat
#  like the Ultralight SDK needed.)
# bin/ is a generated artifact directory (it is in .gitignore), so it is wiped
# before copying. Without this, anything the staging excludes (test*.exe,
# jsc.exe, WebDriver.exe, jxl.dll) survives from a previous run and the artifact
# stops reflecting what staging actually produced -- which is how 11.4 MB of
# JavaScriptCore test tools ended up in a 174 MB shell.
rm -rf bin
mkdir -p bin
cp -f vshell.exe bin/vshell.exe
cp -f "$WK"/runtime/* bin/

missing=0
for f in WebKit2.dll WebKitWebProcess.exe WebKitNetworkProcess.exe; do
	if [ -f "bin/$f" ]; then
		echo "==> runtime OK      $f"
	else
		echo "==> runtime MISSING $f    (expect a blank page, no error)" >&2
		missing=1
	fi
done
[ "$missing" = "0" ] || echo "==> runtime incomplete: check WK_BUILD=$WK_BUILD" >&2

echo "==> built $HERE/bin/vshell.exe"
ls -1 bin | sed 's/^/    /'

if [ "${1:-}" = "--run" ]; then
	exec ./bin/vshell.exe --engine webkit --port 8123 --web-root web/public
fi
