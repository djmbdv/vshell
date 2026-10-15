#!/usr/bin/env sh
# stage_runtime.sh — prepare the WinCairo build for vshell's `webkit` engine.
#
#   WK_SRC=/c/projects/WebKit WK_BUILD=/c/projects/WebKit/WebKitBuild/Release \
#       sh scripts/stage_runtime.sh
#
# Produces (everything self-contained under .work/wk/):
#   include/WebKit/*.h   public C API headers, flattened like a real install
#   lib/libWebKit2.a     MinGW import library (gendef + dlltool)
#   runtime/             WebKit2.dll, the *Process executables, Requirements DLLs
#
# Why the import lib: WinCairo is built with MSVC/clang-cl, vshell links with
# mingw-w64 gcc (V -cc gcc). The C API is extern "C" with undecorated names on
# x64, so a MinGW import lib generated from the DLL is enough.
set -eu

WK_SRC="${WK_SRC:-}"
WK_BUILD="${WK_BUILD:-}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$HERE/.work/wk"

[ -n "$WK_SRC" ]   || { echo "set WK_SRC=<webkit checkout>" >&2; exit 1; }
[ -n "$WK_BUILD" ] || { echo "set WK_BUILD=<WebKitBuild/Release>" >&2; exit 1; }
# The output directory is not always bin64. The WinCairo build produced by
# build-wincairo-console.bat writes to bin/, so accept either instead of
# trusting docs.webkit.org (which is what made this script fail the first time).
BIN_DIR=""
for candidate in "$WK_BUILD/bin64" "$WK_BUILD/bin"; do
	if [ -d "$candidate" ]; then
		BIN_DIR="$candidate"
		break
	fi
done
[ -n "$BIN_DIR" ] || { echo "no bin64/ or bin/ under $WK_BUILD (run build-webkit first)" >&2; exit 1; }
echo "    output dir: $BIN_DIR"

echo "==> headers"
mkdir -p "$DEST/include/WebKit"
for d in \
	"$WK_SRC/Source/WebKit/Shared/API/c" \
	"$WK_SRC/Source/WebKit/UIProcess/API/C" \
	"$WK_SRC/Source/WebKit/UIProcess/API/C/win"
do
	[ -d "$d" ] || { echo "missing header dir: $d" >&2; exit 1; }
	cp -f "$d"/*.h "$DEST/include/WebKit/"
done
# The build also stages a flattened, complete copy of the public headers for
# the framework layout (151 headers, including the Win-only WKBaseWin.h). Copy
# that over the source-dir set so the staged tree matches the real install.
if [ -d "$WK_BUILD/WebKit/Headers/WebKit" ]; then
	cp -f "$WK_BUILD/WebKit/Headers/WebKit"/*.h "$DEST/include/WebKit/"
fi
ls "$DEST/include/WebKit" | wc -l | xargs echo "    headers staged:"

echo "==> runtime (DLLs + helper processes)"
# Se vacia el destino antes de copiar. Copiar sin limpiar hace que lo que se
# excluye SOBREVIVA de la pasada anterior: la primera version de la lista de
# exclusiones de abajo no tuvo efecto por esto, porque .work/wk/runtime todavia
# tenia los test*.exe del staging previo y build_vshell.sh los copiaba a bin/.
rm -rf "$DEST/runtime"
mkdir -p "$DEST/runtime"

# Excluir lo que NO es runtime.
#
# El build dir deja aqui herramientas que el shell no ejecuta nunca, y el
# `cp *.exe`/`*.dll` las arrastraba al artefacto: 11,4 MB de los 174 MB medidos.
#
#   test*.exe             herramientas de test de JavaScriptCore (~7 MB: testb3,
#                         testmasm, testair...). El glob cubre las futuras.
#   LLInt*Extractor.exe   extractores que solo existen en tiempo de compilacion
#   jsc.exe               shell de JS (ENABLE_JAVASCRIPT_SHELL=OFF)
#   WebDriver.exe         (ENABLE_WEBDRIVER=OFF)
#   jxl*.dll              copias de vcpkg del paquete libjxl, que este build ya
#                         no usa (USE_JPEGXL=OFF). Son TRES ficheros: jxl.dll,
#                         jxl_cms.dll y jxl_threads.dll. Excluir solo jxl.dll fue
#                         el primer intento y dejo los otros dos sueltos.
#                         (El glob cubre las tres.)
#   WebDriver.exe         (ENABLE_WEBDRIVER=OFF)
#
# Se conservan MiniBrowser.exe y su bundle a proposito: son el experimento de
# control que distingue un bug de WebKit de uno nuestro (docs/perf-trim.md).
#
# Antes de esto hubo un intento de detectar "obsoletos" comparando fechas con
# WebKit2.dll. Se descarto: marcaba tambien JavaScriptCore.dll, icudt77.dll y
# harfbuzz.dll (que simplemente no se reenlazan) y enterraba los 3 reales bajo
# 20 falsos positivos. Una lista explicita con su motivo es mas util que un
# criterio que hay que interpretar.
is_runtime_binary() {
	case "$(basename "$1")" in
		test*.exe | LLInt*Extractor.exe | jsc.exe | WebDriver.exe | jxl*.dll)
			return 1
			;;
	esac
	return 0
}

for f in "$BIN_DIR"/*.dll "$BIN_DIR"/*.exe; do
	[ -f "$f" ] || continue
	if is_runtime_binary "$f"; then
		cp -f "$f" "$DEST/runtime/"
	else
		echo "    excluido (no es runtime): $(basename "$f")"
	fi
done

# WebKitRequirements (cairo, icu, libcurl, ...) may live one level up or in
# WebKitLibraries/win/bin depending on how build-webkit ran.
for extra in "$WK_BUILD" "$WK_BUILD/../.." "$WK_SRC/WebKitLibraries/win/bin"; do
	[ -d "$extra" ] && cp -f "$extra"/*.dll "$DEST/runtime/" 2>/dev/null || true
done
echo "    runtime files:"
ls -1 "$DEST/runtime" | sed 's/^/      /'

[ -f "$DEST/runtime/WebKit2.dll" ] || { echo "WebKit2.dll not found: check WK_BUILD" >&2; exit 1; }

echo "==> MinGW import library"
command -v gendef  >/dev/null 2>&1 || { echo "gendef missing (pacman -S mingw-w64-x86_64-tools-git)" >&2; exit 1; }
command -v dlltool >/dev/null 2>&1 || { echo "dlltool missing (pacman -S mingw-w64-x86_64-binutils)" >&2; exit 1; }
mkdir -p "$DEST/lib"
( cd "$DEST/runtime" && gendef - WebKit2.dll > "$DEST/lib/WebKit2.def" )
dlltool -d "$DEST/lib/WebKit2.def" -D WebKit2.dll -l "$DEST/lib/libWebKit2.a"

echo "==> symbol probe (this is the make-or-break check of the migration)"
for sym in WKViewCreate WKViewSetUsesOffscreenRendering WKPageLoadURL \
           WKPageEvaluateJavaScriptInMainFrame WKUserContentControllerAddScriptMessageHandler \
           WKScriptMessageGetBody WKPageGetInspector WKInspectorShow WKPreferencesSetDeveloperExtrasEnabled
do
	if grep -q "^${sym}\$" "$DEST/lib/WebKit2.def"; then
		echo "    OK      $sym"
	else
		echo "    MISSING $sym"
	fi
done

echo
echo "staged in $DEST"
echo "next: add to scripts/build_vshell.sh"
echo "  -cflags \"-I\$HERE -I\$HERE/.work/wk/include\" -ldflags \"-L\$HERE/.work/wk/lib\""
echo "and copy \$DEST/runtime/* next to bin/vshell.exe"
