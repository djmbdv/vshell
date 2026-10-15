/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Codebun contributors. Licensed under the MIT License.
 *
 *  Why this file exists at all: build/lib/extensions.ts resolves an extension's
 *  build for the *web* target by looking for exactly `esbuild.browser.mts`:
 *
 *      let esbuildConfigFileName = forWeb ? 'esbuild.browser.mts' : 'esbuild.mts';
 *      // Fallback: … (used by extensions with their own build system, e.g. copilot)
 *      if (!hasEsbuild && !forWeb) { … }
 *
 *  The fallback to `.esbuild.mts` is disabled for web on purpose, so without this
 *  file the extension would fall through to `fromLocalNormal()` (vsce packaging of
 *  the raw source) and would not get a browser bundle. Upstream chose the same
 *  layout for its own web-capable extensions — see extensions/simple-browser.
 *--------------------------------------------------------------------------------------------*/

import * as path from 'node:path';
import { run } from '../esbuild-extension-common.mts';

const srcDir = path.join(import.meta.dirname, 'src');
const outDir = path.join(import.meta.dirname, 'dist', 'browser');

run({
	platform: 'browser',
	entryPoints: {
		'extension': path.join(srcDir, 'extension.ts'),
	},
	srcDir,
	outdir: outDir,
	additionalOptions: {
		tsconfig: path.join(import.meta.dirname, 'tsconfig.browser.json'),
	},
}, process.argv);
