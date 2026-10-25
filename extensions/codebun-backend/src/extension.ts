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
 * The service listens on 127.0.0.1 and requires a per-run token the shell
 * generates and delivers out-of-band: the engine injects it into the page as a
 * document-start user script (never a URL, never an HTTP response a local process
 * could fetch), the page re-broadcasts it on a same-origin BroadcastChannel, and
 * this extension sends it on every call as X-Codebun-Token. The Bun side rejects
 * a missing/mismatched token with 401 (web/backend.js).
 *
 * The boundary this gives is "the engine delivered the page", not cryptography
 * against a local process: the token's secrecy rests on the BroadcastChannel
 * being origin-scoped and not network reachable. That is a real step up from the
 * Origin-only check it replaces (forgeable by any local process), and it is what
 * makes a destructive endpoint safe to add next — but do not describe it as
 * isolation. When the shell sets no token (standalone dev), the service is open.
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

/*
 * Session data the shell sent to the page (see the SECURITY note above).
 *
 * `token` is filled in by the bootstrap handshake below and attached to every
 * request. `folder` is only read once, at activation, to open the workspace.
 */
const session: { token?: string } = {};

/* The page broadcasts { token, folder } on this channel; the extension host
 * worker listens on it. Both sides are same-origin, which is what scopes it. */
const BOOTSTRAP_CHANNEL = 'codebun-bootstrap';

interface Bootstrap {
	token?: string;
	folder?: string;
}

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
	const headers = new Headers(init?.headers);
	if (session.token) {
		headers.set('x-codebun-token', session.token);
	}
	const response = await fetch(WORKER_ORIGIN + ENDPOINT + path, { ...init, headers });
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

/* A Windows path from the native dialog (C:\Users\...) becomes a codebun: Uri the
 * provider understands; the backend's toFsPath turns the slash form back into a
 * real path. */
function bootstrapUri(folder: string): vscode.Uri {
	return vscode.Uri.from({ scheme: 'codebun', path: folder.replace(/\\/g, '/') });
}

/*
 * One request/response round-trip with the shell, over the BroadcastChannel.
 *
 * `request` builds the message to send (it is handed a correlation id); `select`
 * returns a Box<T> when a reply matches, or undefined to keep waiting. The
 * message is re-sent every 250 ms until a reply arrives or the timeout elapses,
 * because a channel has no replay: the page (or this worker) may not have been
 * listening yet when the first send happened, and whichever started later would
 * otherwise wait forever.
 *
 * Resolves to undefined on timeout, so "no shell answered" is a value callers
 * handle, not a hang.
 */
interface Box<T> { value: T }

function shellRequest<T>(
	request: (id: string) => object,
	select: (data: any) => Box<T> | undefined,
	timeoutMs: number
): Promise<T | undefined> {
	return new Promise(resolve => {
		const channel = openBootstrapChannel();
		if (!channel) {
			resolve(undefined);
			return;
		}

		const id = `q${Date.now().toString(36)}${Math.random().toString(36).slice(2, 8)}`;
		let settled = false;
		let retry: ReturnType<typeof setInterval> | undefined;
		const finish = (value: T | undefined) => {
			if (settled) {
				return;
			}
			settled = true;
			if (retry) {
				clearInterval(retry);
			}
			try { channel.close(); } catch { /* already closed */ }
			resolve(value);
		};

		channel.onmessage = (event: MessageEvent) => {
			const box = select(event.data);
			if (box) {
				finish(box.value);
			}
		};

		let attempts = 0;
		const maxAttempts = Math.max(1, Math.round(timeoutMs / 250));
		retry = setInterval(() => {
			if (settled) {
				return;
			}
			if (++attempts >= maxAttempts) {
				finish(undefined);
				return;
			}
			try { channel.postMessage(request(id)); } catch { /* closed */ }
		}, 250);
		try { channel.postMessage(request(id)); } catch { /* closed */ }
	});
}

/* The bootstrap channel, or undefined where the global is missing.
 *
 * Returns the instance instead of being annotated at the call site on purpose:
 * this extension compiles with `types: ["node"]` and no DOM lib, where
 * `BroadcastChannel` is declared as a global VALUE only. Naming it as a type is
 * then an error — TS2749, "refers to a value, but is being used as a type" — and
 * it is exactly the kind of thing the esbuild bundle does not catch, because
 * esbuild only strips types. (Found by the build's `bun check`.) */
function openBootstrapChannel() {
	try {
		return new BroadcastChannel(BOOTSTRAP_CHANNEL);
	} catch {
		return undefined;
	}
}

/* The shell's session token and the folder it opened at startup (either may be
 * empty: standalone dev, or the user cancelled the dialog). */
async function requestBootstrap(): Promise<Bootstrap> {
	const box = await shellRequest<Bootstrap>(
		() => ({ type: 'codebun:hello' }),
		data => data?.type === 'codebun:bootstrap' ? { value: { token: data.token, folder: data.folder } } : undefined,
		5000
	);
	return box ?? {};
}

/*
 * The shell's native folder picker, on demand (vshell.dialog.openFolder, via the
 * page). Returns:
 *   undefined        -> no shell answered (standalone dev): the caller falls back
 *   { folder: '' }   -> the user cancelled
 *   { folder: path } -> a folder was chosen
 * The long timeout covers a user deliberating: the dialog is modal, so the reply
 * only arrives once it closes.
 */
async function pickFolderInShell(): Promise<{ folder: string } | undefined> {
	return shellRequest<{ folder: string }>(
		id => ({ type: 'codebun:pickFolder', id }),
		data => data?.type === 'codebun:folderPicked'
			? { value: { folder: typeof data.folder === 'string' ? data.folder : '' } }
			: undefined,
		60000
	);
}

/*
 * The integrated terminal.
 *
 * A VS Code terminal is a Pseudoterminal plus a transport. The transport here is
 * a WebSocket to the Bun service, which owns the real PTY (bun-pty, i.e. ConPTY
 * on Windows). The two halves are independent: this class only moves bytes and
 * window size, and the shell inside never knows a browser is involved.
 *
 * The token rides in the query string because a WebSocket built by the browser
 * cannot carry request headers (web/backend.js accepts either carrier).
 */
const TERMINAL_ENDPOINT = `${ENDPOINT}/terminal`;

function terminalSocketUrl(cols: number, rows: number, cwd?: string): string {
	const base = WORKER_ORIGIN.replace(/^http/, 'ws');
	const params = new URLSearchParams();
	params.set('cols', String(cols));
	params.set('rows', String(rows));
	if (cwd) {
		params.set('cwd', cwd);
	}
	if (session.token) {
		params.set('token', session.token);
	}
	return `${base}${TERMINAL_ENDPOINT}?${params.toString()}`;
}

type TerminalFrame =
	| { t: 'data'; d: string }
	| { t: 'exit'; code?: number; signal?: number | string }
	| { t: 'error'; message: string };

class CodebunPseudoterminal implements vscode.Pseudoterminal {
	private readonly _onDidWrite = new vscode.EventEmitter<string>();
	readonly onDidWrite: vscode.Event<string> = this._onDidWrite.event;
	private readonly _onDidClose = new vscode.EventEmitter<number | void>();
	readonly onDidClose: vscode.Event<number | void> = this._onDidClose.event;
	private socket: WebSocket | undefined;

	constructor(private readonly cwd: string | undefined) { }

	open(initial: vscode.TerminalDimensions | undefined): void {
		let socket: WebSocket;
		try {
			socket = new WebSocket(terminalSocketUrl(initial?.columns ?? 80, initial?.rows ?? 24, this.cwd));
		} catch (error) {
			this._onDidWrite.fire(`codebun: could not open the terminal: ${error}\r\n`);
			this._onDidClose.fire(1);
			return;
		}
		this.socket = socket;

		socket.onmessage = (event: MessageEvent) => {
			let frame: TerminalFrame;
			try {
				frame = JSON.parse(typeof event.data === 'string' ? event.data : '');
			} catch {
				return; // not ours, or not JSON: ignore instead of breaking the pane
			}
			if (frame.t === 'data') {
				this._onDidWrite.fire(frame.d);
			} else if (frame.t === 'exit') {
				this._onDidWrite.fire(`\r\n[process exited with code ${frame.code ?? '?'}]\r\n`);
				this._onDidClose.fire(typeof frame.code === 'number' ? frame.code : undefined);
			} else if (frame.t === 'error') {
				this._onDidWrite.fire(`\r\ncodebun: ${frame.message}\r\n`);
				this._onDidClose.fire(1);
			}
		};
		socket.onclose = () => this._onDidClose.fire(undefined);
		socket.onerror = () => { /* onclose always follows, and fires the close */ };
	}

	close(): void {
		try { this.socket?.close(); } catch { /* already closed */ }
		this.socket = undefined;
	}

	handleInput(data: string): void {
		this.send({ t: 'data', d: data });
	}

	setDimensions(dimensions: vscode.TerminalDimensions): void {
		this.send({ t: 'resize', cols: dimensions.columns, rows: dimensions.rows });
	}

	private send(frame: object): void {
		try {
			if (this.socket?.readyState === WebSocket.OPEN) {
				this.socket.send(JSON.stringify(frame));
			}
		} catch { /* the socket went away mid-write */ }
	}
}

/* Where a new terminal should start: the first workspace folder as a plain fs
 * path (codebun:C:/x -> C:/x, which the backend's toFsPath resolves again). */
function workspaceFsPath(): string | undefined {
	return (vscode.workspace.workspaceFolders ?? [])[0]?.uri.path || undefined;
}

export function activate(context: vscode.ExtensionContext): void {

	context.subscriptions.push(
		vscode.workspace.registerFileSystemProvider('codebun', new CodebunFileSystemProvider(), { isCaseSensitive: true })
	);

	// The terminal: registerTerminalProfileProvider puts "Codebun" in the
	// terminal dropdown's profile list; the command is the same thing reachable
	// from the palette. Both build a Pseudoterminal over the WS the backend
	// serves, so nothing here touches the PTY directly.
	context.subscriptions.push(
		vscode.window.registerTerminalProfileProvider('codebun.terminal', {
			provideTerminalProfile: () => new vscode.TerminalProfile({
				name: 'Codebun',
				pty: new CodebunPseudoterminal(workspaceFsPath()),
			}),
		})
	);

	context.subscriptions.push(vscode.commands.registerCommand('codebun.terminal.new', () => {
		vscode.window.createTerminal({
			name: 'Codebun',
			pty: new CodebunPseudoterminal(workspaceFsPath()),
		}).show();
	}));

	// Pick up the shell's session data and open the folder it chose, without a
	// reload: the provider above is registered before this runs, so the folder
	// can be added to this window. (openInThisWindow explains why a reload —
	// which is what the workbench's own "Open Folder" does — loses it.)
	void (async () => {
		const boot = await requestBootstrap();
		if (boot.token) {
			session.token = boot.token;
		}
		if (boot.folder) {
			try {
				await openInThisWindow(bootstrapUri(boot.folder));
			} catch (error) {
				await vscode.window.showErrorMessage(`Codebun could not open ${boot.folder}: ${error}`);
			}
		}
	})();

	context.subscriptions.push(vscode.commands.registerCommand('codebun.openFolder', async () => {
		// Prefer the shell's native picker: it runs in the OS, on the folders the
		// user can actually see. Only when no shell answers (standalone web dev)
		// does this fall back to a typed path — the web build's own "Open Folder"
		// expects a remote authority and never asks the OS at all.
		let chosen = await pickFolderInShell();
		if (chosen === undefined) {
			const typed = await vscode.window.showInputBox({
				title: 'Codebun — open folder',
				prompt: 'No shell answered; type an absolute path on this machine',
				value: 'C:/',
			});
			chosen = { folder: typed ?? '' };
		}
		if (!chosen.folder) {
			return; // the user cancelled
		}

		try {
			await openInThisWindow(bootstrapUri(chosen.folder));
		} catch (error) {
			await vscode.window.showErrorMessage(`Codebun could not open ${chosen.folder}: ${error}`);
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
