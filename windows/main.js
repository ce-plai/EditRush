'use strict';
// Electron main process: window, menu bar, file dialogs, single-instance file opening and the
// quit / close guard. The editor itself runs in the renderer (src/ui/app.js).

const { app, BrowserWindow, Menu, dialog, ipcMain, shell } = require('electron');
const path = require('path');
const { execFile } = require('child_process');

let win = null;
let allowClose = false;
const pendingFiles = [];

// Files passed on the command line (double-clicked .editrush / media files).
function filesFromArgs(argv) {
  return argv.slice(app.isPackaged ? 1 : 2).filter(a => !a.startsWith('-') && path.isAbsolute(a));
}

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', (_e, argv) => {
    const files = filesFromArgs(argv);
    if (win) {
      if (win.isMinimized()) win.restore();
      win.focus();
      if (files.length) win.webContents.send('open-files', files);
    }
  });
  pendingFiles.push(...filesFromArgs(process.argv));
  app.whenReady().then(createWindow);
}

function createWindow() {
  win = new BrowserWindow({
    width: 1440, height: 900, minWidth: 1020, minHeight: 640,
    backgroundColor: '#1c1c1f',
    title: 'EditRush',
    icon: path.join(__dirname, 'src', 'ui', 'icon.png'),
    webPreferences: { nodeIntegration: true, contextIsolation: false, backgroundThrottling: false },
    // EDITRUSH_NO_FOCUS=1 opens the window without taking keyboard focus (automated testing).
    show: process.env.EDITRUSH_NO_FOCUS !== '1',
  });
  if (process.env.EDITRUSH_NO_FOCUS === '1') win.once('ready-to-show', () => win.showInactive());
  win.loadFile(path.join(__dirname, 'src', 'index.html'));
  win.on('close', e => {
    if (allowClose) return;
    e.preventDefault();
    win.webContents.send('request-close');
  });
  win.on('focus', () => win.webContents.send('window-focus'));
  buildMenu();
}

// MARK: - Menu (accelerators mirror the macOS shortcuts with Ctrl in place of Cmd)

function send(command, arg) { if (win) win.webContents.send('command', command, arg); }

function buildMenu() {
  const item = (label, command, accelerator, extra = {}) => ({ label, accelerator, click: () => send(command), ...extra });
  const template = [
    { label: '&File', submenu: [
      item('New Project', 'newProject', 'Ctrl+N'),
      item('Open...', 'openProject', 'Ctrl+O'),
      { type: 'separator' },
      item('Save', 'save', 'Ctrl+S'),
      item('Save As...', 'saveAs', 'Ctrl+Shift+S'),
      { type: 'separator' },
      item('Import Media...', 'importMedia', 'Ctrl+I'),
      item('Export...', 'showExport', 'Ctrl+E'),
      { type: 'separator' },
      { label: 'Exit', click: () => win && win.close() },
    ] },
    { label: '&Edit', submenu: [
      item('Undo', 'undo', 'Ctrl+Z'),
      item('Redo', 'redo', 'Ctrl+Shift+Z'),
      item('Redo', 'redo', 'Ctrl+Y', { visible: false }),
      { type: 'separator' },
      item('Cut', 'cut', 'Ctrl+X'),
      item('Copy', 'copy', 'Ctrl+C'),
      item('Paste', 'paste', 'Ctrl+V'),
      item('Duplicate', 'duplicate', 'Ctrl+D'),
      { type: 'separator' },
      item('Delete', 'delete', 'Delete'),
      item('Ripple Delete', 'rippleDelete', 'Shift+Delete'),
      { type: 'separator' },
      item('Select All', 'selectAll', 'Ctrl+A'),
    ] },
    { label: '&Clip', submenu: [
      item('Split at Playhead', 'split', 'Ctrl+B'),
      item('Join Clips', 'join', 'Ctrl+J'),
      item('Close Gaps', 'closeGaps'),
      item('Detach Audio', 'detachAudio'),
      { type: 'separator' },
      item('Add Title', 'addTitle', 'Ctrl+T'),
      { type: 'separator' },
      item('Fade In 1s', 'fadeIn'),
      item('Fade Out 1s', 'fadeOut'),
      item('Remove Fades', 'removeFades'),
    ] },
    { label: '&View', submenu: [
      item('Zoom In', 'zoomIn', 'Ctrl+='),
      item('Zoom Out', 'zoomOut', 'Ctrl+-'),
      item('Zoom to Fit', 'zoomToFit', 'Shift+Z'),
      { type: 'separator' },
      item('Toggle Snapping', 'toggleSnapping', 'N'),
      { type: 'separator' },
      { label: 'Toggle Developer Tools', accelerator: 'Ctrl+Shift+I', command: 'devtools', click: () => win && win.webContents.toggleDevTools() },
    ] },
    { label: '&Playback', submenu: [
      item('Play / Pause', 'togglePlay', 'Space'),
      { type: 'separator' },
      item('Previous Frame', 'prevFrame', 'Left'),
      item('Next Frame', 'nextFrame', 'Right'),
      item('Back 1 Second', 'back1', 'Shift+Left'),
      item('Forward 1 Second', 'forward1', 'Shift+Right'),
      { type: 'separator' },
      item('Go to Start', 'goToStart', 'Home'),
      item('Go to End', 'goToEnd', 'End'),
      { type: 'separator' },
      item('Shuttle Back 1 Second', 'back1', 'J'),
      item('Stop', 'pause', 'K'),
      item('Play Forward', 'play', 'L'),
      { type: 'separator' },
      item('Nudge Left', 'nudgeLeft', ','),
      item('Nudge Right', 'nudgeRight', '.'),
    ] },
    { label: '&Help', submenu: [
      { label: 'Keyboard Shortcuts', click: () => shell.openPath(path.join(__dirname, 'README.md')) },
    ] },
  ];
  // Shortcuts are handled by the renderer's key handler (src/ui/app.js installKeys), which leaves
  // keys alone while typing in a text field. The menu shows them but does not register them.
  for (const menu of template) {
    for (const entry of menu.submenu) {
      if (entry.accelerator && entry.command !== 'devtools') entry.registerAccelerator = false;
    }
  }
  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}

// MARK: - IPC

ipcMain.handle('pending-files', () => pendingFiles.splice(0));

ipcMain.handle('dialog-open', (_e, options) => dialog.showOpenDialog(win, options));
ipcMain.handle('dialog-save', (_e, options) => dialog.showSaveDialog(win, options));
ipcMain.handle('dialog-message', (_e, options) => dialog.showMessageBox(win, options));
ipcMain.handle('user-data', () => app.getPath('userData'));

ipcMain.on('confirm-close', () => {
  allowClose = true;
  if (win) win.close();
});

ipcMain.on('set-title', (_e, title) => { if (win) win.setTitle(title); });

/// Installed font families (Windows font collection via PowerShell).
ipcMain.handle('font-families', () => new Promise((resolve, reject) => {
  const script = 'Add-Type -AssemblyName System.Drawing; (New-Object System.Drawing.Text.InstalledFontCollection).Families | ForEach-Object { $_.Name }';
  execFile('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', script], { windowsHide: true, maxBuffer: 4 << 20 }, (err, stdout, stderr) => {
    if (err) { reject(new Error(`listing fonts failed: ${err.message} ${stderr}`)); return; }
    resolve([...new Set(stdout.split(/\r?\n/).map(s => s.trim()).filter(Boolean))].sort((a, b) => a.localeCompare(b)));
  });
}));

app.on('window-all-closed', () => app.quit());
