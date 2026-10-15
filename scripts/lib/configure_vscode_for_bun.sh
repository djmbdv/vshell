#!/usr/bin/env bash
# Configure a VS Code checkout so the whole build runs on Bun
# (no `node`, no `npm`).
#
#   sh scripts/lib/configure_vscode_for_bun.sh [path-to-vscode-checkout]
#
# It is idempotent: running it twice changes nothing, and if the changes are
# already committed in the fork (e.g. djmbdv/vscode), it simply reports
# "no change needed".
#
# What it does:
#   1. package.json
#      - "gulp"       -> "bun ./node_modules/gulp/bin/gulp.js"
#        (the original hardcodes `node --experimental-strip-types --max-old-space-size=8192`)
#      - "preinstall" / "postinstall" -> run the .ts entrypoints with bun
#      - allowScripts["kerberos@2.1.1"] = false
#        (its native build needs MSVC Spectre-mitigated libs and breaks `bun install`)
#   2. build/npm/postinstall.ts
#      - make the package manager overridable, so it can spawn `bun install`
#        in every subfolder instead of the hardcoded `npm`
#
set -euo pipefail

# The shell repo this script belongs to, resolved BEFORE the cd below so a
# relative $0 cannot be re-interpreted against the checkout. Used to stage the
# Codebun backend extension into the checkout (see the end of this file).
SHELL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"

VDIR="${1:-.work/vscode}"
cd "${VDIR}" || { echo "no vscode checkout at '${VDIR}'" >&2; exit 1; }

command -v bun >/dev/null || { echo "bun is required in PATH" >&2; exit 1; }

PATCHER="$(mktemp "${TMPDIR:-/tmp}/bun-configure.XXXXXX.cjs")"
trap 'rm -f "${PATCHER}"' EXIT

cat > "${PATCHER}" <<'BUNPATCH'
const fs = require('node:fs');

function patch(file, pairs) {
  let s = fs.readFileSync(file, 'utf8');
  let changed = 0;
  for (const [from, to] of pairs) {
    if (s.includes(to)) continue;              // already applied
    if (s.includes(from)) {
      s = s.split(from).join(to);
      changed++;
    } else {
      console.log(`  ! pattern not found in ${file}: ${from.slice(0, 60)}...`);
    }
  }
  if (changed) {
    fs.writeFileSync(file, s);
    console.log(`  patched ${file} (${changed} change${changed > 1 ? 's' : ''})`);
  } else {
    console.log(`  ok (already configured): ${file}`);
  }
}

patch('package.json', [
  ['"gulp": "node --experimental-strip-types --max-old-space-size=8192 ./node_modules/gulp/bin/gulp.js"',
   '"gulp": "bun ./node_modules/gulp/bin/gulp.js"'],
  ['"preinstall": "node build/npm/preinstall.ts"',
   '"preinstall": "bun build/npm/preinstall.ts"'],
  ['"postinstall": "node build/npm/postinstall.ts"',
   '"postinstall": "bun build/npm/postinstall.ts"'],
  ['"kerberos@2.1.1": true',
   '"kerberos@2.1.1": false'],
]);

patch('build/npm/postinstall.ts', [
  ["const npm = process.platform === 'win32' ? 'npm.cmd' : 'npm';",
   "const npm = process.env['VSCODE_PACKAGE_MANAGER'] || (process.platform === 'win32' ? 'npm.cmd' : 'npm');"],
  // Allow trimming the install set (skip tests, remote, copilot, non-web
  // extensions, the component-explorer...). Set VSCODE_INSTALL_DIRS.
  ['\tconst _state = computeState();',
   "\tconst _state = computeState();\n\n\t// vshell: optional allowlist to skip unneeded folders\n\tconst _only = (process.env['VSCODE_INSTALL_DIRS'] || '').split(',').map(s => s.trim()).filter(Boolean);\n\tconst _dirs = _only.length > 0 ? dirs.filter(d => _only.includes(d)) : dirs;\n"],
  ['\tfor (const dir of dirs) {', '\tfor (const dir of _dirs) {'],
]);

// Type checking:  3. build/lib/tsgo.ts  ->  run `bun check` instead of `tsgo`.
// Bun ships its own TypeScript checker (the TypeScript 7 native port), so the
// build needs no `tsgo` binary and no `@typescript/native` dependency, and
// `bun check` never emits — which is exactly what every caller of this module
// asks for (`noEmit: true`). `--no-pretty` makes it print tsc-format
// diagnostics (`file.ts(line,col): error TSxxxx: ...`), which is what the
// reporter in that same file already parses.
patch('build/lib/tsgo.ts', [
  [`/**
 * Absolute path to the TypeScript 7 (native) compiler entrypoint. TS7 is
 * installed under the \`@typescript/native\` alias, a package name that only
 * exists at the repository root and never collides with the \`typescript\`
 * (<= 6.x) that individual extensions install locally. Resolving it explicitly
 * and invoking it via \`node\` guarantees we always run TS7, regardless of the
 * node_modules layout of the project being compiled.
 */
const ts7TscPath = path.join(path.dirname(createRequire(import.meta.url).resolve('@typescript/native/package.json')), 'bin', 'tsc');`,
   `/**
 * vshell: type checking runs on \`bun check\`, Bun's built-in TypeScript
 * checker (a port of the TypeScript 7 native compiler). No \`tsgo\` binary and
 * no \`@typescript/native\` package are needed, and \`bun check\` never emits,
 * so it maps exactly onto the \`noEmit\` behaviour every caller asks for.
 * The \`VSCODE_BUN_BIN\` environment variable overrides the interpreter.
 */
const bunBin = process.env['VSCODE_BUN_BIN']
\t|| ('bun' in process.versions ? process.execPath : (process.platform === 'win32' ? 'bun.exe' : 'bun'));`],

  [`\tconst args = [ts7TscPath, '--project', projectPath, '--pretty', 'false', '--incremental'];
\tif (config.noEmit) {
\t\targs.push('--noEmit');
\t} else {
\t\targs.push('--sourceMap', '--inlineSources');
\t}
\tconst child = cp.spawn(process.execPath, args, {`,
   `\t// vshell: \`bun check --no-pretty\` prints tsc-format diagnostics
\t// (file.ts(line,col): error TSxxxx: ...) and checks with every CPU core.
\tconst args = ['check', '--project', projectPath, '--no-pretty'];
\tconst child = cp.spawn(bunBin, args, {`],

  [`\t\t\t\treject(new Error(\`tsgo exited with code \${code ?? 'unknown'}\`));`,
   `\t\t\t\treject(new Error(\`bun check exited with code \${code ?? 'unknown'}\`));`],

  // Shadowing: `bun check` is shorthand for "run the package.json script named
  // check" whenever one exists (verified: it echoes `$ <cmd>` and exits 0), so
  // a project with a `check` script would silently type-check nothing. Bun
  // resolves that name against the nearest package.json from the *process cwd*,
  // so run from a directory with no package.json and pass an absolute
  // --project instead.
  [`\t// vshell: \`bun check --no-pretty\` prints tsc-format diagnostics
\t// (file.ts(line,col): error TSxxxx: ...) and checks with every CPU core.
\tconst args = ['check', '--project', projectPath, '--no-pretty'];
\tconst child = cp.spawn(bunBin, args, {
\t\tcwd: root,`,
   `\t// vshell: \`bun check --no-pretty\` prints tsc-format diagnostics
\t// (file.ts(line,col): error TSxxxx: ...) and checks with every CPU core.
\t// --project is absolute and cwd is NOT the checkout root on purpose (see
\t// the shadowing note above): a "check" npm script in the project would
\t// otherwise shadow the built-in checker and exit 0 without checking.
\tconst args = ['check', '--project', path.resolve(root, projectPath), '--no-pretty'];
\tconst child = cp.spawn(bunBin, args, {
\t\tcwd: os.tmpdir(),`],

  [`import * as cp from 'child_process';
import es from 'event-stream';`,
   `import * as cp from 'child_process';
import * as os from 'os';
import es from 'event-stream';`],

  // 'close' guarantees the stdio pipes are drained; 'exit' can fire first.
  [`\treturn new Promise<void>((resolve, reject) => {
\t\tchild.on('exit', code => {`,
   `\treturn new Promise<void>((resolve, reject) => {
\t\t// vshell: wait for 'close', NOT 'exit'. 'exit' can fire before the
\t\t// stdout/stderr 'data' events are delivered: with ~20 checks running in
\t\t// parallel (the extension step) 5 of 23 measured runs had an empty
\t\t// buffer at 'exit' and the full summary only at 'close', which made the
\t\t// guard below fail on a perfectly good run.
\t\tchild.on('close', code => {`],

  // Belt and braces: refuse a "green" run that produced no checker summary.
  [`\t\t\tif (code === 0) {
\t\t\t\tPromise.resolve(onComplete?.()).then(() => resolve(), reject);`,
   `\t\t\tif (code === 0) {
\t\t\t\t// vshell guard: a shadowed run exits 0 having checked nothing. The
\t\t\t\t// checker always prints a summary; a shell script does not.
\t\t\t\tif (!allOutput.includes('No type errors')) {
\t\t\t\t\treject(new Error(\`bun check printed no summary (shadowed by a "check" script?): \${allOutput.trim().slice(0, 300)}\`));
\t\t\t\t\treturn;
\t\t\t\t}
\t\t\t\tPromise.resolve(onComplete?.()).then(() => resolve(), reject);`],
]);

// The log labels should not claim to run a binary we no longer ship.
patch('build/lib/extensions.ts', [
  ["'typechecking extension (tsgo)'", "'typechecking extension (bun check)'"],
  ["'typechecking extension media (tsgo)'", "'typechecking extension media (bun check)'"],
]);

patch('build/lib/compilation.ts', [
  ["'[tsgo] watch-client-noEmit failed'", "'[bun check] watch-client-noEmit failed'"],
]);

// Drop the ipynb extension from the web build. `excludedExtensions` is VS
// Code's own mechanism (it already excludes `copilot`) and it is applied
// *before* each extension's typecheck/bundle step, so ipynb is neither built
// nor packaged into .build/web/extensions (hence not into the final output).
patch('build/lib/extensions.ts', [
  [`const excludedExtensions = [
\t'copilot',`,
   `const excludedExtensions = [
\t'copilot',
\t'ipynb',`],

  // Its webview/notebook media bundle comes from a *static* list that
  // excludedExtensions does not cover, and that step would need ipynb's
  // dependencies back. Remove the entry as well.
  [`\t{ script: 'ipynb/esbuild.notebook.mts', tsconfig: 'ipynb/notebook-src/tsconfig.json' },
\t{ script: 'markdown-language-features/esbuild.notebook.mts', tsconfig: 'markdown-language-features/notebook/tsconfig.json' },`,
   `\t// vshell: ipynb excluded from the build (see excludedExtensions above)
\t{ script: 'markdown-language-features/esbuild.notebook.mts', tsconfig: 'markdown-language-features/notebook/tsconfig.json' },`],
]);

// Mermaid: ~58 MB of the 265 MB web output (22%) in unminified bundles, and a
// desktop shell for a code editor does not need diagram rendering inside the
// markdown preview. Same two-step treatment as ipynb, for the same reason: the
// media list below is *static* and is NOT covered by excludedExtensions, so
// removing the name alone would leave esbuild still trying to build it.
patch('build/lib/extensions.ts', [
  [`\t'copilot',
\t'ipynb',`,
   `\t'copilot',
\t'ipynb',
\t'mermaid-markdown-features',`],

  [`\t{ script: 'mermaid-markdown-features/esbuild.webview.mts', tsconfig: 'mermaid-markdown-features/preview-src/tsconfig.json' },`,
   `\t// vshell: mermaid-markdown-features excluded (see excludedExtensions above)`],
]);

// NLS (i18n) is the single most expensive step of the web bundle: it walks
// ~1.7k modules and extracts ~21k messages, single-threaded (~5 min). A local
// shell does not need translations, so it is OFF unless VSHELL_NLS=1 is set;
// the localize() calls then keep their literal (English) text.
patch('build/gulpfile.vscode.web.ts', [
  [`const esbuildBundleVSCodeWebTask = task.define('esbuild-vscode-web', () => runEsbuildBundle('out-vscode-web', false, true));
const esbuildBundleVSCodeWebMinTask = task.define('esbuild-vscode-web-min', () => runEsbuildBundle('out-vscode-web-min', true, true, \`\${sourceMappingURLBase}/core\`));`,
   `// vshell: off by default (VSHELL_NLS=1 re-enables it) — see the note in the
// patcher above. Top-level const so both tasks share it.
const VSHELL_NLS = process.env['VSHELL_NLS'] === '1';
const esbuildBundleVSCodeWebTask = task.define('esbuild-vscode-web', () => runEsbuildBundle('out-vscode-web', false, VSHELL_NLS));
const esbuildBundleVSCodeWebMinTask = task.define('esbuild-vscode-web-min', () => runEsbuildBundle('out-vscode-web-min', true, VSHELL_NLS, \`\${sourceMappingURLBase}/core\`));`],
]);

// The `web` build target deliberately leaves out the browser shell/bootstrap
// ("web workbench only (no browser shell)") because vscode.dev ships its own host
// page. We serve this repo's workbench.html template from the Bun server, so we
// do need it: without the shell nothing reads the workbench-web-configuration
// meta tag or calls create(), and the entry that template loads
// (out/vs/code/browser/workbench/workbench.js) is never emitted. Note the
// `server-web` target does include it (via ...webEntryPoints).
patch('build/next/index.ts', [
  [`\t\t\t\t'vs/workbench/workbench.web.main.internal', // web workbench only (no browser shell)
\t\t\t\t...keyboardMapEntryPoints,
\t\t\t];`,
   `\t\t\t\t'vs/workbench/workbench.web.main.internal',
\t\t\t\t// vshell: the shell that reads the workbench-web-configuration meta
\t\t\t\t// tag and calls create() — vscode.dev provides its own host page, we
\t\t\t\t// serve the repo's workbench.html template instead.
\t\t\t\t'vs/code/browser/workbench/workbench',
\t\t\t\t...keyboardMapEntryPoints,
\t\t\t];`],
]);

// The CSS that the shell imports (`import './aria.css'`, `./editor.css`, ...) is
// only bundled into a sibling workbench.css when the entry point is listed in
// getCssBundleEntryPointsForTarget; otherwise cssExternalPlugin() leaves every
// `import "./x.css"` in place and the browser requests e.g.
// /out/vs/code/browser/workbench/aria.css -> 404, workbench.js aborts before
// create(). The `web` target lists only the workbench mains (the shell is only
// in `server-web`), so we add it here to get out/vs/code/browser/workbench/
// workbench.css emitted, which is exactly what workbench.html links.
patch('build/next/index.ts', [
  [`\t\tcase 'web':
\t\t\treturn new Set([
\t\t\t\t'vs/workbench/workbench.web.main.internal',
\t\t\t\t'vs/sessions/sessions.web.main.internal',
\t\t\t]);`,
   `\t\tcase 'web':
\t\t\treturn new Set([
\t\t\t\t'vs/workbench/workbench.web.main.internal',
\t\t\t\t'vs/sessions/sessions.web.main.internal',
\t\t\t\t// vshell: our host page loads this shell, so its CSS must be bundled
\t\t\t\t// into out/vs/code/browser/workbench/workbench.css.
\t\t\t\t'vs/code/browser/workbench/workbench',
\t\t\t]);`],
]);

// Pin `glob` for build/. Bun hoists glob@11 (ESM, no default export) where npm
// hoisted glob@7.2.3 (CJS with main "glob.js"), and build/lib/extensions.ts
// does `import glob from 'glob'` — under Bun the gulpfile then cannot even be
// loaded:
//   SyntaxError: module '...glob/dist/esm/index.js' does not have an export
//   named 'default'. Did you mean 'glob'?
// Declaring the version the build works with keeps everything on bun, so the
// npm install in build/ is no longer needed.
{
  const file = 'build/package.json';
  const pkg = JSON.parse(fs.readFileSync(file, 'utf8'));
  const deps = pkg.devDependencies || (pkg.devDependencies = {});
  if (deps.glob !== '^7.2.3') {
    deps.glob = '^7.2.3';
    // keep the file's alphabetical ordering
    pkg.devDependencies = Object.fromEntries(Object.keys(deps).sort().map(k => [k, deps[k]]));
    fs.writeFileSync(file, JSON.stringify(pkg, null, 2) + '\n');
    console.log(`  patched ${file} (glob pinned so bun hoists the CJS build)`);
  } else {
    console.log(`  ok (already configured): ${file}`);
  }
}

// Extension gallery: Open VSX, not the Microsoft marketplace.
//
// Without an `extensionsGallery`, build/lib/builtInExtensions.ts falls back to
// downloading built-in extensions from GitHub releases (which is why the OSS
// product.json only lists the three js-debug ones), and the workbench has no
// marketplace at all: no extension can be installed from the UI.
//
// Open VSX is the documented, licence-clean option (it is what VSCodium ships).
// The Microsoft marketplace is deliberately NOT used: it is the only source of
// GitHub Copilot Chat, but its terms restrict distribution to Visual Studio
// products, so a fork has no right to it. See docs/perf-trim.md.
//
// The values below are taken from VSCodium's prepare_vscode.sh rather than
// invented, and `linkProtectionTrustedDomains` must include the host or the
// workbench treats gallery links as untrusted.
{
  const file = 'product.json';
  const pj = JSON.parse(fs.readFileSync(file, 'utf8'));
  const GALLERY = {
    serviceUrl: 'https://open-vsx.org/vscode/gallery',
    itemUrl: 'https://open-vsx.org/vscode/item',
    latestUrlTemplate: 'https://open-vsx.org/vscode/gallery/{publisher}/{name}/latest',
    controlUrl: 'https://raw.githubusercontent.com/EclipseFdn/publish-extensions/refs/heads/master/extension-control/extensions.json',
  };
  let changed = false;
  if (!pj.extensionsGallery) {
    pj.extensionsGallery = GALLERY;
    changed = true;
  }
  const domains = Array.isArray(pj.linkProtectionTrustedDomains) ? pj.linkProtectionTrustedDomains : [];
  if (!domains.includes('https://open-vsx.org')) {
    pj.linkProtectionTrustedDomains = [...domains, 'https://open-vsx.org'];
    changed = true;
  }
  if (changed) {
    // Tabs, like the rest of the file, so the diff stays readable.
    fs.writeFileSync(file, JSON.stringify(pj, null, '\t') + '\n');
    console.log(`  patched ${file} (open-vsx gallery)`);
  } else {
    console.log(`  ok (already configured): ${file}`);
  }
}
BUNPATCH

echo "==> configuring VS Code checkout for bun (${VDIR})"
bun "${PATCHER}"

# --- Codebun backend extension -----------------------------------------------
#
# The source lives in the shell repo, NOT in the checkout: the checkout is
# disposable (fetch_vscode_web.sh runs `git reset --hard`), so anything written
# there is lost on the next build. Copying it in on every configure is what makes
# the two survive each other — the same reason every other edit in this file is a
# patch rather than a commit.
#
# It has to land as a DIRECT child of extensions/, because its
# esbuild.browser.mts imports `../esbuild-extension-common.mts` and that path only
# resolves from that level. Background: extensions/codebun-backend/README.md.
#
# Without this the web build still succeeds — it simply has no backend, and the
# workbench cannot open a folder. That silence is why the check below is loud.
CB_SRC="${VSHELL_CODEBUN_EXT:-$SHELL_REPO/extensions/codebun-backend}"
if [ -d "$CB_SRC" ]; then
	rm -rf extensions/codebun-backend
	cp -r "$CB_SRC" extensions/codebun-backend
	echo "  staged extensions/codebun-backend (the web backend extension)"
else
	echo "  ! codebun-backend not found at $CB_SRC" >&2
	echo "    the web build will have no filesystem backend and cannot open a folder" >&2
fi
