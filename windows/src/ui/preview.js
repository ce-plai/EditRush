'use strict';
// Preview: the canvas fitted in a dark stage, direct manipulation of the selected clip (move,
// corner scale, rotate with snapping guides), drops, and the transport bar.
// Port of PreviewView.swift, PreviewGeometry.swift, PreviewTransformOverlay.swift and
// PreviewTransportBar.swift.

const M = require('../core/model');
const compositor = require('../engine/compositor');
const { h, icon } = require('./dom');
const fmt = require('./format');
const { mediaIDFromDrag } = require('./mediabin');
const { droppedPathsOf } = require('./drop');

const INSET = 16;
const HANDLE_HIT = 9, ROTATE_HIT = 11, SNAP = 6, ROTATE_DISTANCE = 22;
const GUIDE = '#ff52c7';
const ACCENT = '#4d8fff';

class Preview {
  constructor(app, frameCanvas) {
    this.app = app;
    this.store = app.store;
    this.frame = frameCanvas;
    this.overlay = h('canvas.overlay');
    this.error = h('div.preview-error');
    this.emptyState = h('div.bin-empty', { style: { position: 'absolute', inset: '24px', border: '1.5px dashed rgba(255,255,255,0.16)', borderRadius: '14px' } },
      icon('import', 38), h('div', { style: { fontSize: '15px', fontWeight: 600, color: 'var(--text)' } }, 'Drop videos, photos and music here'),
      h('div', 'MP4, MOV, MP3, WAV, OGG, PNG and JPG - or import from your PC'),
      h('button.btn.primary', { onclick: async () => this.place(await app.documents.importWithDialog()) }, 'Import Media...'));
    this.stage = h('div.preview-stage', this.frame, this.overlay, this.emptyState, this.error);
    this.tc = h('div.tc');
    this.playBtn = h('button.round-btn.big', { title: 'Play / Pause (Space)', onclick: () => app.command('togglePlay') });
    const transport = h('div.transport', this.tc,
      h('button.round-btn', { title: 'Go to Start (Home)', onclick: () => app.command('goToStart') }, icon('start')),
      h('button.round-btn', { title: 'Previous Frame (Left)', onclick: () => app.command('prevFrame') }, icon('prev')),
      this.playBtn,
      h('button.round-btn', { title: 'Next Frame (Right)', onclick: () => app.command('nextFrame') }, icon('next')),
      h('button.round-btn', { title: 'Go to End (End)', onclick: () => app.command('goToEnd') }, icon('end')));
    this.root = h('div.panel.preview', this.stage, transport);

    this.session = null;
    this.hoverID = null;
    this.guides = { x: null, y: null };
    this.readout = null;
    this.installPointer();
    this.installDrops();
    new ResizeObserver(() => this.layout()).observe(this.stage);
    this.store.on('project', () => { this.layout(); this.drawOverlay(); });
    this.store.on('ui', () => { this.updateTransport(); this.drawOverlay(); });
    app.playback.onState(() => this.updateTransport());
    this.layout();
    this.updateTransport();
  }

  // MARK: Layout

  /// Where the canvas is drawn inside the stage, in CSS pixels.
  mapping() {
    const c = this.store.project.canvas;
    const W = this.stage.clientWidth, H = this.stage.clientHeight;
    const aw = Math.max(1, W - 2 * INSET), ah = Math.max(1, H - 2 * INSET);
    const k = Math.min(aw / c.width, ah / c.height);
    const w = Math.round(c.width * k), hgt = Math.round(c.height * k);
    return { x: Math.round(INSET + (aw - w) / 2), y: Math.round(INSET + (ah - hgt) / 2), width: w, height: hgt, scale: w / c.width };
  }

  layout() {
    const m = this.mapping();
    Object.assign(this.frame.style, { left: `${m.x}px`, top: `${m.y}px`, width: `${m.width}px`, height: `${m.height}px` });
    const dpr = window.devicePixelRatio || 1;
    const W = Math.round(this.stage.clientWidth * dpr), H = Math.round(this.stage.clientHeight * dpr);
    if (this.overlay.width !== W || this.overlay.height !== H) { this.overlay.width = W; this.overlay.height = H; }
    const empty = M.projectDuration(this.store.project) <= 0;
    this.emptyState.style.display = empty ? 'flex' : 'none';
    this.frame.style.visibility = empty ? 'hidden' : 'visible';
    this.app.playback.invalidate();
    this.drawOverlay();
  }

  updateTransport() {
    const s = this.store, fps = s.project.canvas.frameRate;
    this.tc.replaceChildren(fmt.timecode(s.playhead, fps), h('span', ` / ${fmt.timecode(M.projectDuration(s.project), fps)}`));
    const playing = this.app.playback.isPlaying;
    if (this.shownPlaying !== playing) { this.shownPlaying = playing; this.playBtn.replaceChildren(icon(playing ? 'pause' : 'play', 18)); }
    const err = this.app.playback.lastError;
    this.error.style.display = err ? 'block' : 'none';
    this.error.textContent = err || '';
  }

  // MARK: Clip frames (CSS pixels in the stage)

  frameOf(clip) {
    const p = this.store.project;
    const layer = { clip, media: clip.mediaID ? M.findMedia(p, clip.mediaID) : null };
    if (!clip.text && (!layer.media || layer.media.kind === 'audio')) return null;
    const content = compositor.contentSize(p, layer);
    if (!content) return null;
    const r = M.clipRect(content, p.canvas, clip.transform, !!clip.text);
    const m = this.mapping();
    return new ClipFrame(m.x + (r.x + r.width / 2) * m.scale, m.y + (r.y + r.height / 2) * m.scale, r.width * m.scale, r.height * m.scale, clip.transform.rotation);
  }

  /// Active visual clips at the playhead, topmost first: [{ clip, track }].
  activeClips() {
    const p = this.store.project;
    const t = this.store.playhead;
    const out = [];
    for (const track of [...p.tracks].reverse()) {
      if (track.kind !== 'video' || track.isHidden) continue;
      for (const clip of track.clips) if (M.clipContains(clip, t) && this.frameOf(clip)) out.push({ clip, track });
    }
    return out;
  }

  /// The single selected clip if it is visual, on a visible video track and active at the playhead.
  editableSelection() {
    const s = this.store;
    if (s.selection.size !== 1) return null;
    const id = [...s.selection][0];
    const l = M.locate(s.project, id);
    if (!l) return null;
    const track = s.project.tracks[l.track], clip = track.clips[l.clip];
    if (track.kind !== 'video' || track.isHidden || !M.clipContains(clip, s.playhead) || !this.frameOf(clip)) return null;
    return { clip, track };
  }

  selectionRegion(p) {
    const sel = this.editableSelection();
    if (!sel) return null;
    const f = this.frameOf(sel.clip);
    if (!sel.track.isLocked) {
      if (dist(p, f.rotationHandle(ROTATE_DISTANCE)) <= ROTATE_HIT) return { ...sel, frame: f, region: 'rotate' };
      const small = Math.min(f.w, f.h) < HANDLE_HIT * 3;
      if (!(small && f.contains(p))) {
        const i = f.corners().findIndex(c => dist(p, c) <= HANDLE_HIT);
        if (i >= 0) return { ...sel, frame: f, region: 'corner', corner: i };
      }
    }
    return f.contains(p) ? { ...sel, frame: f, region: 'body' } : null;
  }

  topmostClip(p, preferText) {
    const m = this.mapping();
    if (p.x < m.x || p.y < m.y || p.x > m.x + m.width || p.y > m.y + m.height) return null;
    const hits = [];
    for (const a of this.activeClips()) {
      const f = this.frameOf(a.clip);
      if (!f.contains(p)) continue;
      if (!preferText) return { ...a, frame: f };
      hits.push({ ...a, frame: f });
    }
    return hits.find(x => x.clip.text) || hits[0] || null;
  }

  // MARK: Pointer

  installPointer() {
    const pos = e => { const r = this.stage.getBoundingClientRect(); return { x: e.clientX - r.left, y: e.clientY - r.top }; };
    this.overlay.addEventListener('mousedown', e => {
      if (e.button !== 0) return;
      e.preventDefault();
      if (document.activeElement) document.activeElement.blur();
      this.begin(pos(e), e.detail >= 2);
      const move = ev => this.update(pos(ev), ev);
      const up = ev => {
        window.removeEventListener('mousemove', move);
        window.removeEventListener('mouseup', up);
        this.finish(pos(ev));
      };
      window.addEventListener('mousemove', move);
      window.addEventListener('mouseup', up);
    });
    this.overlay.addEventListener('mousemove', e => { if (!this.session) this.hover(pos(e)); });
    this.overlay.addEventListener('mouseleave', () => { if (!this.session) { this.hoverID = null; this.overlay.style.cursor = ''; this.drawOverlay(); } });
  }

  hover(p) {
    const hit = this.selectionRegion(p);
    let cursor = '';
    let hoverID = null;
    if (hit) {
      if (!hit.track.isLocked) cursor = hit.region === 'rotate' ? 'alias' : hit.region === 'corner' ? resizeCursor([-135, -45, 45, 135][hit.corner] + hit.frame.rot) : 'grab';
    } else {
      const top = this.topmostClip(p, false);
      hoverID = top ? top.clip.id : null;
    }
    this.overlay.style.cursor = cursor;
    if (hoverID !== this.hoverID) { this.hoverID = hoverID; this.drawOverlay(); }
  }

  begin(p, doubleClick) {
    if (this.session && this.session.didEdit) this.store.endCoalescing();
    this.hoverID = null;
    const hit = this.selectionRegion(p);
    if (doubleClick) {
      const t = this.topmostClip(p, true);
      if (t && t.clip.text) {
        if (!hit || t.clip.id !== hit.clip.id) this.startMove(t, p);
        else this.session = { mode: 'move', clipID: t.clip.id, start: p, startXf: M.clone(t.clip.transform), frame: t.frame, locked: t.track.isLocked };
        this.app.inspector.requestTextEditing(t.clip.id);
        return;
      }
    }
    if (hit) {
      const mode = hit.region === 'rotate' ? 'rotate' : hit.region === 'corner' ? 'scale' : 'move';
      this.session = { mode: hit.track.isLocked ? 'idle' : mode, clipID: hit.clip.id, start: p, startXf: M.clone(hit.clip.transform), frame: hit.frame };
      if (mode === 'move' && !hit.track.isLocked) this.overlay.style.cursor = 'grabbing';
      return;
    }
    const top = this.topmostClip(p, false);
    if (top) { this.startMove(top, p); return; }
    if (this.store.selection.size) this.store.setSelection([]);
    this.session = { mode: 'idle', clipID: null, start: p };
  }

  startMove(hit, p) {
    this.store.setSelection([hit.clip.id]);
    this.session = { mode: hit.track.isLocked ? 'idle' : 'move', clipID: hit.clip.id, start: p, startXf: M.clone(hit.clip.transform), frame: hit.frame };
    if (!hit.track.isLocked) this.overlay.style.cursor = 'grabbing';
  }

  update(p, e) {
    const s = this.session;
    if (!s || !s.clipID || s.mode === 'idle') return;
    if (!s.moved) { if (dist(p, s.start) < 2) return; s.moved = true; }
    const snapping = this.store.snappingEnabled && !e.ctrlKey;
    const start = s.startXf;
    const key = `preview-transform-${s.clipID}`;
    const m = this.mapping();
    if (s.mode === 'move') {
      let dx = p.x - s.start.x, dy = p.y - s.start.y;
      let lockX = false, lockY = false;
      if (e.shiftKey) { if (Math.abs(dx) >= Math.abs(dy)) { dy = 0; lockY = true; } else { dx = 0; lockX = true; } }
      const guides = { x: null, y: null };
      if (snapping) {
        const b = s.frame.bounds();
        const bx = [b.x + dx, b.x + b.w / 2 + dx, b.x + b.w + dx], by = [b.y + dy, b.y + b.h / 2 + dy, b.y + b.h + dy];
        const sx = !lockX && snap(bx, [m.x, m.x + m.width / 2, m.x + m.width]);
        if (sx) { dx += sx.adjust; guides.x = sx.target; }
        const sy = !lockY && snap(by, [m.y, m.y + m.height / 2, m.y + m.height]);
        if (sy) { dy += sy.adjust; guides.y = sy.target; }
      }
      this.guides = guides;
      this.readout = null;
      const ox = start.offsetX + dx / m.width, oy = start.offsetY + dy / m.height;
      this.store.updateClip(s.clipID, 'Transform', c => { c.transform.offsetX = ox; c.transform.offsetY = oy; }, { coalesce: key });
    } else if (s.mode === 'scale') {
      const c = { x: s.frame.cx, y: s.frame.cy };
      const d0 = dist(s.start, c), d1 = dist(p, c);
      if (d0 <= 1) return;
      let k = Math.min(20, Math.max(0.02, start.scale * d1 / d0));
      if (snapping && start.scale > 0) {
        const unitHalfDiagonal = Math.hypot(s.frame.w, s.frame.h) / 2 / start.scale;
        if (Math.abs(k - 1) * unitHalfDiagonal < SNAP) k = 1;
      }
      this.readout = { text: `${Math.round(k * 100)}%`, at: p };
      this.store.updateClip(s.clipID, 'Transform', cl => { cl.transform.scale = k; }, { coalesce: key });
    } else if (s.mode === 'rotate') {
      const c = { x: s.frame.cx, y: s.frame.cy };
      const a0 = Math.atan2(s.start.y - c.y, s.start.x - c.x), a1 = Math.atan2(p.y - c.y, p.x - c.x);
      let r = start.rotation + (a1 - a0) * 180 / Math.PI;
      if (e.shiftKey) r = Math.round(r / 15) * 15;
      else if (snapping) { const right = Math.round(r / 90) * 90; if (Math.abs(r - right) < 3) r = right; }
      r = normalizedDegrees(r);
      this.readout = { text: `${Math.round(r)}deg`, at: p };
      this.store.updateClip(s.clipID, 'Transform', cl => { cl.transform.rotation = r; }, { coalesce: key });
    }
    s.didEdit = true;
    this.drawOverlay();
  }

  finish(p) {
    if (this.session && this.session.didEdit) this.store.endCoalescing();
    this.session = null;
    this.guides = { x: null, y: null };
    this.readout = null;
    this.hover(p);
    this.drawOverlay();
  }

  // MARK: Overlay drawing

  drawOverlay() {
    const ctx = this.overlay.getContext('2d');
    const dpr = window.devicePixelRatio || 1;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, this.overlay.width, this.overlay.height);
    if (M.projectDuration(this.store.project) <= 0) return;
    ctx.scale(dpr, dpr);
    const m = this.mapping();
    ctx.lineWidth = 1;
    ctx.strokeStyle = GUIDE;
    if (this.guides.x !== null) { ctx.beginPath(); ctx.moveTo(this.guides.x + 0.5, m.y); ctx.lineTo(this.guides.x + 0.5, m.y + m.height); ctx.stroke(); }
    if (this.guides.y !== null) { ctx.beginPath(); ctx.moveTo(m.x, this.guides.y + 0.5); ctx.lineTo(m.x + m.width, this.guides.y + 0.5); ctx.stroke(); }

    const sel = this.editableSelection();
    if (this.hoverID && (!sel || sel.clip.id !== this.hoverID)) {
      const clip = this.store.clip(this.hoverID);
      const track = clip && M.trackContaining(this.store.project, clip.id);
      if (clip && track && !track.isHidden && M.clipContains(clip, this.store.playhead)) {
        ctx.strokeStyle = 'rgba(77,143,255,0.85)';
        this.framePath(ctx, this.frameOf(clip));
        ctx.stroke();
      }
    }
    if (sel) {
      const f = this.frameOf(sel.clip);
      ctx.lineWidth = 3; ctx.strokeStyle = 'rgba(0,0,0,0.35)';
      this.framePath(ctx, f); ctx.stroke();
      if (sel.track.isLocked) {
        ctx.setLineDash([4, 3]); ctx.lineWidth = 1; ctx.strokeStyle = 'rgba(255,255,255,0.8)';
        this.framePath(ctx, f); ctx.stroke(); ctx.setLineDash([]);
      } else {
        ctx.lineWidth = 1.5; ctx.strokeStyle = ACCENT;
        this.framePath(ctx, f); ctx.stroke();
        const top = f.point(0, -f.h / 2), knob = f.rotationHandle(ROTATE_DISTANCE);
        ctx.beginPath(); ctx.moveTo(top.x, top.y); ctx.lineTo(knob.x, knob.y); ctx.stroke();
        this.knob(ctx, knob, 5.5);
        for (const c of f.corners()) this.knob(ctx, c, 5);
      }
    }
    if (this.readout) {
      ctx.font = '600 11px "Segoe UI"';
      const w = ctx.measureText(this.readout.text).width + 14, hh = 20;
      const x = this.readout.at.x + 14, y = this.readout.at.y + 16;
      ctx.fillStyle = 'rgba(0,0,0,0.72)';
      ctx.beginPath(); ctx.roundRect(x, y, w, hh, hh / 2); ctx.fill();
      ctx.fillStyle = 'white'; ctx.textBaseline = 'middle'; ctx.textAlign = 'center';
      ctx.fillText(this.readout.text, x + w / 2, y + hh / 2);
    }
  }

  framePath(ctx, f) {
    const cs = f.corners();
    ctx.beginPath();
    ctx.moveTo(cs[0].x, cs[0].y);
    for (const c of cs.slice(1)) ctx.lineTo(c.x, c.y);
    ctx.closePath();
  }

  knob(ctx, p, r) {
    ctx.save();
    ctx.shadowColor = 'rgba(0,0,0,0.45)'; ctx.shadowBlur = 4; ctx.shadowOffsetY = 1;
    ctx.fillStyle = 'white';
    ctx.beginPath(); ctx.arc(p.x, p.y, r, 0, Math.PI * 2); ctx.fill();
    ctx.restore();
    ctx.lineWidth = 1.5; ctx.strokeStyle = ACCENT;
    ctx.beginPath(); ctx.arc(p.x, p.y, r, 0, Math.PI * 2); ctx.stroke();
  }

  // MARK: Drops: Explorer files are imported, bin items used directly; all land at the playhead.

  installDrops() {
    this.stage.addEventListener('dragover', e => { e.preventDefault(); e.dataTransfer.dropEffect = 'copy'; });
    this.stage.addEventListener('drop', async e => {
      e.preventDefault();
      e.stopPropagation();
      this.app.hideDropHighlight();
      const key = `preview-drop-${M.uuid()}`;
      const items = [];
      const paths = droppedPathsOf(e);
      const projects = paths.filter(f => f.toLowerCase().endsWith(`.${M.FILE_EXTENSION}`));
      if (projects.length) { this.app.documents.openFiles(projects); return; }
      const id = mediaIDFromDrag(e);
      if (paths.length) items.push(...await this.app.documents.importPaths(paths, key));
      if (id && this.store.media(id)) items.push(this.store.media(id));
      this.place(items, key);
    });
  }

  /// Adds `items` at the playhead as one undo step, visual and audio media each chaining.
  place(items, key = `preview-drop-${M.uuid()}`) {
    let visual = this.store.playhead, sound = this.store.playhead;
    const added = [];
    for (const item of items) {
      const isAudio = item.kind === 'audio';
      const id = this.store.addClip(item.id, { time: isAudio ? sound : visual, coalesce: key });
      const clip = id && this.store.clip(id);
      if (!clip) continue;
      added.push(id);
      if (isAudio) sound = M.clipEnd(clip); else visual = M.clipEnd(clip);
    }
    this.store.endCoalescing();
    if (added.length > 1) this.store.setSelection(added);
  }
}

/// A clip's on-screen frame: unrotated size about a centre, rotated clockwise by `rot` degrees.
class ClipFrame {
  constructor(cx, cy, w, h, rot) { Object.assign(this, { cx, cy, w, h, rot }); }
  point(lx, ly) {
    const a = this.rot * Math.PI / 180, c = Math.cos(a), s = Math.sin(a);
    return { x: this.cx + lx * c - ly * s, y: this.cy + lx * s + ly * c };
  }
  local(p) {
    const a = -this.rot * Math.PI / 180, c = Math.cos(a), s = Math.sin(a);
    const dx = p.x - this.cx, dy = p.y - this.cy;
    return { x: dx * c - dy * s, y: dx * s + dy * c };
  }
  corners() { const w = this.w / 2, h = this.h / 2; return [[-w, -h], [w, -h], [w, h], [-w, h]].map(([x, y]) => this.point(x, y)); }
  bounds() {
    const cs = this.corners(), xs = cs.map(c => c.x), ys = cs.map(c => c.y);
    return { x: Math.min(...xs), y: Math.min(...ys), w: Math.max(...xs) - Math.min(...xs), h: Math.max(...ys) - Math.min(...ys) };
  }
  contains(p) { const l = this.local(p); return Math.abs(l.x) <= this.w / 2 && Math.abs(l.y) <= this.h / 2; }
  rotationHandle(d) { return this.point(0, -this.h / 2 - d); }
}

const dist = (a, b) => Math.hypot(a.x - b.x, a.y - b.y);

function snap(candidates, targets) {
  let best = null;
  for (const t of targets) for (const c of candidates) {
    const d = t - c;
    if (Math.abs(d) <= SNAP && (!best || Math.abs(d) < Math.abs(best.adjust))) best = { adjust: d, target: t };
  }
  return best;
}

function normalizedDegrees(r) {
  let v = r % 360;
  if (v > 180) v -= 360;
  if (v <= -180) v += 360;
  return v === 0 ? 0 : v;
}

function resizeCursor(angle) {
  let a = angle % 360;
  if (a < 0) a += 360;
  return ['ew-resize', 'nwse-resize', 'ns-resize', 'nesw-resize'][Math.floor((a + 22.5) / 45) % 4];
}

module.exports = { Preview };
