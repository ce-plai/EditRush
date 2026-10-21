'use strict';
// Media bin: imported media as tiles with poster frames / waveforms, a kind filter, missing-file
// detection and relinking. Port of MediaBinView.swift, MediaBinTile.swift and MediaBinActions.swift.

const path = require('path');
const { ipcRenderer, shell } = require('electron');
const M = require('../core/model');
const R = require('../core/rules');
const { mediaPath, mediaFileExists } = require('../core/store');
const importer = require('../media/importer');
const { h, icon, clear, contextMenu } = require('./dom');
const fmt = require('./format');

const DRAG_PREFIX = 'editrush-media:';
const TINTS = { video: '#3d6bcc', audio: '#339e73', image: '#805ccc' };
const KIND_ICON = { video: 'film', audio: 'wave', image: 'photo' };

class MediaBin {
  constructor(app) {
    this.app = app;
    this.store = app.store;
    this.filter = 'all';
    this.missing = new Map();
    this.segs = {};
    const filterBar = h('div.bin-filter', ...['all', 'video', 'audio', 'image'].map(k => {
      this.segs[k] = h('div.seg', { onclick: () => { this.filter = k; this.render(); } },
        { all: 'All', video: 'Video', audio: 'Audio', image: 'Images' }[k]);
      return this.segs[k];
    }));
    this.grid = h('div.bin-grid', { onmousedown: e => { if (e.target === this.grid) this.store.setSelectedMedia(null); } });
    this.empty = h('div.bin-empty', icon('import', 36), h('div', 'Drag video, audio and image files here, or'),
      h('button.btn.primary', { onclick: () => app.command('importMedia') }, 'Import Media...'));
    this.root = h('div.panel.bin',
      h('div.panel-header', 'Media', h('div', { style: { flex: 1 } }),
        h('button.tool', { title: 'Import media (Ctrl+I)', onclick: () => app.command('importMedia') }, icon('plus'))),
      filterBar, this.grid, this.empty);
    this.tiles = new Map();
    this.store.on('project', () => this.render());
    this.store.on('ui', () => this.updateSelection());
    app.cache.onChange(() => this.refreshThumbs());
    window.addEventListener('focus', () => this.render());
    this.render();
  }

  render() {
    const p = this.store.project;
    for (const [k, seg] of Object.entries(this.segs)) seg.classList.toggle('on', k === this.filter);
    const items = p.media.filter(m => this.filter === 'all' || m.kind === this.filter);
    this.empty.style.display = p.media.length ? 'none' : 'flex';
    this.grid.style.display = p.media.length ? 'grid' : 'none';
    const keep = new Set();
    clear(this.grid);
    for (const m of items) {
      const key = `${m.id}|${m.url}`;
      keep.add(key);
      let tile = this.tiles.get(key);
      if (!tile) { tile = this.makeTile(m); this.tiles.set(key, tile); }
      tile.update(m);
      this.grid.appendChild(tile.el);
    }
    for (const k of [...this.tiles.keys()]) if (!keep.has(k)) this.tiles.delete(k);
    if (p.media.length && !items.length) this.grid.appendChild(h('div.hint', { style: { gridColumn: '1 / -1' } }, 'No media of this kind.'));
    this.updateSelection();
  }

  updateSelection() {
    for (const t of this.tiles.values()) t.el.classList.toggle('selected', t.media.id === this.store.selectedMediaID);
  }

  refreshThumbs() { for (const t of this.tiles.values()) t.drawThumb(); }

  usageCount(id) { return this.store.project.tracks.reduce((n, t) => n + t.clips.filter(c => c.mediaID === id).length, 0); }

  makeTile(media) {
    const thumbCanvas = h('canvas', { width: 240, height: 132 });
    const dur = h('div.dur');
    const name = h('div.name');
    const missingLabel = h('div.missing-label', 'Missing');
    const thumb = h('div.thumb', thumbCanvas, h('div.kind', icon(KIND_ICON[media.kind], 12)), dur, missingLabel);
    const add = h('button.add', { title: 'Add to the timeline after the playhead', onclick: e => { e.stopPropagation(); this.addToTimeline(tile.media); } }, icon('plus', 14));
    const el = h('div.tile', {
      draggable: true,
      onmousedown: () => { this.store.setSelectedMedia(tile.media.id); },
      ondblclick: () => this.addToTimeline(tile.media),
      ondragstart: e => {
        if (tile.isMissing) { e.preventDefault(); return; }
        e.dataTransfer.setData('text/plain', DRAG_PREFIX + tile.media.id);
        e.dataTransfer.effectAllowed = 'copy';
        this.app.draggingMedia = tile.media.id;
      },
      ondragend: () => { this.app.draggingMedia = null; },
      oncontextmenu: e => { e.preventDefault(); this.showMenu(tile, e.clientX, e.clientY); },
    }, thumb, add, name);
    const tile = {
      el, media, isMissing: false,
      update: m => {
        tile.media = m;
        tile.isMissing = !mediaFileExists(m);
        el.classList.toggle('missing', tile.isMissing);
        missingLabel.style.display = tile.isMissing ? '' : 'none';
        name.textContent = m.name;
        dur.textContent = m.kind === 'image' ? '' : fmt.shortDuration(m.duration);
        dur.style.display = m.kind === 'image' ? 'none' : '';
        const facts = m.kind === 'video' ? `${m.pixelWidth}x${m.pixelHeight}, ${Math.round(m.frameRate)} fps, ${fmt.shortDuration(m.duration)}`
          : m.kind === 'image' ? `${m.pixelWidth}x${m.pixelHeight} image` : `Audio, ${fmt.shortDuration(m.duration)}`;
        el.title = `${m.name}\n${facts}${tile.isMissing ? '\nFile is missing - right-click to locate it' : ''}`;
        tile.drawThumb();
      },
      drawThumb: () => {
        const ctx = thumbCanvas.getContext('2d');
        const W = thumbCanvas.width, H = thumbCanvas.height;
        ctx.fillStyle = '#111';
        ctx.fillRect(0, 0, W, H);
        if (tile.isMissing) return;
        const m = tile.media;
        if (m.kind === 'audio') {
          const wf = this.app.cache.get('waveform', m);
          ctx.fillStyle = TINTS.audio;
          if (!wf) return;
          const n = wf.peaks.length;
          for (let x = 0; x < W; x++) {
            const a = Math.floor(x / W * n), b = Math.max(a + 1, Math.floor((x + 1) / W * n));
            let peak = 0;
            for (let i = a; i < b && i < n; i++) peak = Math.max(peak, wf.peaks[i]);
            const hh = Math.max(1, peak * H * 0.85);
            ctx.fillRect(x, (H - hh) / 2, 1, hh);
          }
          return;
        }
        const img = this.app.cache.get('poster', m);
        if (!img) return;
        const iw = img.naturalWidth || img.width, ih = img.naturalHeight || img.height;
        const s = Math.max(W / iw, H / ih);
        ctx.drawImage(img, (W - iw * s) / 2, (H - ih * s) / 2, iw * s, ih * s);
      },
    };
    return tile;
  }

  showMenu(tile, x, y) {
    const m = tile.media;
    this.store.setSelectedMedia(m.id);
    const n = this.usageCount(m.id);
    contextMenu(x, y, [
      { label: 'Add to Timeline', enabled: !tile.isMissing, action: () => this.addToTimeline(m) },
      { label: 'Show in Explorer', enabled: !tile.isMissing, action: () => shell.showItemInFolder(mediaPath(m)) },
      ...(tile.isMissing ? [{ label: 'Locate File...', action: () => this.relink(m) }] : []),
      '-',
      { label: n > 0 ? `Remove from Project (and ${n} clip${n === 1 ? '' : 's'})` : 'Remove from Project', action: () => this.store.removeMedia(m.id) },
    ]);
  }

  async relink(media) {
    const r = await ipcRenderer.invoke('dialog-open', {
      title: `Locate "${path.basename(mediaPath(media))}"`,
      filters: [{ name: 'Media', extensions: [...importer.supportedExtensions] }],
      properties: ['openFile'],
    });
    if (r.canceled || !r.filePaths.length) return;
    const file = r.filePaths[0];
    try {
      const probed = await importer.probe(file);
      if (probed.kind !== media.kind) {
        this.store.setStatus(`Couldn't relink: "${path.basename(file)}" is not ${media.kind === 'image' ? 'an image' : `a ${media.kind} file`}`);
        return;
      }
      if (probed.kind === 'image') {
        const img = await this.app.cache.ready('still', probed);
        if (!img) throw new Error("the image couldn't be read");
        probed.pixelWidth = img.naturalWidth; probed.pixelHeight = img.naturalHeight;
      }
      this.app.cache.forget(media.url);
      this.store.relinkMedia(media.id, probed);
      this.store.setStatus(`Relinked "${media.name}"`);
    } catch (e) {
      this.store.setStatus(`Couldn't relink: ${e.message}`);
    }
  }

  /// Appends media one after another after the playhead as one undo step (Rush-style sequence
  /// building); the playhead moves to the end of the last added clip.
  addToTimeline(media) {
    if (!mediaFileExists(media)) {
      this.store.setStatus(`"${path.basename(mediaPath(media))}" is missing - right-click it to locate the file.`);
      return;
    }
    if (document.activeElement) document.activeElement.blur();
    this.store.setSelectedMedia(media.id);
    appendMedia(this.app, [media]);
  }
}

/// Timeline length `addClip` gives a new clip of `media` (images: 5 s).
function clipDuration(media, project) {
  const canvas = project.canvas;
  if (media.kind === 'image' || !(media.duration > 0)) return 5;
  const fps = Math.max(1, canvas.frameRate);
  return Math.max(M.frameDuration(canvas), Math.floor(media.duration * fps + 1e-6) / fps);
}

/// Earliest start >= `time` where [start, start + duration) overlaps no clip on `track`.
function firstFreeStart(track, duration, time) {
  let start = Math.max(0, time);
  for (const c of [...track.clips].sort((a, b) => a.start - b.start)) {
    if (!(M.clipEnd(c) > start + 1e-6)) continue;
    if (c.start >= start + duration - 1e-6) break;
    start = M.clipEnd(c);
  }
  return start;
}

function appendMedia(app, items) {
  const store = app.store;
  if (!items.length) return;
  const key = `bin-add-${M.uuid()}`;
  const added = [];
  let time = store.playhead;
  for (const media of items) {
    const kind = media.kind === 'audio' ? 'audio' : 'video';
    const track = store.project.tracks.find(t => t.kind === kind && R.allowsAutomaticPlacement(t));
    const start = track ? firstFreeStart(track, clipDuration(media, store.project), time) : time;
    const id = store.addClip(media.id, { trackID: track ? track.id : null, time: start, coalesce: key });
    const clip = id && store.clip(id);
    if (!clip) continue;
    added.push(id);
    time = M.clipEnd(clip);
  }
  store.endCoalescing();
  if (!added.length) return;
  store.setSelection(added);
  app.playback.seek(time);
  app.timeline.revealPlayhead();
}

function mediaIDFromDrag(e) {
  const s = e.dataTransfer.getData('text/plain');
  return s && s.startsWith(DRAG_PREFIX) ? s.slice(DRAG_PREFIX.length) : null;
}

module.exports = { MediaBin, DRAG_PREFIX, mediaIDFromDrag, appendMedia };
