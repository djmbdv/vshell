/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Codebun contributors. Licensed under the MIT License.
 *--------------------------------------------------------------------------------------------*/

import * as vscode from 'vscode';

/*
 * Codebun backend extension.
 *
 * What it is for: the web build of the workbench has no access to the real file
 * system and no terminal. `web/serve.js` only serves static files and renders the
 * host page template, so opening a folder is impossible without a backend. This
 * extension is the workbench side of that backend; the shell runs the other side
 * as a Bun service.
 *
 * Scope (ROADMAP Phase 2): file system first, then terminal, then search. Node
 * extensions are deliberately out of scope — a web extension host can only run web
 * extensions, and that is the trade-off of this route.
 *
 * ---------------------------------------------------------------------------
 * SECURITY — read before exposing anything new here.
 *
 * The service listens on 127.0.0.1 and, right now, only checks the Origin header.
 * Any local process can forge that header, so this is NOT a boundary. A token is
 * the intended design and is not implemented yet: deliver it to the extension
 * out-of-band (the page gets it through the shell, the shell through its own
 * launch), never through a URL the page can be tricked into fetching.
 * Tracked in the ROADMAP (Phase 2); do not ship anything that assumes the
 * current check is real isolation.
 * ---------------------------------------------------------------------------
 */

/** Path of the backend, relative to the origin the workbench is served from. */
const ENDPOINT = '/codebun/backend';

/*
 * The extension host runs in a Web Worker (`WorkerGlobalScope`), NOT in the page.
 * That matters for one non-obvious reason: a relative URL has nothing to resolve
 * against inside a worker, so a plain `fetch('/codebun/backend/hello')` fails
 * outright with
 *
 *   TypeError: Failed to execute 'fetch' on 'WorkerGlobalScope':
 *              Failed to parse URL from /codebun/backend/hello
 *
 * even though the page and the service share an origin. The worker script itself
 * is loaded from the same server that hosts the backend, so its own origin is the
 * base we need. (Measured, not assumed: the relative form was tried first and the
 * "Show Backend Status" command reported exactly that TypeError.)
 */
const WORKER_ORIGIN = (globalThis as { location?: { origin?: string } }).location?.origin ?? '';

interface StatResponse {
	type: 'file' | 'directory';
	size: number;
	mtime: number;
}

interface DirEntry {
	name: string;
	type: 'file' | 'directory';
}

async function backend(path: string, init?: RequestInit): Promise<Response> {
	const response = await fetch(WORKER_ORIGIN + ENDPOINT + path, init);
	if (!response.ok) {
		throw new Error(`codebun backend: ${path} -> ${response.status} ${await response.text()}`);
	}
	return response;
}

async function backendJson<T>(path: string, init?: RequestInit): Promise<T> {
	return (await (await backend(path, init)).json()) as T;
}

const q = (uri: vscode.Uri): string => `?path=${encodeURIComponent(uri.path)}`;

class CodebunFileSystemProvider implements vscode.FileSystemProvider {

	private readonly _onDidChangeFile = new vscode.EventEmitter<vscode.FileChangeEvent[]>();
	readonly onDidChangeFile: vscode.Event<vscode.FileChangeEvent[]> = this._onDidChangeFile.event;

	watch(): vscode.Disposable {
		// The service cannot report changes yet, so there is nothing to subscribe
		// to. Returning a no-op keeps the provider valid without pretending.
		return new vscode.Disposable(() => { /* nothing to release */ });
	}

	async stat(uri: vscode.Uri): Promise<vscode.FileStat> {
		const s = await backendJson<StatResponse>(`/stat${q(uri)}`);
		return {
			type: s.type === 'directory' ? vscode.FileType.Directory : vscode.FileType.File,
			// The backend does not expose a creation time; VS Code only uses it for
			// sorting, so mtime is a truthful stand-in rather than a zero.
			ctime: s.mtime,
			mtime: s.mtime,
			size: s.size,
		};
	}

	async readDirectory(uri: vscode.Uri): Promise<[string, vscode.FileType][]> {
		const entries = await backendJson<DirEntry[]>(`/readdir${q(uri)}`);
		return entries.map(entry => [
			entry.name,
			entry.type === 'directory' ? vscode.FileType.Directory : vscode.FileType.File,
		]);
	}

	async readFile(uri: vscode.Uri): Promise<Uint8Array> {
		const response = await backend(`/read${q(uri)}`);
		return new Uint8Array(await response.arrayBuffer());
	}

	async writeFile(uri: vscode.Uri, content: Uint8Array): Promise<void> {
		await backend(`/write${q(uri)}`, { method: 'POST', body: content });
		this._onDidChangeFile.fire([{ type: vscode.FileChangeType.Changed, uri }]);
	}

	async createDirectory(uri: vscode.Uri): Promise<void> {
		await backend(`/mkdir${q(uri)}`, { method: 'POST' });
		this._onDidChangeFile.fire([{ type: vscode.FileChangeType.Created, uri }]);
	}

	async delete(uri: vscode.Uri, options: { recursive: boolean }): Promise<void> {
		await backend(`/delete${q(uri)}&recursive=${options.recursive ? '1' : '0'}`, { method: 'POST' });
		this._onDidChangeFile.fire([{ type: vscode.FileChangeType.Deleted, uri }]);
	}

	async rename(): Promise<void> {
		// Deliberately not faked: a wrong rename loses data. The service has to
		// implement it (and the provider has to fire Deleted + Created) before this
		// is wired up.
		throw new Error('codebun backend: rename is not implemented yet');
	}
}

/*
 * Add a folder to the window that is already open, instead of asking the workbench
 * to load it.
 *
 * Why not `vscode.openFolder`. In the web build that command does not open anything
 * itself: it hands the folder to `WorkspaceProvider.open`
 * (src/vs/code/browser/workbench/workbench.ts), which turns it into a URL
 *
 *   <origin><path>?folder=<encoded uri>
 *
 * and assigns it to `location.href`. The page therefore RELOADS with the folder as
 * its workspace, and that is where this breaks. `web.main.ts#initServices` resolves
 * and validates the workspace folder right at the start — before the web worker
 * extension host has started, and so before an `onFileSystem:` extension can
 * register anything. The workbench then reports
 *
 *   Ignoring the error while validating workspace folder codebun:c:/... -
 *   Unable to resolve filesystem provider with relative file path 'codebun:c:/...'
 *
 * drops the folder, reloads once more to retry, and the race happens again on the
 * new page. The result, measured in the embedded engine, is a permanently blank
 * workbench: the page is reloading in a loop, not failing to render. (The same
 * build does the same in Chromium, so this is the workbench's startup order and not
 * the WebKit port.)
 *
 * Adding the folder here removes the race by construction: the extension is
 * necessarily running — it is the one executing this command — so the provider is
 * registered before the folder exists, rather than the other way round. As a bonus
 * a single-view shell no longer pays a full page reload (and the shutdown errors
 * that come with it) just to change folder.
 *
 * The trade-off, stated plainly: the folder is not part of the URL, so a reload
 * loses it. Persisting and restoring it is what the shell will do once it owns the
 * last-opened folder (ROADMAP Phase 2); it must not be done by putting the folder
 * back in the URL, which is the reload path above.
 */
async function openInThisWindow(folder: vscode.Uri): Promise<void> {
	const open = vscode.workspace.workspaceFolders ?? [];
	const name = folder.path.split('/').filter(Boolean).pop() ?? folder.path;
	if (!vscode.workspace.updateWorkspaceFolders(0, open.length, { uri: folder, name })) {
		throw new Error(`${folder.toString(true)} cannot be added to this window`);
	}
}

export function activate(context: vscode.ExtensionContext): void {

	context.subscriptions.push(
		vscode.workspace.registerFileSystemProvider('codebun', new CodebunFileSystemProvider(), { isCaseSensitive: true })
	);

	context.subscriptions.push(vscode.commands.registerCommand('codebun.openFolder', async () => {
		// The web build's "Open Folder" expects a remote authority and does not ask
		// the OS for a path, so this path is typed. When the shell exposes its first
		// native dialog (ROADMAP Phase 2, "a folder dialog"), this becomes a picker
		// and the prompt goes away.
		const path = await vscode.window.showInputBox({
			title: 'Codebun — open folder',
			prompt: 'Absolute path on this machine (the native picker arrives with the vshell dialog API)',
			value: 'C:/',
		});
		if (!path) {
			return;
		}

		try {
			await openInThisWindow(vscode.Uri.from({ scheme: 'codebun', path: path.replace(/\\/g, '/') }));
		} catch (error) {
			await vscode.window.showErrorMessage(`Codebun could not open ${path}: ${error}`);
		}
	}));

	context.subscriptions.push(vscode.commands.registerCommand('codebun.status', async () => {
		// A deliberately trivial round-trip: it proves the extension is running in
		// the web extension host AND that the Bun service is reachable, which are
		// the two things that fail independently when something is wrong.
		try {
			const hello = await backendJson<{ ok: boolean; pid: number; cwd: string; version: string }>('/hello');
			await vscode.window.showInformationMessage(
				`Codebun backend: ok, pid ${hello.pid}, ${hello.version}, cwd ${hello.cwd}`
			);
		} catch (error) {
			await vscode.window.showErrorMessage(`Codebun backend unreachable: ${error}`);
		}
	}));
}

export function deactivate(): void { /* nothing to release */ }
