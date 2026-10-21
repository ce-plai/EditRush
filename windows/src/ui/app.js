'use strict';
// Renderer entry: builds the window layout (toolbar, media bin | preview | inspector, timeline)
// and wires commands, keyboard shortcuts, drops, the status toast and the close guard.
// Port of EditRushApp.swift, MainView.swift, ShellActions.swift, ShellKeyMonitor.swift and
// ShellExportGuard.swift.

const { ipcRenderer } = require('electron');
const { droppedPathsOf } = require('./drop');
const M = require('../core/model');
const { EditorStore } = require('../core/store');
const { MediaCache } = require('../media/cache');
const { PlaybackController } = require('../engine/playback');
const { Exporter } = require('../engine/exporter');
const text = require('../engine/text');
const { h, icon, isTyping, closeContextMenu } = require('./dom');
const { Documents } = require('./documents');
const { MediaBin } = require('./mediabin');
const { Preview } = require('./preview');
const { Inspector } = require('./inspector');
const { Timeline } = require('./timeline');
const { ExportDialog } = require('./exportdialog');

const TIMELINE_FRACTION_KEY = 'shell.timelineFraction';
const DEFAULT_TIMELINE_FRACTION = 0.38;

class App {
  constructor() {
    this.store = new EditorStore();
    this.cache = new MediaCache();
    this.exporter = new Exporter(this.cache);
    this.documents = new Documents(this);
    this.listeners = {};
  }

  async start() {
    const root = document.getElementById('app');
    this.previewCanvas = h('canvas.frame');
    this.playback = new PlaybackController(this.store, this.cache, this.previewCanvas);

    this.toolbar = this.buildToolbar();
    this.bin = new MediaBin(this);
    this.preview = new Preview(this, this.previewCanvas);
    this.inspector = new Inspector(this);
    this.timeline = new Timeline(this);
    this.exportDialog = new ExportDialog(this);
    this.toast = h('div.toast', { style: { display: 'none' }, onclick: () => this.store.setStatus(null) });

    this.workspace = h('div.workspace', this.bin.root, h('div.vdivider'), this.preview.root, h('div.vdivider'), this.inspector.root, this.toast);
    this.splitHandle = h('div.split-handle', { title: 'Drag to resize the timeline' });
    root.append(this.toolbar, this.workspace, this.splitHandle, this.timeline.root, h('div.drop-highlight', h('div', 'Drop to import')));
    this.installSplit();
    this.installKeys();
    this.installDrops();
    this.installIPC();
    this.store.on('ui', () => this.updateChrome());
    this.store.on('project', () => this.updateChrome());
    this.exporter.onChange(() => this.exportChanged());

    document.fonts.addEventListener('loadingdone', () => { text.clearCache(); this.playback.invalidate(); });
    await this.documents.startSession();
    const files = await ipcRenderer.invoke('pending-files');
    if (files.length) await this.documents.openFiles(files);
    this.updateChrome();
  }

  // MARK: Toolbar

  buildToolbar() {
    this.undoBtn = h('button.tb-btn', { onclick: () => this.command('undo') }, icon('undo'), 'Undo');
    this.redoBtn = h('button.tb-btn', { onclick: () => this.command('redo') }, icon('redo'), 'Redo');
    this.titleInput = h('input', {
      placeholder: 'Project name', spellcheck: false, title: 'Rename project',
      onkeydown: e => {
        if (e.key === 'Enter') e.target.blur();
        if (e.key === 'Escape') { e.target.value = this.store.project.name; e.target.blur(); }
      },
      onblur: e => {
        if (e.target.value !== this.store.project.name) this.documents.renameProject(e.target.value);
        e.target.value = this.store.project.name;
      },
    });
    this.editedBadge = h('span.badge', 'Edited');
    this.exportBtn = h('button.tb-btn.accent', { onclick: () => this.command('showExport') });
    return h('div.toolbar',
      this.undoBtn, this.redoBtn,
      h('div.spacer'),
      h('div.project-title', icon('film', 18), this.titleInput, this.editedBadge),
      h('div.spacer'),
      h('button.tb-btn', { title: 'Import video, audio and images (Ctrl+I)', onclick: () => this.command('importMedia') }, icon('import'), 'Import'),
      h('button.tb-btn', { title: 'Add a title at the playhead (Ctrl+T)', onclick: () => this.command('addTitle') }, icon('title'), 'Title'),
      this.exportBtn);
  }

  updateChrome() {
    const s = this.store;
    this.undoBtn.disabled = !s.undoActionName;
    this.undoBtn.title = s.undoActionName ? `Undo ${s.undoActionName}` : 'Nothing to undo';
    this.redoBtn.disabled = !s.redoActionName;
    this.redoBtn.title = s.redoActionName ? `Redo ${s.redoActionName}` : 'Nothing to redo';
    if (document.activeElement !== this.titleInput) this.titleInput.value = s.project.name;
    this.editedBadge.style.display = s.isDirty ? '' : 'none';
    const title = `${s.project.name}${s.isDirty ? ' - Edited' : ''} - EditRush`;
    if (title !== this.lastTitle) { this.lastTitle = title; ipcRenderer.send('set-title', title); }
    this.updateExportButton();
    this.updateToast();
  }

  updateExportButton() {
    const ex = this.exporter;
    this.exportBtn.replaceChildren(...(ex.isExporting
      ? [h('span', `${Math.round(ex.progress * 100)}%`)]
      : [icon('export'), 'Export']));
    this.exportBtn.disabled = M.projectDuration(this.store.project) <= 0 && !ex.isExporting;
    this.exportBtn.title = ex.isExporting ? 'Show export progress' : 'Export the video (Ctrl+E)';
  }

  exportChanged() {
    const ex = this.exporter;
    this.updateExportButton();
    if (ex.state === this.lastExportState) return;
    this.lastExportState = ex.state;
    if (this.exportDialog.isOpen) return;
    if (ex.state === 'finished') this.store.setStatus(`Exported "${require('path').basename(ex.outputPath)}"`);
    if (ex.state === 'failed') this.store.setStatus(`Export failed: ${ex.message}`);
  }

  // MARK: Status toast (clears after 4 s)

  updateToast() {
    const message = this.store.statusMessage;
    if (message === this.toastMessage) return;
    this.toastMessage = message;
    clearTimeout(this.toastTimer);
    if (!message) { this.toast.style.display = 'none'; return; }
    const lower = message.toLowerCase();
    const problem = ["couldn't", 'could not', 'failed', 'error', 'missing', 'unsupported', "can't", 'cannot'].some(w => lower.includes(w));
    this.toast.className = 'toast' + (problem ? ' problem' : '');
    this.toast.replaceChildren(icon(problem ? 'warn' : 'check', 18), h('span', message));
    this.toast.style.display = 'flex';
    this.toast.title = 'Click to dismiss';
    if (!message.endsWith('...')) {
      this.toastTimer = setTimeout(() => { if (this.store.statusMessage === message) this.store.setStatus(null); }, 4000);
    }
  }

  // MARK: Resizable split (timeline height share remembered across launches)

  installSplit() {
    const minTop = 300, minBottom = 170;
    const read = () => { const v = Number(localStorage.getItem(TIMELINE_FRACTION_KEY)); return v > 0 && v < 1 ? v : DEFAULT_TIMELINE_FRACTION; };
    let fraction = read();
    const layout = () => {
      const available = window.innerHeight - this.toolbar.offsetHeight - this.splitHandle.offsetHeight;
      const upper = Math.max(minBottom, available - minTop);
      const bottom = Math.min(upper, Math.max(Math.min(minBottom, available), fraction * available));
      this.timeline.root.style.height = `${bottom}px`;
      this.timeline.resized();
      this.playback.invalidate();
    };
    this.splitHandle.addEventListener('mousedown', e => {
      e.preventDefault();
      const startY = e.clientY, startH = this.timeline.root.offsetHeight;
      const available = window.innerHeight - this.toolbar.offsetHeight - this.splitHandle.offsetHeight;
      const move = ev => { fraction = (startH - (ev.clientY - startY)) / available; layout(); };
      const up = () => {
        window.removeEventListener('mousemove', move);
        window.removeEventListener('mouseup', up);
        localStorage.setItem(TIMELINE_FRACTION_KEY, String(fraction));
      };
      window.addEventListener('mousemove', move);
      window.addEventListener('mouseup', up);
    });
    this.splitHandle.addEventListener('dblclick', () => { fraction = DEFAULT_TIMELINE_FRACTION; localStorage.setItem(TIMELINE_FRACTION_KEY, String(fraction)); layout(); });
    window.addEventListener('resize', layout);
    layout();
  }

  // MARK: Commands (menus, toolbar and keyboard all come through here)

  command(name, arg) {
    const s = this.store, pb = this.playback;
    const typing = isTyping();
    const textCommand = { undo: 'undo', redo: 'redo', cut: 'cut', copy: 'copy', paste: 'paste', selectAll: 'selectAll' }[name];
    if (typing && textCommand) { document.execCommand(textCommand); return; }
    if (this.exportDialog.isOpen && !['showExport'].includes(name)) return;
    const reveal = () => this.timeline.revealPlayhead();
    switch (name) {
      case 'newProject': return this.documents.newProject();
      case 'openProject': return this.documents.openWithDialog();
      case 'openRecent': return this.documents.openRecent(arg);
      case 'save': return this.documents.save();
      case 'saveAs': return this.documents.saveAs();
      case 'importMedia': return this.documents.importWithDialog();
      case 'showExport':
        if (M.projectDuration(s.project) <= 0 && !this.exporter.isExporting && this.exporter.state === 'idle') {
          s.setStatus('Add something to the timeline before exporting.');
          return;
        }
        pb.pause();
        return this.exportDialog.open();
      case 'undo': return s.undo();
      case 'redo': return s.redo();
      case 'cut': return s.cutSelection();
      case 'copy': return s.copySelection();
      case 'paste': return s.pasteAtPlayhead();
      case 'duplicate': return s.duplicateSelection();
      case 'delete': return s.deleteSelection(false);
      case 'rippleDelete': return s.deleteSelection(true);
      case 'selectAll': return s.selectAll();
      case 'split': return s.splitAtPlayhead();
      case 'join': return s.joinSelection();
      case 'closeGaps': return s.closeGaps();
      case 'detachAudio': return this.detachAudio(s.selectedClips);
      case 'addTitle': return s.addTextClip();
      case 'fadeIn': return s.setFades(1, null);
      case 'fadeOut': return s.setFades(null, 1);
      case 'removeFades': return s.setFades(0, 0);
      case 'zoomIn': return s.zoom(1.5);
      case 'zoomOut': return s.zoom(1 / 1.5);
      case 'zoomToFit': s.zoomToFit(); return this.timeline.scrollToStart();
      case 'toggleSnapping': s.toggleSnapping(); return s.setStatus(s.snappingEnabled ? 'Snapping on' : 'Snapping off');
      case 'togglePlay': return pb.togglePlay();
      case 'play': return pb.play();
      case 'pause': return pb.pause();
      case 'prevFrame': pb.stepFrames(-1); return reveal();
      case 'nextFrame': pb.stepFrames(1); return reveal();
      case 'back1': pb.seek(s.playhead - 1); return reveal();
      case 'forward1': pb.seek(s.playhead + 1); return reveal();
      case 'goToStart': pb.goToStart(); return reveal();
      case 'goToEnd': pb.goToEnd(); return reveal();
      case 'nudgeLeft': return s.nudgeSelection(arg || -1);
      case 'nudgeRight': return s.nudgeSelection(arg || 1);
      default: throw new Error(`Unknown command ${name}`);
    }
  }

  /// Detaches audio from every detachable clip in `clips` as one undo step.
  detachAudio(clips) {
    const key = `detach-${M.uuid()}`;
    for (const c of clips.filter(c => this.store.canDetachAudio(c))) this.store.detachAudio(c.id, key);
    this.store.endCoalescing();
  }

  // MARK: Plain-key shortcuts (ignored while typing in a text field)

  installKeys() {
    window.addEventListener('keydown', e => {
      if (e.altKey || e.metaKey) return;
      if (e.ctrlKey) {
        const cmd = ctrlShortcut(e);
        if (!cmd) return;
        // While typing, text editing shortcuts stay with the text field.
        if (isTyping() && ['undo', 'redo', 'cut', 'copy', 'paste', 'selectAll'].includes(cmd)) return;
        e.preventDefault();
        if (!e.repeat) this.command(cmd);
        return;
      }
      if (isTyping() || this.exportDialog.isOpen || document.querySelector('.modal-back')) {
        if (e.key === 'Escape' && isTyping()) document.activeElement.blur();
        return;
      }
      const shift = e.shiftKey;
      const k = e.key;
      let cmd = null, arg, repeats = false;
      switch (k) {
        case ' ': if (!shift) cmd = 'togglePlay'; break;
        case 'ArrowLeft': cmd = shift ? 'back1' : 'prevFrame'; repeats = true; break;
        case 'ArrowRight': cmd = shift ? 'forward1' : 'nextFrame'; repeats = true; break;
        case 'ArrowUp': case 'Home': if (!shift) cmd = 'goToStart'; break;
        case 'ArrowDown': case 'End': if (!shift) cmd = 'goToEnd'; break;
        case 'Backspace': case 'Delete': cmd = shift ? 'rippleDelete' : 'delete'; break;
        case 'Escape': closeContextMenu(); this.store.setSelection([]); e.preventDefault(); return;
        default: {
          const c = k.toLowerCase();
          if (c === ',' || c === '<') { cmd = 'nudgeLeft'; arg = shift ? -10 : -1; repeats = true; }
          else if (c === '.' || c === '>') { cmd = 'nudgeRight'; arg = shift ? 10 : 1; repeats = true; }
          else if (c === 'j' && !shift) { cmd = 'back1'; repeats = true; }
          else if (c === 's' && !shift) cmd = 'split';
          else if (c === 'k' && !shift) cmd = 'pause';
          else if (c === 'l' && !shift) cmd = 'play';
          else if (c === 'n' && !shift) cmd = 'toggleSnapping';
          else if (c === 'z' && shift) cmd = 'zoomToFit';
        }
      }
      if (!cmd) return;
      e.preventDefault();
      if (e.repeat && !repeats) return;
      this.command(cmd, arg);
    });
  }

  // MARK: Explorer drops (anywhere without its own drop target)

  installDrops() {
    const highlight = document.querySelector('.drop-highlight');
    let depth = 0;
    const hasFiles = e => [...(e.dataTransfer?.types || [])].includes('Files');
    window.addEventListener('dragenter', e => { if (hasFiles(e)) { depth++; highlight.classList.add('on'); } });
    window.addEventListener('dragleave', e => { if (hasFiles(e) && --depth <= 0) { depth = 0; highlight.classList.remove('on'); } });
    window.addEventListener('dragover', e => { if (hasFiles(e)) { e.preventDefault(); e.dataTransfer.dropEffect = 'copy'; } });
    window.addEventListener('drop', e => {
      depth = 0;
      highlight.classList.remove('on');
      if (!hasFiles(e)) return;
      e.preventDefault();
      this.documents.openFiles(droppedPathsOf(e));
    });
    this.dropHighlight = highlight;
  }

  hideDropHighlight() { this.dropHighlight.classList.remove('on'); }

  // MARK: IPC from the main process

  installIPC() {
    ipcRenderer.on('command', (_e, name, arg) => this.command(name, arg));
    ipcRenderer.on('open-files', (_e, files) => this.documents.openFiles(files));
    ipcRenderer.on('window-focus', () => this.cache.retryFailed());
    ipcRenderer.on('request-close', () => this.requestClose());
  }

  /// Close / quit: during an export asks first; always flushes pending changes.
  async requestClose() {
    if (this.closing) return;
    if (this.exporter.isExporting) {
      const name = this.exporter.outputPath ? `"${require('path').basename(this.exporter.outputPath)}"` : 'The video';
      const r = await ipcRenderer.invoke('dialog-message', {
        type: 'warning', message: 'An export is in progress',
        detail: `${name} is ${Math.floor(this.exporter.progress * 100)}% exported. If you quit now, the export stops and no file is written.`,
        buttons: ['Keep Exporting', 'Stop Export and Quit'], defaultId: 0, cancelId: 0, noLink: true,
      });
      if (r.response !== 1) return;
      this.closing = true;
      this.exporter.cancel();
      const deadline = Date.now() + 10000;
      while (this.exporter.isExporting && Date.now() < deadline) await new Promise(res => setTimeout(res, 20));
    }
    this.closing = true;
    if (document.activeElement) document.activeElement.blur();
    this.playback.pause();
    this.documents.flush();
    ipcRenderer.send('confirm-close');
  }
}

/// Command for a Ctrl shortcut (the same keys the menu bar shows), or null.
function ctrlShortcut(e) {
  const k = e.key.toLowerCase(), shift = e.shiftKey;
  const map = shift
    ? { s: 'saveAs', z: 'redo' }
    : { n: 'newProject', o: 'openProject', s: 'save', i: 'importMedia', e: 'showExport', z: 'undo', y: 'redo', x: 'cut', c: 'copy',
      v: 'paste', d: 'duplicate', a: 'selectAll', b: 'split', j: 'join', t: 'addTitle', '=': 'zoomIn', '+': 'zoomIn', '-': 'zoomOut' };
  return map[k] || null;
}

let app = null;
function start() {
  app = new App();
  app.start().catch(e => {
    console.error('EditRush failed to start', e);
    document.body.append(h('pre', { style: { color: '#ff8080', padding: '20px', whiteSpace: 'pre-wrap' } }, `EditRush failed to start:\n${e.stack}`));
  });
  window.editRush = app;
}

module.exports = { start };
