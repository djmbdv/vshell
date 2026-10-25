#!/usr/bin/env bash
# Builds the REH (remote extension host) and assembles a runnable layout.
#
#   sh scripts/build_reh.sh [--run]
#
# Then attach the shell to it with:
#   bin/vshell.exe --engine webkit --url http://127.0.0.1:8137/
#
# Why this is separate from build_web.sh: the two are different targets of the
# same pipeline. `web` produces the workbench alone (no server, no Node half);
# `server-web` produces server-main.js + the workbench + the extension host, which
# is what a remote workspace is.
#
# Why an assembly step: the bundle task emits a FLAT tree (server-main.js, vs/,
# media/ at the top of out-vscode-reh-web), while the server resolves resources
# relative to `<appRoot>/out/`. Copied as-is, the host page loads and every asset
# 404s — that is measured, not guessed.
#
# The REH also expects node_modules/ (natives) and extensions/ next to
# package.json. Those are junctions to the checkout rather than copies: they are
# large, and this layout is a build artifact under .work/.
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
HERE="$(pwd)"

# Bun is the ONLY JavaScript interpreter in this project, including at build time.
# These two lines are what enforces it: nothing below can reach a system Node even if
# one is installed, and the `node` that third-party binding.gyp files call is the Bun
# shim in scripts/tools (Bun implements -p/-e, which is all gyp wants).
PATH="${HERE}/scripts/tools:${HERE}/node_modules/.bin:${PATH}"
export PATH
if [ "${VSHELL_ALLOW_NODE:-0}" != "1" ]; then
	export PATH="$(printf '%s' "${PATH}" | tr ':' '\n' | grep -vi 'nodejs' | paste -sd ':' -)"
fi

VS="${HERE}/.work/vscode"
REH="${HERE}/.work/reh"
DATA="${HERE}/.work/reh-data"

if [ ! -d "${VS}/src" ]; then
	echo "ERROR: ${VS} is missing. Run scripts/build_web.sh once first." >&2
	exit 1
fi

# Native addons the REH loads at runtime. They are N-API (node-addon-api), so the
# ABI is stable and Bun can load them — that was verified with a prebuilt `.node`
# before this list existed, and again when the terminal turned out to need exactly
# that. `node-pty` is deliberately NOT here: it ships prebuilds/win32-x64 with
# conpty.node, conpty_console_list.node and, crucially, conpty/{conpty.dll,
# OpenConsole.exe} — the layout its native module looks for. A from-source build
# shadows those prebuilds with a build/Release that has no conpty/ folder, which is
# what made every terminal die with "Cannot find conpty.dll" (see
# install_conpty_dlls). Measured under Bun with only the prebuilds present: both
# useConptyDll true and false spawn and echo. spdlog/deviceid/windows-registry/
# sqlite3 have no prebuilds, so those four still need the VS toolchain.
NATIVES="@vscode/spdlog @vscode/deviceid @vscode/windows-registry @vscode/sqlite3"

# node-gyp runs under BUN, not Node and not npm: `bun node_modules/node-gyp/bin/
# node-gyp.js` reports `using node@26.x` (Bun emulates process.versions) and does
# the whole configure step. Pinned in the repo's package.json so the version is
# reproducible instead of whatever npm happens to bundle.
build_natives() {
	NODE_GYP="${HERE}/node_modules/node-gyp/bin/node-gyp.js"
	if [ ! -f "${NODE_GYP}" ]; then
		echo "ERROR: node-gyp is not installed. Run: bun install" >&2
		return 1
	fi
	for pkg in ${NATIVES}; do
		dir="${VS}/node_modules/${pkg}"
		if [ ! -d "${dir}" ]; then
			echo "  skip ${pkg} (not installed in the checkout)"
			continue
		fi
		if ls "${dir}/build/Release/"*.node >/dev/null 2>&1; then
			echo "  ok   ${pkg} (already built)"
			continue
		fi
		echo "==> building ${pkg}"
		(
			cd "${dir}"
			bun "${NODE_GYP}" rebuild
		) || echo "  !! ${pkg} failed — see the VS components named in the error" >&2
	done
}

# Only relevant if node-pty is ever built from source: its native module resolves
# `<its own dir>/conpty/conpty.dll`, and `node-gyp rebuild` does not copy Microsoft's
# ConPTY redistribution there (npm's install script does). VS Code's default is to use
# that DLL, so a from-source build spawns nothing and says so only in the terminal UI.
# The prebuilds already contain the folder, so with the default setup this is a no-op.
install_conpty_dlls() {
	np="${VS}/node_modules/node-pty"
	[ -d "${np}/build/Release" ] || return 0
	[ -d "${np}/third_party/conpty" ] || return 0
	src="$(ls -d "${np}"/third_party/conpty/*/win10-x64 2>/dev/null | sort | tail -1)"
	[ -n "${src}" ] || return 0
	mkdir -p "${np}/build/Release/conpty"
	for f in conpty.dll OpenConsole.exe; do
		if [ -f "${src}/${f}" ] && [ ! -f "${np}/build/Release/conpty/${f}" ]; then
			cp "${src}/${f}" "${np}/build/Release/conpty/${f}"
			echo "  conpty: ${f} -> node-pty/build/Release/conpty (from-source build)"
		fi
	done
}

if [ "${1:-}" = "--natives" ]; then
	build_natives
	install_conpty_dlls
	exit $?
fi

echo "==> bundling server-web (this reuses the checkout, ~1-2 min)"
install_conpty_dlls
(
	cd "${VS}"
	bun build/next/index.ts bundle --target server-web --out out-vscode-reh-web
)

echo "==> assembling ${REH}"
if ! rm -rf "${REH}" 2>/dev/null; then
	echo "ERROR: ${REH} is busy. Stop the running server first (it uses that dir as cwd)." >&2
	exit 1
fi
mkdir -p "${REH}/out"
cp -r "${VS}/out-vscode-reh-web/." "${REH}/out/"
cp "${VS}/package.json" "${REH}/package.json"
if [ -f "${VS}/product.json" ]; then
	cp "${VS}/product.json" "${REH}/product.json"
fi

# NLS is off in this build (see configure_vscode_for_bun.sh), but the extension host
# still looks for the messages bundle and logs an ENOENT on every launch. An empty
# table is what "no translations" means here, so the noise goes away for free.
if [ ! -f "${REH}/out/nls.messages.json" ]; then
	printf '{}\n' >"${REH}/out/nls.messages.json"
fi

# Junctions, not copies: node_modules is ~1 GB and this tree is disposable.
for link in node_modules extensions; do
	if command -v cmd >/dev/null 2>&1; then
		cmd //c mklink //J "$(cygpath -w "${REH}/${link}")" "$(cygpath -w "${VS}/${link}")" >/dev/null
	else
		ln -s "${VS}/${link}" "${REH}/${link}"
	fi
done

mkdir -p "${DATA}"
echo "    layout: ${REH}"
echo "    check : ${REH}/out/server-main.js $([ -f "${REH}/out/server-main.js" ] && echo present || echo MISSING)"

if [ "${1:-}" = "--run" ]; then
	echo "==> starting (Ctrl+C to stop)"
	exec bun "${REH}/out/server-main.js" \
		--host 127.0.0.1 --port "${VSHELL_REH_PORT:-8137}" \
		--without-connection-token --accept-server-license-terms \
		--server-data-dir "$(cygpath -w "${DATA}")"
fi

cat <<EOF

Next:
  bun ${REH}/out/server-main.js --host 127.0.0.1 --port 8137 \\
      --without-connection-token --accept-server-license-terms \\
      --server-data-dir $(cygpath -w "${DATA}")

  bin/vshell.exe --engine webkit --url http://127.0.0.1:8137/
EOF
