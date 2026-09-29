// Disposable Electron (Chromium) target for Dropy's device checks. Mirrors the AppKit
// input fixture (Scripts/bench/InputFixture): two identical windows, A and B, each with
// a text field, a button and a scrollable list, plus a per-window menu command. Every
// input event a renderer receives and every effect it causes is written as one JSON
// line to the log, tagged with the window, so a harness can tell an event that reached
// the intended window from one that reached the other window, or nothing.
//
// Launch through LaunchServices so the process has a real launch date:
//   open -n DropyElectronFixture.app --args --log <log.jsonl> --commands <commands.txt>
//        [--mode input|animation] [--page <file.html>]
// Modes: `input` (default) opens A and B; `animation` opens one window showing --page,
// the name of a page bundled from Scripts/bench (placement, recovery and benchmark
// checks). Pages are bundled, never read from the repository: the app is launched
// through LaunchServices and reading ~/Documents would raise a privacy prompt.
//
// Commands are appended as lines to the commands file (Electron has no distributed
// notifications). The same vocabulary as the AppKit fixture:
//   state:<nonce>  reset  key:A|key:B  space:other|space:home  quit
// Logs contain only synthetic content typed by the harness. The app never loads remote
// content and runs with a throwaway profile (--user-data-dir is set by the launcher).
'use strict';
const { app, BrowserWindow, Menu, ipcMain } = require('electron');
const fs = require('fs');
const path = require('path');

function argument(name, fallback) {
  const index = process.argv.indexOf(name);
  return index >= 0 && index + 1 < process.argv.length ? process.argv[index + 1] : fallback;
}

const logPath = argument('--log', null);
const commandsPath = argument('--commands', null);
const mode = argument('--mode', 'input');
const page = argument('--page', null);
const started = Date.now();

// A throwaway profile, so no state reaches or comes from a person's Electron apps.
const profile = argument('--profile', null);
if (profile) app.setPath('userData', profile);

function log(object) {
  if (!logPath) return;
  const line = Object.assign({}, object, { t: Math.round(Date.now() - started) / 1000 });
  const sorted = {};
  for (const key of Object.keys(line).sort()) sorted[key] = line[key];
  fs.appendFileSync(logPath, JSON.stringify(sorted) + '\n');
}

// Private SkyLight calls for this process's own windows (see spaces.c). Optional:
// without the addon, `space:*` replies with an error and the harness records notRun.
let spaces = null;
try {
  spaces = require(path.join(process.resourcesPath, 'spaces.node'));
} catch (error) {
  spaces = null;
}

/** name -> { window, id } */
const windows = new Map();
let homeSpace = 0;

function windowNumber(window) {
  // "window:<CGWindowID>:0" on macOS.
  const match = /^window:(\d+):/.exec(window.getMediaSourceId());
  return match ? Number(match[1]) : 0;
}

function createWindow(name, x, y, file) {
  const window = new BrowserWindow({
    x, y, width: 520, height: 380, title: `Dropy electron ${name}`, show: false,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true, sandbox: true, nodeIntegration: false,
    },
  });
  window.on('page-title-updated', (event) => event.preventDefault());
  for (const [event, change] of [['focus', 'becameKey'], ['blur', 'resignedKey'],
    ['minimize', 'minimized'], ['restore', 'deminimized']]) {
    window.on(event, () => {
      log({ kind: 'focus', w: name, change });
      // Typing into whichever window is key edits its field, so a key event delivered
      // to the wrong window shows up as a text change there.
      if (change === 'becameKey' && mode === 'input') {
        window.webContents.executeJavaScript('window.fixtureFocusText && window.fixtureFocusText()').catch(() => {});
      }
    });
  }
  window.webContents.on('will-navigate', (event) => event.preventDefault());
  window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  window.loadFile(file);
  windows.set(name, { window, name });
  return window;
}

function focusedName() {
  const focused = BrowserWindow.getFocusedWindow();
  for (const [name, entry] of windows) if (entry.window === focused) return name;
  return null;
}

async function state(nonce) {
  const line = { kind: 'state', nonce, active: BrowserWindow.getFocusedWindow() !== null };
  for (const [name, { window }] of windows) {
    let content = {};
    try { content = await window.webContents.executeJavaScript('window.fixtureState()'); } catch (error) { content = {}; }
    const key = window.isFocused();
    line[name] = Object.assign({ id: windowNumber(window), key, main: key, minimized: window.isMinimized(),
      onScreen: window.isVisible() && !window.isMinimized() }, content);
  }
  log(line);
}

function moveA(toHome) {
  const entry = windows.get('A');
  if (!spaces || !entry) { log({ kind: 'space', error: 'unsupported' }); return; }
  const id = windowNumber(entry.window);
  const target = toHome ? homeSpace : spaces.otherDesktop(id);
  if (!target) { log({ kind: 'space', error: 'noOtherDesktop' }); return; }
  spaces.moveToSpace(id, target);
  setTimeout(() => log({ kind: 'space', A: spaces.spacesOf(id) }), 300);
}

function command(text) {
  if (text === 'quit') { app.quit(); return; }
  if (text === 'reset') {
    for (const { window } of windows.values()) window.webContents.executeJavaScript('window.fixtureReset()').catch(() => {});
    log({ kind: 'reset' });
    return;
  }
  if (text === 'key:A' || text === 'key:B') {
    const entry = windows.get(text.slice(4));
    if (!entry) return;
    app.focus({ steal: true });
    entry.window.show();
    entry.window.focus();
    return;
  }
  if (text === 'space:other' || text === 'space:home') { moveA(text === 'space:home'); return; }
  if (text.startsWith('state:')) { state(text.slice(6)); }
}

// Tails the commands file; each complete line is one command.
function watchCommands() {
  if (!commandsPath) return;
  if (!fs.existsSync(commandsPath)) fs.writeFileSync(commandsPath, '');
  let offset = fs.statSync(commandsPath).size;
  let pending = '';
  setInterval(() => {
    let size;
    try { size = fs.statSync(commandsPath).size; } catch (error) { return; }
    if (size < offset) offset = 0;
    if (size === offset) return;
    const handle = fs.openSync(commandsPath, 'r');
    const buffer = Buffer.alloc(size - offset);
    fs.readSync(handle, buffer, 0, buffer.length, offset);
    fs.closeSync(handle);
    offset = size;
    pending += buffer.toString('utf8');
    const lines = pending.split('\n');
    pending = lines.pop();
    for (const line of lines) if (line.trim()) command(line.trim());
  }, 25);
}

ipcMain.on('fixture-log', (event, record) => {
  let name = '?';
  for (const [key, entry] of windows) if (entry.window.webContents === event.sender) name = key;
  if (!record || typeof record !== 'object') return;
  log(Object.assign({}, record, { w: name }));
});

app.on('did-become-active', () => log({ kind: 'focus', w: 'app', change: 'appActive' }));
app.on('did-resign-active', () => log({ kind: 'focus', w: 'app', change: 'appInactive' }));
app.on('window-all-closed', () => app.quit());

app.whenReady().then(async () => {
  if (logPath) fs.writeFileSync(logPath, '');
  Menu.setApplicationMenu(Menu.buildFromTemplate([
    { role: 'appMenu' },
    { label: 'Test', submenu: [{
      label: 'Count in key window', accelerator: 'CmdOrCtrl+K',
      click: () => {
        const name = focusedName();
        if (!name) { log({ kind: 'effect', w: 'none', effect: 'command' }); return; }
        windows.get(name).window.webContents.executeJavaScript('window.fixtureCommand()').catch(() => {});
      },
    }] },
  ]));
  const loads = [];
  if (mode === 'animation') {
    const name = path.basename(page || 'animation.html');
    const window = createWindow('A', 80, 120, path.join(__dirname, 'pages', name));
    loads.push(new Promise((resolve) => window.webContents.once('did-finish-load', resolve)));
  } else {
    for (const [name, x] of [['A', 100], ['B', 660]]) {
      const window = createWindow(name, x, 160, path.join(__dirname, 'index.html'));
      loads.push(new Promise((resolve) => window.webContents.once('did-finish-load', resolve)));
    }
  }
  await Promise.all(loads);
  for (const { window } of windows.values()) window.show();
  windows.get(mode === 'animation' ? 'A' : 'B').window.focus();
  watchCommands();
  setTimeout(() => {
    const a = windows.get('A').window;
    homeSpace = spaces ? (spaces.spacesOf(windowNumber(a))[0] || 0) : 0;
    const ready = { kind: 'ready', pid: process.pid, A: windowNumber(a), electron: process.versions.electron,
      chrome: process.versions.chrome, spacesAddon: spaces !== null };
    if (windows.has('B')) ready.B = windowNumber(windows.get('B').window);
    log(ready);
    // Device-check scripts read the window from stdout as the AppKit fixture prints it.
    process.stdout.write(`fixture window=${ready.A} space=${homeSpace}\n`);
  }, 500);
});
