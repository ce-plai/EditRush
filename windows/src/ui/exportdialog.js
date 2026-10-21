'use strict';
// Export sheet: resolution, codec and container, destination, progress with time remaining,
// cancel, and "Hide" to keep editing while the export runs. Port of ExportSheet.swift.

const path = require('path');
const os = require('os');
const { ipcRenderer, shell } = require('electron');
const M = require('../core/model');
const { Resolutions, Codecs, Containers, outputSize } = require('../engine/exporter');
const { h } = require('./dom');
const { fileSafeName } = require('./documents');

const SETTINGS_KEY = 'export.settings';

class ExportDialog {
  constructor(app) {
    this.app = app;
    this.exporter = app.exporter;
    this.back = null;
    this.exporter.onChange(() => { if (this.back) this.render(); });
  }

  get isOpen() { return !!this.back; }

  settings() {
    try {
      const s = JSON.parse(localStorage.getItem(SETTINGS_KEY) || 'null');
      if (s && Resolutions[s.resolution] && Codecs[s.codec] && Containers[s.container]) return s;
    } catch (e) { console.error('EditRush: stored export settings are invalid', e); }
    return { resolution: 'p1080', codec: 'h264', container: 'mp4' };
  }

  saveSettings(s) { localStorage.setItem(SETTINGS_KEY, JSON.stringify(s)); }

  open() {
    if (this.back) return;
    this.back = h('div.modal-back');
    this.modal = h('div.modal');
    this.back.appendChild(this.modal);
    document.body.appendChild(this.back);
    this.render();
  }

  close() {
    if (!this.back) return;
    this.back.remove();
    this.back = null;
    if (!this.exporter.isExporting && this.exporter.state !== 'idle') this.exporter.reset();
  }

  render() {
    const ex = this.exporter;
    const project = this.app.store.project;
    const s = this.settings();
    const m = this.modal;
    m.replaceChildren();
    if (ex.isExporting) {
      const pct = Math.floor(ex.progress * 100);
      const remaining = ex.remaining === null ? 'Estimating time remaining...' : `About ${formatRemaining(ex.remaining)} remaining`;
      m.append(h('h2', 'Exporting...'), h('div.insp-facts', path.basename(ex.outputPath)),
        h('div.progress', h('div', { style: { width: `${pct}%` } })),
        h('div.info-row', h('span', `${pct}%`), h('span', ex.cancelled ? 'Stopping...' : remaining)),
        h('div.actions',
          h('button.btn', { title: 'Keep editing; the toolbar Export button shows progress', onclick: () => this.close() }, 'Hide'),
          h('button.btn', { disabled: ex.cancelled, onclick: () => ex.cancel() }, 'Cancel Export')));
      return;
    }
    if (ex.state === 'finished') {
      m.append(h('h2', 'Export complete'), h('div.insp-facts', { style: { whiteSpace: 'normal' } }, ex.outputPath),
        h('div.actions',
          h('button.btn', { onclick: () => shell.showItemInFolder(ex.outputPath) }, 'Show in Explorer'),
          h('button.btn.primary', { onclick: () => this.close() }, 'Done')));
      return;
    }
    if (ex.state === 'failed' || ex.state === 'cancelled') {
      m.append(h('h2', ex.state === 'failed' ? 'Export failed' : 'Export cancelled'),
        h('div.hint', { style: { padding: 0, whiteSpace: 'pre-wrap', userSelect: 'text' } }, ex.state === 'failed' ? ex.message : 'No file was written.'),
        h('div.actions', h('button.btn', { onclick: () => { ex.reset(); this.render(); } }, 'Back'), h('button.btn.primary', { onclick: () => this.close() }, 'Close')));
      return;
    }
    const select = (options, value, onchange) => h('select.select', { onchange: e => onchange(e.target.value) },
      ...Object.entries(options).map(([k, label]) => h('option', { value: k, selected: k === value }, label)));
    const update = change => { const n = { ...s, ...change }; this.saveSettings(n); this.render(); };
    const size = outputSize(s, project.canvas);
    const duration = M.projectDuration(project);
    m.append(h('h2', 'Export Video'),
      h('div.row', h('label', 'Resolution'), select(Resolutions, s.resolution, v => update({ resolution: v }))),
      h('div.row', h('label', 'Codec'), select(Codecs, s.codec, v => update({ codec: v }))),
      h('div.row', h('label', 'Format'), select(Containers, s.container, v => update({ container: v }))),
      h('div.info-row', h('span', 'Output'), h('span', `${size.width}x${size.height}, ${project.canvas.frameRate} fps, ${duration.toFixed(1)} s`)),
      h('div.actions',
        h('button.btn', { onclick: () => this.close() }, 'Cancel'),
        h('button.btn.primary', { disabled: duration <= 0, onclick: () => this.chooseAndExport(s) }, 'Export...')));
  }

  async chooseAndExport(s) {
    const store = this.app.store;
    const ext = s.container === 'mp4' ? 'mp4' : 'mov';
    const dir = store.projectPath ? path.dirname(store.projectPath) : path.join(os.homedir(), 'Videos');
    const r = await ipcRenderer.invoke('dialog-save', {
      title: 'Export Video', defaultPath: path.join(dir, `${fileSafeName(store.project.name)}.${ext}`),
      filters: [{ name: Containers[s.container], extensions: [ext] }],
    });
    if (r.canceled || !r.filePath) return;
    let file = r.filePath;
    if (path.extname(file).toLowerCase() !== `.${ext}`) file += `.${ext}`;
    this.exporter.export(M.clone(store.project), file, s);
    this.render();
  }
}

function formatRemaining(sec) {
  if (sec < 60) return `${Math.max(1, Math.round(sec))} s`;
  const m = Math.floor(sec / 60), r = Math.round(sec % 60);
  return `${m} min ${r} s`;
}

module.exports = { ExportDialog };
