"use strict";
// The Brick's file page: views of the data card for games, saves and BIOS files, using only the
// HTTP interface of dufs, the file server (listed in docs/system-image.md, "Browser page").
// Paths here are relative to the card: folders end in "/", and the card's root is "".

/** Specular's built-in systems (builtin_systems() in Specular's library). A folder under roms/
 *  named after one tells Specular the system of games it can't tell apart by themselves. Offered
 *  as new folder names, and shown with the system's name. */
const SYSTEMS = {
	gb: "Game Boy", gbc: "Game Boy Color", gba: "Game Boy Advance", nes: "NES",
	snes: "Super Nintendo", md: "Mega Drive", ps1: "PlayStation",
};

/** The tabs: each shows the card from its own folder. Hidden entries (names starting with ".")
 *  are left out of all but "files" (`showHidden`), as Specular ignores them. `states`: also list the save-state
 *  folders (showStates). */
const VIEWS = {
	games: { title: "Games", root: "roms/",
		hint: "Games can be in any folders: Specular works out each game's system itself. A folder per system (gba, ps1, …) keeps the card tidy, and tells Specular the system of disc images (.cue, .chd, …) that more than one system uses." },
	saves: { title: "Saves", root: "saves/", states: true,
		hint: "Battery saves, named after their games and in matching folders: roms/gba/Golden Sun.gba saves to saves/gba/Golden Sun.srm." },
	bios: { title: "BIOS", root: "bios/",
		hint: "BIOS files. Emulators look for them by exact file name, so keep the names they expect." },
	files: { title: "All files", root: "", showHidden: true,
		hint: "Everything on the card. backups/, made when installing to internal storage, holds the copy of TrimUI's system: your way back to it, so don't delete it. updates/ is where Crystaline OS update files (.update) go. logs/ has reports of installs, updates and card repairs. config/ holds your settings. cache/ holds box art and game lists, and is safe to delete." },
};

/** The largest file FAT32 can hold. */
const FAT32_MAX = 2 ** 32 - 1;
/** Uploads are written under their name plus this, and renamed once complete. */
const PARTIAL = ".uploading";
const UNREACHABLE = "Can't reach the Brick. Is its File transfer screen open, and is this device on the same network?";

const $ = id => document.getElementById(id);

// --- Talking to dufs --------------------------------------------------------------------------

/** The address of a card path. */
const url = path => "/" + path.split("/").map(encodeURIComponent).join("/");

/** A failed request as a message for the user: the status and dufs's own text, if any. */
function describe(status, statusText, body) {
	if (status === 0) return UNREACHABLE;
	let msg = `${status} ${statusText}`;
	if (body) msg += `: ${body}`;
	// dufs sends no text with these; the usual causes on a FAT32 card:
	if (status === 500) msg += " (the card may be full, or the name not allowed on it)";
	return msg;
}

/** Sends a request; unless it succeeds, throws an Error with describe()'s message and `status`
 *  (0 when dufs couldn't be reached). */
async function call(method, path, headers = {}, query = "") {
	let res;
	try {
		res = await fetch(url(path) + query, { method, headers, cache: "no-store" });	// never a stale listing or size
	} catch {
		throw Object.assign(new Error(UNREACHABLE), { status: 0 });
	}
	if (!res.ok) throw Object.assign(new Error(describe(res.status, res.statusText, await res.text())), { status: res.status });
	return res;
}

/** A folder's entries: { path_type: "Dir" | "File" | "SymlinkDir" | "SymlinkFile", name,
 *  mtime (ms), size }, where a folder's size is its number of entries (dufs stops counting at
 *  1000). In search results (`query` "&q=…"), names are paths below `dir`. */
async function list(dir, query = "") {
	return (await (await call("GET", dir, {}, `?json${query}`)).json()).paths;
}

/** The size of what is at `path` (dufs answers HEAD for a folder too), or -1 if nothing is. Finds
 *  names that differ only in case, as FAT32 ignores case. */
async function sizeOf(path) {
	try {
		const res = await call("HEAD", path);
		return Number(res.headers.get("content-length"));
	} catch (e) {
		if (e.status === 404) return -1;
		throw e;
	}
}

// --- Page state and drawing -------------------------------------------------------------------

/** What is shown: a view and a folder in it (a card path). Kept in the address after "#" as
 *  <view>/<folder below the view's root>: #games/gba/ is roms/gba/. */
let viewName = "games", view = VIEWS.games, dir = "roms/";

function readHash() {
	const [name, ...rest] = location.hash.slice(1).split("/");
	viewName = name in VIEWS ? name : "games";
	view = VIEWS[viewName];
	try {
		dir = view.root + rest.map(decodeURIComponent).join("/");
	} catch {
		dir = view.root;	// a mangled address
	}
	if (dir && !dir.endsWith("/")) dir += "/";
}

/** The page address of a folder (a card path) in a view, by default the current one. */
const link = (path, name = viewName) => "#" + name + url(path.slice(VIEWS[name].root.length));

/** Makes an element: el("a", { href: "#" }, "text", child, …). */
function el(tag, attrs = {}, ...children) {
	const e = document.createElement(tag);
	for (const [k, v] of Object.entries(attrs)) {
		if (k.startsWith("on")) e.addEventListener(k.slice(2), v);
		else e.setAttribute(k, v);
	}
	e.append(...children);
	return e;
}

/** Sizes in powers of 1000, as operating systems mostly show them. */
function formatSize(n) {
	const units = ["B", "KB", "MB", "GB", "TB"];
	let i = 0;
	while (n >= 1000 && i < units.length - 1) { n /= 1000; i++; }
	return `${i ? n.toFixed(n < 10 ? 1 : 0) : n} ${units[i]}`;
}

/** "1 item", "3 items"; dufs stops counting a folder's entries at 1000. */
const count = (n, word) => n >= 1000 ? `1000+ ${word}s` : `${n} ${word}${n === 1 ? "" : "s"}`;

const baseName = path => path.replace(/\/$/, "").split("/").pop();
const isDir = item => item.path_type.endsWith("Dir");	// SymlinkDir too

function show() {
	readHash();
	for (const a of $("tabs").children) a.classList.toggle("active", a.dataset.view === viewName);
	$("hint").textContent = dir === view.root ? view.hint : "";
	$("zip").href = url(dir) + "?zip";
	$("mkdir").hidden = true;
	$("folder-names").replaceChildren(...(dir === "roms/" ? Object.keys(SYSTEMS) : []).map(
		k => el("option", { value: k }, SYSTEMS[k])));

	const crumbs = [el("a", { href: link(view.root) }, view.title)];
	const parts = dir.slice(view.root.length).split("/").filter(Boolean);
	parts.forEach((p, i) => crumbs.push(" / ", el("a", { href: link(view.root + parts.slice(0, i + 1).join("/") + "/") }, p)));
	$("crumbs").replaceChildren(...crumbs);

	refresh();
	showStates();
}

/** Lists the current folder again. */
async function refresh() {
	const shown = dir;
	let items, error;
	try {
		items = await list(dir);
	} catch (e) {
		error = e;
	}
	if (shown !== dir) return;	// the user moved on meanwhile
	if (error) {
		$("status").textContent = error.message;
		$("list").replaceChildren();
		return;
	}
	if (!view.showHidden) items = items.filter(i => !i.name.startsWith("."));
	$("status").textContent = items.length ? "" : "Nothing here yet. Upload files, or drop them on this page.";
	$("list").replaceChildren(...items.map(entryRow));
}

function entryRow(item) {
	const path = dir + item.name + (isDir(item) ? "/" : "");
	const del = el("button", { type: "button", class: "delete", onclick: () => remove(path, item) }, "Delete");
	if (isDir(item)) {
		const items = count(item.size, "item");
		return el("li", { class: "dir" },
			el("a", { class: "name", href: link(path) }, item.name + "/"),
			el("span", { class: "info" }, dir === "roms/" && SYSTEMS[item.name] ? `${SYSTEMS[item.name]} · ${items}` : items),
			del);
	}
	const partial = item.name.endsWith(PARTIAL);
	return el("li", { class: partial ? "partial" : "file" },
		el("a", { class: "name", href: url(path), download: item.name }, item.name),
		el("span", { class: "info" }, (partial ? "Unfinished upload · " : "") + formatSize(item.size) +
			" · " + new Date(item.mtime).toLocaleString()),
		del);
}

async function remove(path, item) {
	const what = isDir(item)
		? `the folder "${item.name}" and everything in it`
		: `"${item.name}"`;
	if (!confirm(`Delete ${what}? This can't be undone.`)) return;
	try {
		await call("DELETE", path);
	} catch (e) {
		alert(`Couldn't delete "${item.name}": ${e.message}`);
	}
	refresh();
}

/** In the Saves view: every .states folder under roms/, each downloadable as a zip, labelled by
 *  its games folder and linked in "All files" (the other views hide .states). */
async function showStates() {
	$("states").hidden = !(view.states && dir === view.root);
	if ($("states").hidden) return;
	let found;
	try {
		found = (await list("roms/", "&q=.states")).filter(i => isDir(i) && baseName(i.name) === ".states");
	} catch (e) {
		$("states-list").replaceChildren(el("li", {}, e.message));
		return;
	}
	$("states-list").replaceChildren(...(found.length ? found.map(i => {
		const path = `roms/${i.name}/`;
		return el("li", { class: "dir" },
			el("a", { class: "name", href: link(path, "files") }, path.replace(/\.states\/$/, "")),
			el("span", { class: "info" }, count(i.size, "file")),
			el("a", { class: "button", href: url(path) + "?zip", download: "" }, "Download as zip"));
	}) : [el("li", {}, "None yet.")]));
}

$("new-folder").onclick = () => {
	$("mkdir").hidden = !$("mkdir").hidden;
	if (!$("mkdir").hidden) $("mkdir-name").focus();
};
$("mkdir").onsubmit = async e => {
	e.preventDefault();
	const name = $("mkdir-name").value.trim();
	const problem = badName(name);
	if (problem) return alert(problem);
	try {
		await call("MKCOL", dir + name + "/");
		$("mkdir-name").value = "";
		$("mkdir").hidden = true;
	} catch (e) {
		alert(`Couldn't make the folder: ${e.message}`);
	}
	refresh();
};

// --- Uploads ----------------------------------------------------------------------------------
// One file at a time, in order. Each is written to "<name>.uploading" and renamed to its name once
// the card holds all of it, so a cut upload never looks like a complete game or save. Retrying a
// failed upload continues from the part already on the card. That is only safe because the browser
// still holds the same file: the list of uploads is lost on reload, and a later upload of the same
// name starts from the beginning.

/** Why a name can't be used on the FAT32 card, or "" if it can. */
function badName(name) {
	if (!name) return "A name is needed.";
	if (name === "." || name === "..") return `"${name}" can't be used as a name`;
	if (/["*/:<>?\\|\x00-\x1f]/.test(name)) return `"${name}": names on the card can't contain " * / : < > ? \\ |`;
	if (/[. ]$/.test(name)) return `"${name}": names on the card can't end with a dot or a space`;
	return "";
}

/** Files that operating systems leave beside the user's own, not worth uploading. */
const isJunk = name => name === ".DS_Store" || name.startsWith("._") || name === "Thumbs.db" || name === "desktop.ini";

/** @typedef {{ file: File, dest: string, state: "waiting"|"sending"|"done"|"failed"|"cancelled",
 *              row: HTMLElement, problem: string, xhr?: XMLHttpRequest, retried?: boolean }} Upload
 *  `problem`: why it can't be uploaded at all (no Retry). `retried`: set after a failure, so the
 *  next attempt continues from the .uploading part already on the card. */
/** @type {Upload[]} */
const uploads = [];
let pumping = false;

/** Queues `picked` ([{file, rel}]) for upload into the folder `into`. `rel` is a file's path below
 *  it: just its name, or with folders when a folder was picked or dropped. Asks once before
 *  replacing. */
async function addUploads(picked, into) {
	picked = picked.filter(p => !p.rel.split("/").some(isJunk));
	if (!picked.length) return;
	const fresh = [], taken = [];
	for (const { file, rel } of picked) {
		const u = { file, dest: into + rel, state: "waiting" };
		u.problem = rel.split("/").map(badName).find(Boolean) ||
			(file.size > FAT32_MAX ? `${formatSize(file.size)} is more than the card's FAT32 can hold in one file (4 GB)` : "");
		if (!u.problem) {
			try {
				if (await sizeOf(u.dest) >= 0) { taken.push(u); continue; }
			} catch (e) {
				return alert(e.message);
			}
		}
		fresh.push(u);
	}
	if (taken.length) {
		const names = taken.slice(0, 10).map(u => "  " + u.dest).join("\n") + (taken.length > 10 ? `\n  …and ${taken.length - 10} more` : "");
		if (confirm(`Already on the card:\n${names}\n\nReplace ${taken.length === 1 ? "it" : "them"}? (Cancel uploads only the others.)`)) fresh.push(...taken);
	}
	for (const u of fresh) {
		u.row = el("li", {});
		uploads.push(u);
		setState(u, u.problem ? "failed" : "waiting", u.problem);
		$("upload-list").append(u.row);
	}
	$("uploads").hidden = !uploads.length;
	pump();
}

/** Sends waiting uploads one at a time, in order; does nothing if already running. */
async function pump() {
	if (pumping) return;
	pumping = true;
	for (let u; (u = uploads.find(u => u.state === "waiting"));) {
		await send(u);
		if (u.dest.startsWith(dir)) refresh();
	}
	pumping = false;
}

async function send(u) {
	const temp = u.dest + PARTIAL;
	setState(u, "sending");
	try {
		// A part bigger than the file isn't this file's: start again. A complete part goes straight to
		// the check. An empty file still needs its PUT.
		const held = u.retried ? await sizeOf(temp) : -1;
		const from = held > 0 && held <= u.file.size ? held : 0;
		stopIfCancelled(u);
		if (from < u.file.size || u.file.size === 0) await transfer(u, temp, from);
		const got = await sizeOf(temp);
		if (got !== u.file.size) throw new Error(`the card holds ${formatSize(Math.max(got, 0))} of ${formatSize(u.file.size)}`);
		stopIfCancelled(u);
		await call("MOVE", temp, { Destination: location.origin + url(u.dest) });	// WebDAV wants a full URL
		setState(u, "done");
	} catch (e) {
		if (u.state === "cancelled") {
			call("DELETE", temp).catch(() => {});
			return;
		}
		u.retried = true;
		setState(u, "failed", e.message);
	}
}

/** Ends send() if the user cancelled while it waited for dufs. */
function stopIfCancelled(u) {
	if (u.state === "cancelled") throw new Error("Cancelled");
}

/** Sends the file from byte `from` on (PATCH appends to what the card holds), streaming it from
 *  disk: the browser never reads a whole file into memory. Shows progress. */
function transfer(u, path, from) {
	return new Promise((resolve, reject) => {
		const x = u.xhr = new XMLHttpRequest();
		const start = Date.now();
		x.open(from ? "PATCH" : "PUT", url(path));
		if (from) x.setRequestHeader("X-Update-Range", "append");
		x.upload.onprogress = e => u.state === "sending" && progress(u, from, e.loaded, start);
		x.onload = () => x.status < 300 ? resolve() : reject(new Error(describe(x.status, x.statusText, x.responseText)));
		x.onerror = () => reject(new Error(UNREACHABLE));
		x.onabort = () => reject(new Error("Cancelled"));
		x.send(from ? u.file.slice(from) : u.file);
	});
}

function progress(u, from, sent, start) {
	const bar = u.row.querySelector("progress"), info = u.row.querySelector(".info");
	const done = from + sent, rate = sent / Math.max((Date.now() - start) / 1000, 0.001);
	bar.value = done / Math.max(u.file.size, 1);
	const left = (u.file.size - done) / rate;
	info.textContent = `${formatSize(done)} of ${formatSize(u.file.size)} · ${formatSize(rate)}/s` +
		(done >= u.file.size ? " · finishing" : !sent ? "" : left < 60 ? ` · ${Math.ceil(left)} s left` : ` · ${Math.ceil(left / 60)} min left`);
}

/** Redraws an upload's row for its new state. */
function setState(u, state, message = "") {
	u.state = state;
	const text = {
		waiting: "Waiting", sending: "Starting", done: "Done", cancelled: "Cancelled",
		failed: `Failed: ${message}`,
	}[state];
	const buttons = [];
	if (state === "waiting" || state === "sending")
		buttons.push(el("button", { type: "button", onclick: () => cancel(u) }, "Cancel"));
	if (state === "failed" && !u.problem)
		buttons.push(el("button", { type: "button", onclick: () => { setState(u, "waiting"); pump(); } }, "Retry"));
	u.row.className = state;
	u.row.replaceChildren(
		el("span", { class: "name" }, u.dest),
		el("span", { class: "info" }, text),
		...(state === "sending" ? [el("progress", { max: 1, value: 0 })] : []),
		...buttons);
}

function cancel(u) {
	setState(u, "cancelled");
	u.xhr?.abort();	// nothing if it's not sending
}

// Failed uploads stay, to be retried.
$("clear-uploads").onclick = () => {
	for (const u of uploads.filter(u => u.state === "done" || u.state === "cancelled")) {
		u.row.remove();
		uploads.splice(uploads.indexOf(u), 1);
	}
	$("uploads").hidden = !uploads.length;
};

// --- Picking and dropping files ---------------------------------------------------------------

for (const id of ["pick-files", "pick-folder"]) {
	$(id).onchange = e => {
		addUploads([...e.target.files].map(file => ({ file, rel: file.webkitRelativePath || file.name })), dir);
		e.target.value = "";
	};
}

/** The files dropped, with folders followed. The entries must be taken before the first await:
 *  the browser empties the drop's data when its handler returns. */
async function dropped(data) {
	const entries = [...data.items].map(i => i.webkitGetAsEntry?.()).filter(Boolean);
	if (!entries.length) return [...data.files].map(file => ({ file, rel: file.name }));
	const out = [];
	const walk = async (entry, prefix) => {
		if (entry.isFile) {
			out.push({ file: await new Promise((ok, fail) => entry.file(ok, fail)), rel: prefix + entry.name });
		} else if (entry.isDirectory) {
			const reader = entry.createReader();
			// readEntries gives a folder's entries in batches, then an empty one.
			for (let batch; (batch = await new Promise((ok, fail) => reader.readEntries(ok, fail))).length;) {
				for (const child of batch) await walk(child, prefix + entry.name + "/");
			}
		}
	};
	for (const entry of entries) await walk(entry, "");
	return out;
}

// dragenter and dragleave come for every element the drag crosses: counting them hides the overlay
// only when the drag leaves the page.
let dragDepth = 0;
const isFileDrag = e => e.dataTransfer?.types.includes("Files");
addEventListener("dragenter", e => { if (isFileDrag(e)) { dragDepth++; $("drop").hidden = false; } });
addEventListener("dragleave", e => { if (isFileDrag(e) && --dragDepth <= 0) { dragDepth = 0; $("drop").hidden = true; } });
addEventListener("dragover", e => { if (isFileDrag(e)) e.preventDefault(); });
addEventListener("drop", async e => {
	if (!isFileDrag(e)) return;
	e.preventDefault();
	dragDepth = 0;
	$("drop").hidden = true;
	const into = dir;	// as dropped, though reading folders takes a while
	try {
		addUploads(await dropped(e.dataTransfer), into);
	} catch (err) {
		alert(`Couldn't read what was dropped: ${err.message}`);
	}
});

addEventListener("beforeunload", e => {
	if (uploads.some(u => u.state === "waiting" || u.state === "sending")) {
		e.preventDefault();
		e.returnValue = "";
	}
});

// dufs serves this page at every folder's address (/roms/gba/). Such a folder is shown from "/" in
// "All files", so where the page is is always in the address after "#".
if (location.pathname !== "/") {
	location.replace("/#files" + location.pathname);
} else {
	addEventListener("hashchange", show);
	show();
}
