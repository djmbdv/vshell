#!/usr/bin/env bash
# Builds the VS Code *web* build (vscode-web) from your fork and copies it into
# vshell/web/public so the Bun server can serve it to the embedded view.
#
# This is the workhorse behind scripts/build_web.sh; you normally do not call it
# directly (that launcher puts `bun` on PATH first). If you do:
#
#   "C:\Program Files\Git\bin\bash.exe" scripts/lib/fetch_vscode_web.sh
#
# Env:
#   VSCODE_REPOSITORY  fork to clone    (default: https://github.com/djmbdv/vscode)
#   MS_COMMIT          commit to build  (default: 1.135.0 pinned in codebun)
#   WORK               build dir        (default: .work)
#   DEST               output dir       (default: web/public)
#   IGNORE_SCRIPTS     "1" (default) to skip native postinstalls (kerberos, ...)
#   VSCODE_INSTALL_DIRS  comma-separated subfolders to install; default is the
#                      trimmed, web-only set defined below
#   VSHELL_FAST        "1" = SKIP_FETCH + SKIP_INSTALL (iterate on an existing
#                      checkout; saves the fetch, the reset and every install)
#   SKIP_FETCH         "1" to reuse the checkout as-is (no git fetch/reset)
#   SKIP_INSTALL       "1" to reuse the existing node_modules
#   COMPILE_TASK       optional gulp task that builds out-build/ (EMPTY by
#                      default: the web bundle resolves its resources against
#                      src/, so compiling src — ~15 min here — is not needed).
#                      Set it to compile-build-without-mangling when you also
#                      want out-build/ (the -with-mangling variant aborts on
#                      this commit: "Protected fields have been made PUBLIC")
#   WEB_TASK           gulp task that bundles+assembles ../vscode-web
#   VSHELL_MINIFY      "1" for the minified web task (vscode-web-min-ci). The
#                      default, vscode-web-ci, skips --minify and, with it,
#                      --mangle-privates — most of the bundler's cost
#   VSHELL_NLS         "1" to keep the i18n extraction (~5 min, English text
#                      is kept literal otherwise)
set -euo pipefail

VSCODE_REPOSITORY="${VSCODE_REPOSITORY:-https://github.com/djmbdv/vscode}"
MS_COMMIT="${MS_COMMIT:-08d4889f9ec4a1685d257b9b95de036c8e1ce1e5}"
WORK="${WORK:-.work}"
DEST="${DEST:-web/public}"
# Some transitive deps (kerberos) need MSVC to build a native addon; the web
# build is pure JS, so skip them. Was previously required on the command line:
# with `set -u` an unset IGNORE_SCRIPTS aborted the script halfway through.
IGNORE_SCRIPTS="${IGNORE_SCRIPTS:-1}"
# Iterating? VSHELL_FAST=1 reuses the checkout as-is: no git fetch/reset and no
# dependency installs (~2 min saved per run). configure still re-runs, so patch
# edits are picked up.
SKIP_FETCH="${SKIP_FETCH:-0}"
SKIP_INSTALL="${SKIP_INSTALL:-0}"
if [ "${VSHELL_FAST:-0}" = "1" ]; then
  SKIP_FETCH=1
  SKIP_INSTALL=1
fi
SCRIPT_DIR="$( cd "$(dirname "${BASH_SOURCE[0]}")" && pwd )"

# Trimmed install set: only what the *web* build needs. Skips tests, remote,
# copilot, ipynb (excluded from the build outright, see
# configure_vscode_for_bun.sh), the component-explorer (rspack/vite) and the
# non-web extensions.
DEFAULT_INSTALL_DIRS='build,extensions,extensions/configuration-editing,extensions/css-language-features,extensions/css-language-features/server,extensions/emmet,extensions/extension-editing,extensions/git-base,extensions/github-authentication,extensions/html-language-features,extensions/html-language-features/server,extensions/json-language-features,extensions/json-language-features/server,extensions/markdown-language-features,extensions/markdown-math,extensions/media-preview,extensions/merge-conflict,extensions/npm,extensions/references-view,extensions/search-result,extensions/simple-browser,extensions/typescript-language-features'
VSCODE_INSTALL_DIRS="${VSCODE_INSTALL_DIRS:-${DEFAULT_INSTALL_DIRS}}"

command -v git >/dev/null || { echo "git is required" >&2; exit 1; }
# bun is the only toolchain: package manager, TypeScript checker and runner.
command -v bun >/dev/null || { echo "bun is required" >&2; exit 1; }

echo "==> repository : ${VSCODE_REPOSITORY}"
echo "==> commit     : ${MS_COMMIT}"
echo "==> work dir   : ${WORK}"

mkdir -p "${WORK}"

# Absolute on purpose: the script cd's into ${WORK}/vscode below, and from there
# the relative form ${WORK}/vscode-web resolves to ${WORK}/vscode/${WORK}/vscode-web.
# That is exactly why every earlier run "failed to find" a perfectly good
# artifact and skipped the copy to ${DEST}.
OUTPUT_DIR="$(cd "${WORK}" && pwd)/vscode-web"

# --- single-instance guard -------------------------------------------------
# Two concurrent builds write the same generated files and one of them gets a
# lock error, e.g.:
#   [codicons] Error copying codicon.ttf: EBUSY: resource busy or locked
# Refuse to run twice (the codicon.ttf "missing font" symptom was this).
LOCK="${WORK}/build.lock"
if [ -f "${LOCK}" ]; then
  old_pid="$( cat "${LOCK}" 2>/dev/null || true )"
  # NOTE: `kill -0` alone is not reliable here. The lock stores an MSYS pid
  # (the script's `$$`), which is a small namespace that the runtime reuses, so
  # a long-dead build's pid can later belong to an unrelated bash — and then
  # every new build is refused forever. Only treat the lock as live when that
  # pid really is this script.
  lock_is_live=0
  if [ -n "${old_pid}" ]; then
    if [ -r "/proc/${old_pid}/cmdline" ]; then
      if tr '\0' ' ' < "/proc/${old_pid}/cmdline" 2>/dev/null | grep -q 'fetch_vscode_web'; then
        lock_is_live=1
      fi
    elif kill -0 "${old_pid}" 2>/dev/null; then
      # No /proc (not an MSYS/Cygwin runtime): fall back to the weaker check.
      lock_is_live=1
    fi
  fi
  if [ "${lock_is_live}" = "1" ]; then
    echo "ERROR: another build is already running (pid ${old_pid}); refusing to start." >&2
    echo "       if you are sure it is dead: rm -f ${LOCK}" >&2
    exit 1
  fi
  echo "==> stale lock (pid ${old_pid:-?}), taking over"
fi
echo "$$" > "${LOCK}"
trap 'rm -f "${LOCK}"' EXIT

if [ ! -d "${WORK}/vscode/.git" ]; then
  echo "==> cloning (blobless)..."
  git clone --filter=blob:none "${VSCODE_REPOSITORY}" "${WORK}/vscode"
fi

cd "${WORK}/vscode"
echo "==> fetching ${MS_COMMIT}..."
if [ "${SKIP_FETCH}" = "1" ]; then
  echo "    SKIP_FETCH=1: reusing the checkout as-is"
else
  git fetch --depth 1 origin "${MS_COMMIT}"
  git reset -q --hard
  git checkout -q FETCH_HEAD
fi

# Always re-run: it is idempotent and picks up patch changes.
"${SCRIPT_DIR}/configure_vscode_for_bun.sh" .

# The VS Code repo pins an exact Node version; skip that check so bun can run.
export VSCODE_SKIP_NODE_VERSION_CHECK=1

if [ "${SKIP_INSTALL}" = "1" ]; then
  echo "==> SKIP_INSTALL=1: reusing existing node_modules"
else
  echo "==> installing dependencies (this is slow)..."
  echo "    package manager: bun $(bun --version)"
  if [ "${IGNORE_SCRIPTS}" = "1" ]; then
    # Some transitive deps (e.g. `kerberos`) need MSVC + Spectre-mitigated libs
    # to build a native addon. The vscode-web build is pure JS, so skip them.
    echo "    (--ignore-scripts: skipping native postinstalls)"
    bun install --ignore-scripts
  else
    bun install
  fi

  # VS Code installs the dependencies of every subfolder (build/, extensions/*,
  # remote/, test/, ...) from its own `postinstall` hook. With --ignore-scripts
  # that hook is skipped, so run it explicitly — through bun, thanks to the
  # VSCODE_PACKAGE_MANAGER override added by configure_vscode_for_bun.sh.
  if [ "${IGNORE_SCRIPTS}" = "1" ]; then
    echo "==> installing subfolder dependencies (VS Code postinstall, via bun, trimmed)..."
    echo "    dirs: $(echo "${VSCODE_INSTALL_DIRS}" | tr ',' '\n' | wc -l) folders (trimmed from the full list)"
    if ! VSCODE_PACKAGE_MANAGER=bun VSCODE_INSTALL_DIRS="${VSCODE_INSTALL_DIRS}" VSCODE_FORCE_INSTALL=1 \
         npm_command=install bun build/npm/postinstall.ts; then
      echo "!! postinstall.ts failed (continuing so the build error stays visible)" >&2
    fi
  fi
fi

# There is deliberately no npm step here. Bun used to hoist glob@11 (ESM, no
# default export) for build/, which broke `import glob from 'glob'` and made the
# gulpfile unloadable; configure_vscode_for_bun.sh now pins glob@^7.2.3 in
# build/package.json so bun hoists the CJS build that npm used to provide.

echo "==> building vscode-web..."
# The web task (`vscode-web-ci`) is self-contained: copy-codicons ->
# compile-web-extensions-build -> esbuild bundle -> assemble ../vscode-web.
#
# The compile step (`compile-build-without-mangling` -> out-build/, ~15 min
# here) is NOT required for it. Checked in build/next/index.ts: the bundler's
# `copyResources()` resolves the curated resource patterns with
# `cwd: path.join(REPO_ROOT, SRC_DIR)` and copies every match from `src/`
# straight into the output, so this target reads nothing from out-build.
# (`vscodeWebResourceIncludes`, the list of out-build paths, is consumed by the
# desktop packagers and gulpfile.reh.ts.) Leave COMPILE_TASK empty for the fast
# path; set it when you also need out-build/.
COMPILE_TASK="${COMPILE_TASK:-}"
if [ "${VSHELL_MINIFY:-0}" = "1" ]; then
  WEB_TASK_DEFAULT="vscode-web-min-ci" # --minify (+ --mangle-privates)
else
  WEB_TASK_DEFAULT="vscode-web-ci"     # faster: no minification step
fi
WEB_TASK="${WEB_TASK:-${WEB_TASK_DEFAULT}}"

# Freshness marker: the assemble step rimrafs this itself, but removing it up
# front lets us tell "this run produced it" from "an older run did".
rm -rf "${OUTPUT_DIR}"

# Run gulp DIRECTLY with bun. The `gulp` npm script hardcodes `node`
# ("node --experimental-strip-types ... gulp.js"), which we deliberately avoid.
# Bun executes TypeScript natively, so no strip-types flag is needed.
GULP_JS="node_modules/gulp/bin/gulp.js"
LOG="../build.log"
echo "    runner: bun $(bun --version) ${GULP_JS} ${COMPILE_TASK} ${WEB_TASK}"
echo "    log:    .work/build.log"

: > "${LOG}"

# NOTE: gulp's exit code is unusable for this chain — it reports "The following
# tasks did not complete / Did you forget to signal async completion?" and exits
# 1 even when every task finished (it does that for compile-build-without-mangling
# alone, for vscode-web-min-ci alone, and for both together). So: stop `set -e`
# from killing the script at the pipeline (with `pipefail` it did exactly that,
# before the artifact checks below could run), record the status for the log,
# and gate on the artifacts instead.
#
# Both task names go into a SINGLE gulp invocation on purpose: gulp runs several
# CLI tasks in parallel, and that overlap is what keeps this at ~15 min instead
# of ~15 + the web bundle.
set +e
# shellcheck disable=SC2086
bun "${GULP_JS}" ${COMPILE_TASK} ${WEB_TASK} 2>&1 | tee -a "${LOG}"
gulp_status="${PIPESTATUS[0]}"
set -e

# A real TypeScript error is the one failure that must never slip through: our
# checker prints tsc-format diagnostics, so the log is authoritative.
if grep -q "error TS" "${LOG}"; then
  echo "ERROR: the build reported TypeScript errors:" >&2
  grep "error TS" "${LOG}" | head -10 | sed 's/^/    /' >&2
  exit 1
fi

# The assemble step writes ../vscode-web through async file streams that gulp
# does not await (the same "did not complete" quirk), so right after gulp
# returns the directory may still be missing — or only half written. Wait for it
# to appear and then for its file count to stop changing.
wait_for_output() {
  local dir="$1" prev=-1 cur=-1 stable=0 i
  for i in $(seq 1 90); do
    if [ -d "${dir}" ]; then
      cur=$(find "${dir}" -type f 2>/dev/null | wc -l)
      if [ "${cur}" = "${prev}" ] && [ "${cur}" -gt 100 ]; then
        stable=$((stable + 1))
        [ "${stable}" -ge 2 ] && return 0
      else
        stable=0
      fi
      prev="${cur}"
    fi
    sleep 2
  done
  return 1
}

# out-build/ is only checked when we actually asked for it.
if [ -n "${COMPILE_TASK}" ] && [ ! -d out-build ]; then
  echo "ERROR: ${COMPILE_TASK} produced no out-build/ (gulp exited ${gulp_status})" >&2
  exit 1
fi
if ! wait_for_output "${OUTPUT_DIR}"; then
  echo "ERROR: expected build output at ${OUTPUT_DIR} but it did not appear (gulp exited ${gulp_status})" >&2
  exit 1
fi
echo "    output: $(find "${OUTPUT_DIR}" -type f | wc -l) files, $(du -sh "${OUTPUT_DIR}" | cut -f1)"
if [ "${gulp_status}" != "0" ]; then
  echo "!! gulp exited ${gulp_status}, but the output is present —"
  echo "   continuing (known async-completion quirk of this task chain)."
fi

cd - >/dev/null

echo "==> copying to ${DEST} ..."
rm -rf "${DEST}"
mkdir -p "${DEST}"
cp -r "${OUTPUT_DIR}/." "${DEST}/"

echo "==> done. Serve it with:"
echo "    bun run web/serve.js --port 8123 --root ${DEST}"
