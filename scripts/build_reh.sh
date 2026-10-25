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
VS="${HERE}/.work/vscode"
REH="${HERE}/.work/reh"
DATA="${HERE}/.work/reh-data"

if [ ! -d "${VS}/src" ]; then
	echo "ERROR: ${VS} is missing. Run scripts/build_web.sh once first." >&2
	exit 1
fi

# Native addons the REH loads at runtime. They are N-API (node-addon-api), so the
# ABI is stable and Bun can load them — that was verified with a prebuilt `.node`
# before this list existed. `node-pty` used to be the scary one and is N-API now
# (1.2.0-beta.15); spdlog is optional (its import is guarded) but its absence
# floods the log, and deviceid/windows-registry are imported by id.ts.
NATIVES="node-pty @vscode/spdlog @vscode/deviceid @vscode/windows-registry"

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

if [ "${1:-}" = "--natives" ]; then
	build_natives
	exit $?
fi

echo "==> bundling server-web (this reuses the checkout, ~1-2 min)"
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
