'use strict';
// Timeline: toolbar, track headers and a canvas with the ruler, clips (filmstrips, waveforms,
// fades), playhead, snapping, move / trim / fade / marquee gestures, scrolling, zoom and drops.
// Port of the Sources/EditRush/UI/Timeline views.

const M = require('../core/model');
const R = require('../core/rules');
const { mediaFileExists, ZOOM_MIN, ZOOM_MAX } = require('../core/store');
const { h, icon, contextMenu } = require('./dom');
const fmt = require('./format');
const { mediaIDFromDrag } = require('./mediabin');
const { droppedPathsOf } = require('./drop');

const VIDEO_H = 64, AUDIO_H = 48, RULER_H = 26;
const TOP_PAD = 4, GROUP_GAP = 8, BOTTOM_PAD = 56, LEAD = 10, INSET = 3, TRIM_W = 7, SNAP_PX = 8, SCROLLER = 9;
const DROP_DEFAULT = 5;
const COLORS = {
  video: { body: '#2a4a8c', border: 'rgba(130,170,255,0.55)' },
  image: { body: '#58408c', border: 'rgba(190,160,255,0.55)' },
  audio: { body: '#1f5e45', fill: '#2c7a5a', border: 'rgba(120,230,180,0.5)', wave: 'rgba(170,255,215,0.85)' },
  text: { body: '#a35f25', fill: '#b8692a', border: 'rgba(255,200,140,0.6)' },
};

/// Rows: video tracks top to bottom in reverse array order (top row = top layer), then audio.
function layoutRows(project) {
  const rows = [];
  let y = TOP_PAD;
  const video = project.tracks.filter(t => t.kind === 'video').reverse();
  const audio = project.tracks.filter(t => t.kind === 'audio');
  const row = (t, hgt) => { rows.push({ trackID: t.id, kind: t.kind, name: M.displayName(project, t.id), y, height: hgt, track: t }); y += hgt; };
  for (const t of video) row(t, VIDEO_H);
  if (video.length && audio.length) y += GROUP_GAP;
  for (const t of audio) row(t, AUDIO_H);
  return { rows, tracksHeight: y, contentHeight: y + BOTTOM_PAD };
}

class Timeline {
  constructor(app) {
    this.app = app;
    this.store = app.store;
    this.scrollX = 0;
    this.scrollY = 0;
    this.appliedPPS = this.store.pixelsPerSecond;
    this.drag = null;
    this.hover = null;
    this.snapGuide = null;
    this.dropPreview = null;
    this.layout = layoutRows(this.store.project);

    this.canvas = h('canvas');
    this.wrap = h('div.tl-canvas-wrap', this.canvas);
    this.headers = h('div.tl-headers', h('div.corner'));
    this.headerRows = h('div', { style: { position: 'absolute', left: 0, right: 0, top: `${RULER_H}px` } });
    this.headers.append(this.headerRows);
    this.toolbar = this.buildToolbar();
    this.root = h('div.timeline', this.toolbar, h('div.tl-body', this.headers, this.wrap));

    this.installMouse();
    this.installDrops();
    new ResizeObserver(() => this.resized()).observe(this.wrap);
    this.store.on('project', () => { this.layout = layoutRows(this.store.project); this.renderHeaders(); this.updateToolbar(); this.invalidate(); });
    this.store.on('ui', () => { this.reconcileZoom(); this.updateToolbar(); if (this.app.playback && this.app.playback.isPlaying) this.follow(); this.invalidate(); });
    app.cache.onChange(() => this.invalidate());
    this.renderHeaders();
    this.updateToolbar();
    const loop = () => { requestAnimationFrame(loop); if (this.dirty) { this.dirty = false; this.draw(); } };
    requestAnimationFrame(loop);
  }

  invalidate() { this.dirty = true; }

  // MARK: Geometry

  get pps() { return this.store.pixelsPerSecond; }
  get width() { return this.wrap.clientWidth; }
  get height() { return this.wrap.clientHeight; }
  x(t) { return LEAD + t * this.pps - this.scrollX; }
  rawTime(x) { return (x + this.scrollX - LEAD) / this.pps; }
  time(x) { return Math.max(0, this.rawTime(x)); }
  viewY(cy) { return RULER_H + cy - this.scrollY; }
  contentY(vy) { return vy - RULER_H + this.scrollY; }
  get contentWidth() { return LEAD + (Math.max(M.projectDuration(this.store.project), 5) + 30) * this.pps; }
  get maxScrollX() { return Math.max(0, this.contentWidth - this.width); }
  get trackViewportHeight() { return Math.max(0, this.height - RULER_H); }
  get maxScrollY() { return Math.max(0, this.layout.contentHeight - this.trackViewportHeight); }
  rowAtViewY(y) { if (y < RULER_H) return null; const cy = this.contentY(y); return this.layout.rows.find(r => cy >= r.y && cy < r.y + r.height) || null; }
  clipRect(clip, row) {
    return { x: this.x(clip.start), y: this.viewY(row.y) + INSET, w: Math.max(2, clip.duration * this.pps), h: row.height - 2 * INSET };
  }
  track(id) { return this.store.project.tracks.find(t => t.id === id); }
  contentKind(clip) { if (clip.text) return null; const m = this.store.media(clip.mediaID); return m ? m.kind : null; }

  resized() {
    const dpr = window.devicePixelRatio || 1;
    const W = Math.max(1, this.width), H = Math.max(1, this.height);
    this.canvas.width = Math.round(W * dpr); this.canvas.height = Math.round(H * dpr);
    this.canvas.style.width = `${W}px`; this.canvas.style.height = `${H}px`;
    this.store.timelineViewportWidth = Math.max(100, W - LEAD - 20);
    this.clampScroll();
    this.renderHeaders();
    this.invalidate();
  }

  clampScroll() {
    this.scrollX = Math.min(Math.max(0, this.scrollX), this.maxScrollX);
    this.scrollY = Math.min(Math.max(0, this.scrollY), this.maxScrollY);
  }

  scroll(dx, dy) {
    const ox = this.scrollX, oy = this.scrollY;
    this.scrollX += dx; this.scrollY += dy;
    this.clampScroll();
    if (ox !== this.scrollX || oy !== this.scrollY) { if (oy !== this.scrollY) this.positionHeaders(); this.invalidate(); }
  }

  /// Keeps the playhead (or left edge) fixed when the zoom changes from elsewhere.
  reconcileZoom() {
    const pps = this.store.pixelsPerSecond;
    if (pps === this.appliedPPS) return;
    const old = this.appliedPPS;
    const playheadX = LEAD + this.store.playhead * old - this.scrollX;
    const anchorX = playheadX >= 0 && playheadX <= this.width ? playheadX : 0;
    const anchorT = (anchorX + this.scrollX - LEAD) / old;
    this.appliedPPS = pps;
    this.scrollX = LEAD + anchorT * pps - anchorX;
    this.clampScroll();
  }

  zoomAt(factor, anchorX) {
    this.reconcileZoom();
    const t = this.rawTime(anchorX);
    this.store.zoom(factor);
    this.appliedPPS = this.store.pixelsPerSecond;
    this.scrollX = LEAD + t * this.pps - anchorX;
    this.clampScroll();
    this.invalidate();
  }

  follow() {
    const px = this.x(this.store.playhead);
    if (px <= this.width - 12 && px >= 0) return;
    this.scrollX = LEAD + this.store.playhead * this.pps - 24;
    this.clampScroll();
  }

  revealPlayhead() {
    this.reconcileZoom();
    const px = this.x(this.store.playhead);
    if (px >= 0 && px <= this.width) return;
    this.scrollX = LEAD + this.store.playhead * this.pps - this.width * 0.3;
    this.clampScroll();
    this.invalidate();
  }

  scrollToStart() { this.reconcileZoom(); this.scrollX = 0; this.clampScroll(); this.invalidate(); }

  // MARK: Toolbar

  buildToolbar() {
    const s = this.store;
    const tool = (iconEl, title, action) => h('button.tool', { title, onclick: action }, iconEl);
    this.tc = h('div.tl-tc');
    this.splitBtn = tool(icon('scissors'), 'Split at Playhead (Ctrl+B / S)', () => s.splitAtPlayhead());
    this.deleteBtn = tool(icon('trash'), 'Delete (Del) / Ripple Delete (Shift+Del)', e => s.deleteSelection(e.shiftKey));
    this.dupBtn = tool(icon('duplicate'), 'Duplicate (Ctrl+D)', () => s.duplicateSelection());
    this.joinBtn = tool(icon('join'), 'Join Clips (Ctrl+J)', () => s.joinSelection());
    this.gapsBtn = tool(icon('gaps'), 'Close Gaps', () => s.closeGaps());
    this.detachBtn = tool(icon('detach'), 'Detach Audio', () => this.app.detachAudio(s.selectedClips));
    this.titleBtn = tool(h('span.t-glyph', 'T'), 'Add Title (Ctrl+T)', () => s.addTextClip());
    this.fadeInBtn = tool(icon('fadeIn'), 'Fade In', () => this.toggleFade(true));
    this.fadeOutBtn = tool(icon('fadeOut'), 'Fade Out', () => this.toggleFade(false));
    this.snapBtn = tool(icon('magnet'), 'Snapping', () => s.toggleSnapping());
    this.zoomSlider = h('input', { type: 'range', min: 0, max: 1000, style: { width: '110px', accentColor: 'var(--accent)' }, title: 'Zoom (Ctrl+wheel on the timeline)',
      oninput: e => {
        s.setPixelsPerSecond(ZOOM_MIN * Math.exp(Number(e.target.value) / 1000 * Math.log(ZOOM_MAX / ZOOM_MIN)));
      } });
    this.zoomOutBtn = tool(icon('zoomOut'), 'Zoom Out', () => s.zoom(1 / 1.5));
    this.zoomInBtn = tool(icon('zoomIn'), 'Zoom In', () => s.zoom(1.5));
    return h('div.tl-toolbar', this.tc, h('div.tl-sep'), this.splitBtn, this.deleteBtn, this.dupBtn, this.joinBtn, this.gapsBtn, this.detachBtn,
      h('div.tl-sep'), this.titleBtn, this.fadeInBtn, this.fadeOutBtn, h('div', { style: { flex: 1 } }), this.snapBtn, h('div.tl-sep'),
      this.zoomOutBtn, this.zoomSlider, this.zoomInBtn, tool(icon('zoomFit'), 'Zoom to Fit (Shift+Z)', () => this.app.command('zoomToFit')));
  }

  toggleFade(fadeIn) {
    const clips = this.store.selectedClips;
    const allHave = clips.length && clips.every(c => (fadeIn ? c.fadeIn : c.fadeOut) > 0);
    const v = allHave ? 0 : 1;
    if (fadeIn) this.store.setFades(v, null); else this.store.setFades(null, v);
  }

  updateToolbar() {
    const s = this.store, p = s.project, fps = p.canvas.frameRate;
    this.tc.replaceChildren(fmt.timecode(s.playhead, fps), h('span', ` / ${fmt.timecode(M.projectDuration(p), fps)}`));
    const sel = s.selectedClips;
    const t = s.playhead, margin = s.frameDuration / 2;
    this.splitBtn.disabled = !p.tracks.some(tr => !tr.isLocked && tr.clips.some(c => t > c.start + margin && t < M.clipEnd(c) - margin));
    this.deleteBtn.disabled = !sel.length;
    this.dupBtn.disabled = !sel.length;
    this.joinBtn.disabled = !s.canJoinSelection;
    const hasGaps = p.tracks.some(tr => { let end = 0; for (const c of tr.clips) { if (c.start - end > 1e-6) return true; end = M.clipEnd(c); } return false; });
    this.gapsBtn.disabled = !hasGaps;
    this.gapsBtn.title = sel.length ? 'Close Gaps Before Selection' : 'Close All Gaps';
    this.detachBtn.disabled = !sel.some(c => s.canDetachAudio(c));
    for (const [btn, fadeIn] of [[this.fadeInBtn, true], [this.fadeOutBtn, false]]) {
      const allHave = sel.length > 0 && sel.every(c => (fadeIn ? c.fadeIn : c.fadeOut) > 0);
      btn.disabled = !sel.length;
      btn.classList.toggle('on', allHave);
      const name = fadeIn ? 'Fade In' : 'Fade Out';
      btn.title = allHave ? `Remove ${name}` : `${name} (1 s ${fadeIn ? 'from' : 'to'} black)`;
    }
    this.snapBtn.classList.toggle('on', s.snappingEnabled);
    this.snapBtn.title = s.snappingEnabled ? 'Snapping On (N)' : 'Snapping Off (N)';
    if (document.activeElement !== this.zoomSlider) this.zoomSlider.value = String(Math.log(s.pixelsPerSecond / ZOOM_MIN) / Math.log(ZOOM_MAX / ZOOM_MIN) * 1000);
    this.zoomOutBtn.disabled = s.pixelsPerSecond <= ZOOM_MIN;
    this.zoomInBtn.disabled = s.pixelsPerSecond >= ZOOM_MAX;
  }

  // MARK: Track headers

  renderHeaders() {
    const s = this.store;
    const tb = (name, title, on, action) => h('button.tbtn' + (on ? '.on' : ''), { title, onclick: action }, icon(name, 14));
    const rows = this.layout.rows.map(r => {
      const t = r.track;
      const btns = [];
      if (t.kind === 'video') btns.push(tb(t.isHidden ? 'eyeOff' : 'eye', t.isHidden ? 'Show track' : 'Hide track', t.isHidden, () => s.setTrack(t.id, { hidden: !t.isHidden })));
      btns.push(tb(t.isMuted ? 'mute' : 'speaker', t.isMuted ? 'Unmute track' : 'Mute track', t.isMuted, () => s.setTrack(t.id, { muted: !t.isMuted })));
      btns.push(tb(t.isLocked ? 'lock' : 'unlock', t.isLocked ? 'Unlock track' : 'Lock track', t.isLocked, () => s.setTrack(t.id, { locked: !t.isLocked })));
      return h('div.track-head', {
        style: { top: `${r.y}px`, height: `${r.height}px`, background: t.kind === 'video' ? 'rgba(61,107,204,0.08)' : 'rgba(51,158,115,0.08)' },
        oncontextmenu: e => { e.preventDefault(); contextMenu(e.clientX, e.clientY, [
          { label: 'Add Video Track', action: () => s.addTrack('video') },
          { label: 'Add Audio Track', action: () => s.addTrack('audio') }, '-',
          { label: `Remove Track ${r.name}`, action: () => s.removeTrack(t.id) }]); },
      }, h('div.tname', r.name), h('div.tbtns', ...btns));
    });
    const add = h('div.add-tracks', { style: { top: `${this.layout.tracksHeight + 8}px` } },
      h('button', { title: 'Add a video track', onclick: () => s.addTrack('video') }, '+ Video'),
      h('button', { title: 'Add an audio track', onclick: () => s.addTrack('audio') }, '+ Audio'));
    this.headerRows.replaceChildren(...rows, add);
    this.positionHeaders();
  }

  positionHeaders() { this.headerRows.style.transform = `translateY(${-this.scrollY}px)`; }

  // MARK: Drawing

  draw() {
    this.reconcileZoom();
    const ctx = this.canvas.getContext('2d');
    const dpr = window.devicePixelRatio || 1;
    const W = this.width, H = this.height;
    const s = this.store, p = s.project;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.fillStyle = '#212124';
    ctx.fillRect(0, 0, W, H);
    const visible = { start: this.rawTime(0), end: this.rawTime(W) };
    const scale = fmt.rulerScale(this.pps, p.canvas.frameRate);

    ctx.save();
    ctx.beginPath(); ctx.rect(0, RULER_H, W, H - RULER_H); ctx.clip();
    for (const r of this.layout.rows) {
      const y = this.viewY(r.y);
      ctx.fillStyle = r.kind === 'video' ? 'rgba(61,107,204,0.05)' : 'rgba(51,158,115,0.05)';
      ctx.fillRect(0, y, W, r.height);
      ctx.fillStyle = 'rgba(0,0,0,0.3)';
      ctx.fillRect(0, y + r.height - 1, W, 1);
    }
    // Grid
    ctx.fillStyle = 'rgba(255,255,255,0.035)';
    this.forEachTick(scale, visible, (t, major) => { if (major) ctx.fillRect(Math.round(this.x(t)), RULER_H, 1, H - RULER_H); });
    // Clips
    for (const r of this.layout.rows) {
      const top = this.viewY(r.y);
      if (top > H || top + r.height < RULER_H) continue;
      for (const clip of r.track.clips) {
        if (M.clipEnd(clip) < visible.start) continue;
        if (clip.start > visible.end) break;
        this.drawClip(ctx, clip, r.track, r, s.selection.has(clip.id));
      }
    }
    if (!M.projectDuration(p) && !this.dropPreview) {
      ctx.fillStyle = 'rgba(255,255,255,0.35)';
      ctx.font = '13px "Segoe UI"';
      ctx.textAlign = 'center';
      ctx.fillText('Drag media here from the bin or from Explorer', W / 2, RULER_H + Math.min(this.layout.tracksHeight, H - RULER_H) / 2);
      ctx.textAlign = 'left';
    }
    if (this.dropPreview) this.drawDropPreview(ctx, this.dropPreview);
    if (this.drag && this.drag.type === 'marquee') {
      const r = this.marqueeRect(this.drag);
      ctx.fillStyle = 'rgba(77,143,255,0.12)'; ctx.fillRect(r.x, r.y, r.w, r.h);
      ctx.strokeStyle = 'rgba(77,143,255,0.8)'; ctx.lineWidth = 1; ctx.strokeRect(r.x + 0.5, r.y + 0.5, r.w, r.h);
    }
    ctx.restore();

    this.drawRuler(ctx, scale, visible, W, p.canvas.frameRate);
    if (this.snapGuide !== null) {
      const x = Math.round(this.x(this.snapGuide)) + 0.5;
      ctx.strokeStyle = '#ffcc33'; ctx.lineWidth = 1; ctx.setLineDash([3, 3]);
      ctx.beginPath(); ctx.moveTo(x, 0); ctx.lineTo(x, H); ctx.stroke(); ctx.setLineDash([]);
    }
    // Playhead
    const px = Math.round(this.x(s.playhead)) + 0.5;
    if (px > -10 && px < W + 10) {
      ctx.strokeStyle = '#ff4d4d'; ctx.lineWidth = 1.5;
      ctx.beginPath(); ctx.moveTo(px, RULER_H - 6); ctx.lineTo(px, H); ctx.stroke();
      ctx.fillStyle = '#ff4d4d';
      ctx.beginPath(); ctx.moveTo(px - 6, 2); ctx.lineTo(px + 6, 2); ctx.lineTo(px + 6, RULER_H - 10); ctx.lineTo(px, RULER_H - 4); ctx.lineTo(px - 6, RULER_H - 10); ctx.closePath(); ctx.fill();
    }
    this.drawScrollers(ctx);
  }

  forEachTick(scale, visible, fn) {
    const step = scale.major / scale.divisions;
    const first = Math.max(0, Math.floor(visible.start / step));
    const last = Math.ceil(visible.end / step);
    for (let i = first; i <= last; i++) fn(i * step, i % scale.divisions === 0);
  }

  drawRuler(ctx, scale, visible, W, fps) {
    ctx.fillStyle = '#2b2b2e';
    ctx.fillRect(0, 0, W, RULER_H);
    ctx.fillStyle = 'rgba(0,0,0,0.45)';
    ctx.fillRect(0, RULER_H - 1, W, 1);
    ctx.font = '10px "Segoe UI"';
    ctx.textBaseline = 'top';
    this.forEachTick(scale, visible, (t, major) => {
      const x = Math.round(this.x(t)) + 0.5;
      ctx.fillStyle = major ? 'rgba(255,255,255,0.45)' : 'rgba(255,255,255,0.18)';
      ctx.fillRect(x - 0.5, major ? RULER_H - 11 : RULER_H - 6, 1, major ? 10 : 5);
      if (major) { ctx.fillStyle = 'rgba(255,255,255,0.6)'; ctx.fillText(fmt.rulerLabel(scale, t, fps), x + 3, 3); }
    });
  }

  drawClip(ctx, clip, track, row, selected) {
    const r = this.clipRect(clip, row);
    const media = clip.mediaID ? this.store.media(clip.mediaID) : null;
    const kind = clip.text ? null : (track.kind === 'audio' ? 'audio' : media ? media.kind : 'video');
    const style = COLORS[kind || 'text'];
    const minX = Math.max(r.x, -16), maxX = Math.min(r.x + r.w, this.width + 16);
    const shape = { x: minX, y: r.y, w: Math.max(1, maxX - minX), h: r.h };
    const radius = Math.min(6, r.w / 2, r.h / 2);
    const dimmed = track.isLocked || (track.kind === 'video' && track.isHidden) || (track.kind === 'audio' && track.isMuted);
    const offline = media ? !this.isOnline(media) : false;

    ctx.save();
    if (dimmed) ctx.globalAlpha = 0.42;
    ctx.save();
    ctx.beginPath(); ctx.roundRect(shape.x, shape.y, shape.w, shape.h, radius); ctx.clip();
    ctx.fillStyle = style.body;
    ctx.fillRect(shape.x, shape.y, shape.w, shape.h);
    if (kind === 'video' && media) {
      const hasSound = media.hasAudio && !clip.audioMuted && r.h > 36;
      const strip = hasSound ? 13 : 0;
      this.drawFilmstrip(ctx, media, clip, r, { x: shape.x, y: shape.y, w: shape.w, h: shape.h - strip });
      if (hasSound) {
        const sr = { x: shape.x, y: shape.y + shape.h - strip, w: shape.w, h: strip };
        ctx.fillStyle = 'rgba(0,0,0,0.55)'; ctx.fillRect(sr.x, sr.y, sr.w, sr.h);
        this.drawWaveform(ctx, media, clip, r, { x: sr.x, y: sr.y + 1.5, w: sr.w, h: sr.h - 3 }, track.isMuted ? 'rgba(255,255,255,0.25)' : COLORS.audio.wave);
      }
    } else if (kind === 'image' && media) {
      this.drawFilmstrip(ctx, media, clip, r, shape);
    } else if (kind === 'audio') {
      ctx.fillStyle = style.fill; ctx.fillRect(shape.x, shape.y, shape.w, shape.h);
      ctx.fillStyle = 'rgba(0,0,0,0.18)'; ctx.fillRect(shape.x, shape.y, shape.w, 16);
      if (media) this.drawWaveform(ctx, media, clip, r, { x: shape.x, y: shape.y + 16, w: shape.w, h: shape.h - 18 }, clip.audioMuted ? 'rgba(255,255,255,0.25)' : style.wave);
    } else if (kind === null) {
      this.drawTextBody(ctx, clip, r, shape, style);
    }
    if (kind === 'video' || kind === 'image') {
      const g = ctx.createLinearGradient(0, shape.y, 0, shape.y + 22);
      g.addColorStop(0, 'rgba(0,0,0,0.55)'); g.addColorStop(1, 'rgba(0,0,0,0)');
      ctx.fillStyle = g; ctx.fillRect(shape.x, shape.y, shape.w, 22);
    }
    this.drawFades(ctx, clip, r);
    if (track.isLocked) this.stripes(ctx, shape, 10, 'rgba(0,0,0,0.3)', 2);
    if (offline) { ctx.fillStyle = 'rgba(160,40,30,0.55)'; ctx.fillRect(shape.x, shape.y, shape.w, shape.h); }
    ctx.restore();

    if (kind !== null) this.drawLabel(ctx, clip, media, offline, r);
    if (selected) {
      ctx.strokeStyle = '#ffcc33'; ctx.lineWidth = 2;
      ctx.beginPath(); ctx.roundRect(shape.x + 1, shape.y + 1, shape.w - 2, shape.h - 2, Math.max(0, radius - 1)); ctx.stroke();
    } else {
      ctx.strokeStyle = this.hover && this.hover.id === clip.id ? 'rgba(255,255,255,0.75)' : style.border; ctx.lineWidth = 1;
      ctx.beginPath(); ctx.roundRect(shape.x + 0.5, shape.y + 0.5, shape.w - 1, shape.h - 1, Math.max(0, radius - 0.5)); ctx.stroke();
    }
    if (!track.isLocked && this.showsFadeHandles(clip, r)) {
      this.fadeHandle(ctx, this.fadeHandleCenter(clip, r, true), clip.fadeIn > 0);
      this.fadeHandle(ctx, this.fadeHandleCenter(clip, r, false), clip.fadeOut > 0);
    }
    ctx.restore();
  }

  isOnline(media) {
    const now = performance.now();
    if (!this.onlineCache || now - this.onlineCache.at > 2000) this.onlineCache = { at: now, map: new Map() };
    let v = this.onlineCache.map.get(media.url);
    if (v === undefined) { v = mediaFileExists(media); this.onlineCache.map.set(media.url, v); }
    return v;
  }

  drawLabel(ctx, clip, media, offline, r) {
    let title = clip.label || (media ? media.name : null) || (clip.text ? clip.text.text : 'Clip');
    if (offline) title = `Media Offline - ${title}`;
    let x = Math.max(r.x, 0) + 7;
    let trailing = 7;
    if (this.showsFadeHandles(clip, r)) {
      const hIn = this.fadeHandleCenter(clip, r, true);
      if (hIn.x + 7 > x && hIn.x - 7 < x + 40) x = hIn.x + 8;
      const hOut = this.fadeHandleCenter(clip, r, false);
      if (hOut.x > Math.min(r.x + r.w, this.width) - 48) trailing = Math.max(trailing, Math.min(r.x + r.w, this.width) - hOut.x + 9);
    }
    const available = r.x + r.w - 6 - x;
    if (available <= 14) return;
    let titleW = available;
    ctx.textBaseline = 'top';
    if (r.w > 150) {
      ctx.font = '10px "Segoe UI"';
      const detail = fmt.shortDuration(clip.duration);
      const dw = ctx.measureText(detail).width;
      const dx = Math.min(r.x + r.w, this.width) - trailing - dw;
      if (dx - x > 60) { ctx.fillStyle = 'rgba(255,255,255,0.65)'; ctx.fillText(detail, dx, r.y + 4); titleW = dx - 8 - x; }
    }
    ctx.font = '600 11px "Segoe UI"';
    ctx.fillStyle = 'rgba(255,255,255,0.95)';
    ctx.fillText(ellipsize(ctx, title, titleW), x, r.y + 3);
  }

  drawTextBody(ctx, clip, r, shape, style) {
    ctx.fillStyle = style.fill; ctx.fillRect(shape.x, shape.y, shape.w, shape.h);
    this.stripes(ctx, shape, 18, 'rgba(255,255,255,0.06)', 6);
    const bx = Math.max(r.x, 0) + 7, by = Math.round(r.y + r.h / 2 - 9);
    if (r.x + r.w - (bx + 18) <= -4) return;
    ctx.fillStyle = 'rgba(0,0,0,0.28)';
    ctx.beginPath(); ctx.roundRect(bx, by, 18, 18, 4); ctx.fill();
    ctx.fillStyle = 'white'; ctx.font = 'bold 12px Georgia'; ctx.textBaseline = 'middle';
    ctx.fillText('T', bx + 5, by + 9.5);
    const text = (clip.label || (clip.text ? clip.text.text : 'Title')).replace(/\n/g, ' ');
    const w = r.x + r.w - bx - 18 - 14;
    if (w > 12) { ctx.font = '600 11px "Segoe UI"'; ctx.fillText(ellipsize(ctx, text, w), bx + 25, by + 9.5); }
  }

  stripes(ctx, shape, step, color, width) {
    ctx.save();
    ctx.strokeStyle = color; ctx.lineWidth = width;
    ctx.beginPath();
    for (let x = shape.x - (shape.x % step) - shape.h; x < shape.x + shape.w; x += step) {
      ctx.moveTo(x, shape.y + shape.h); ctx.lineTo(x + shape.h, shape.y);
    }
    ctx.stroke();
    ctx.restore();
  }

  drawFades(ctx, clip, r) {
    const ramp = (a, b, c) => {
      ctx.fillStyle = 'rgba(0,0,0,0.5)';
      ctx.beginPath(); ctx.moveTo(a.x, a.y); ctx.lineTo(b.x, b.y); ctx.lineTo(c.x, c.y); ctx.closePath(); ctx.fill();
      ctx.strokeStyle = 'rgba(255,255,255,0.85)'; ctx.lineWidth = 1.25;
      ctx.beginPath(); ctx.moveTo(a.x, a.y); ctx.lineTo(b.x, b.y); ctx.stroke();
    };
    if (clip.fadeIn > 0) { const w = Math.min(clip.fadeIn * this.pps, r.w); ramp({ x: r.x, y: r.y + r.h }, { x: r.x + w, y: r.y }, { x: r.x, y: r.y }); }
    if (clip.fadeOut > 0) { const w = Math.min(clip.fadeOut * this.pps, r.w); ramp({ x: r.x + r.w, y: r.y + r.h }, { x: r.x + r.w - w, y: r.y }, { x: r.x + r.w, y: r.y }); }
  }

  fadeHandle(ctx, c, active) {
    ctx.save();
    ctx.shadowColor = 'rgba(0,0,0,0.8)'; ctx.shadowBlur = 2;
    ctx.fillStyle = active ? 'white' : 'rgba(255,255,255,0.8)';
    ctx.beginPath(); ctx.arc(c.x, c.y, 4.5, 0, Math.PI * 2); ctx.fill();
    ctx.restore();
    ctx.strokeStyle = 'rgba(0,0,0,0.5)'; ctx.lineWidth = 1;
    ctx.beginPath(); ctx.arc(c.x, c.y, 4, 0, Math.PI * 2); ctx.stroke();
  }

  /// Thumbnails along the clip: frame i of the media's filmstrip covers source time i * interval.
  drawFilmstrip(ctx, media, clip, r, area) {
    if (media.kind === 'image') {
      const img = this.app.cache.get('poster', media);
      if (!img) return;
      const iw = img.naturalWidth || img.width, ih = img.naturalHeight || img.height;
      const tw = Math.max(8, area.h * iw / ih);
      for (let x = Math.max(area.x, r.x); x < area.x + area.w; x += tw) ctx.drawImage(img, x, area.y, tw, area.h);
      return;
    }
    const fs = this.app.cache.get('filmstrip', media);
    if (!fs) return;
    const fw = fs.image.width / fs.frames, fh = fs.image.height;
    const tw = Math.max(8, area.h * fw / fh);
    const startX = r.x + Math.max(0, Math.floor((area.x - r.x) / tw)) * tw;
    for (let x = startX; x < area.x + area.w; x += tw) {
      const t = clip.sourceIn + (x - r.x + tw / 2) / this.pps;
      const i = Math.max(0, Math.min(fs.frames - 1, Math.floor(t / fs.interval)));
      ctx.drawImage(fs.image, i * fw, 0, fw, fh, x, area.y, tw, area.h);
    }
  }

  drawWaveform(ctx, media, clip, r, area, colorStr) {
    const wf = this.app.cache.get('waveform', media);
    if (!wf || area.h <= 2) return;
    const gain = Math.min(2, Math.max(0, clip.volume));
    ctx.fillStyle = colorStr;
    const x0 = Math.max(area.x, r.x), x1 = Math.min(area.x + area.w, r.x + r.w);
    const mid = area.y + area.h / 2;
    for (let x = Math.floor(x0); x < x1; x++) {
      const t0 = clip.sourceIn + (x - r.x) / this.pps, t1 = clip.sourceIn + (x + 1 - r.x) / this.pps;
      const a = Math.floor(t0 * wf.bucketsPerSecond), b = Math.max(a + 1, Math.floor(t1 * wf.bucketsPerSecond));
      let peak = 0;
      for (let i = a; i < b && i < wf.peaks.length; i++) if (i >= 0 && wf.peaks[i] > peak) peak = wf.peaks[i];
      const hh = Math.max(1, Math.min(1, peak * gain) * area.h);
      ctx.fillRect(x, mid - hh / 2, 1, hh);
    }
  }

  drawDropPreview(ctx, dp) {
    const row = dp.trackID ? this.layout.rows.find(r => r.trackID === dp.trackID) : null;
    const y = row ? this.viewY(row.y) + INSET : this.viewY(this.layout.tracksHeight) + 6;
    const hh = row ? row.height - 2 * INSET : (dp.trackKind === 'video' ? VIDEO_H : AUDIO_H) - 2 * INSET;
    let x = this.x(dp.start);
    ctx.save();
    for (const seg of dp.segments) {
      const w = Math.max(4, seg.duration * this.pps);
      ctx.fillStyle = 'rgba(77,143,255,0.25)'; ctx.strokeStyle = '#4d8fff'; ctx.lineWidth = 1.5; ctx.setLineDash([5, 4]);
      ctx.beginPath(); ctx.roundRect(x, y, w, hh, 6); ctx.fill(); ctx.stroke();
      ctx.setLineDash([]);
      ctx.fillStyle = 'white'; ctx.font = '600 11px "Segoe UI"'; ctx.textBaseline = 'top';
      ctx.fillText(ellipsize(ctx, seg.title, w - 12), x + 6, y + 4);
      x += w;
    }
    ctx.restore();
  }

  drawScrollers(ctx) {
    for (const s of [this.hScroller(), this.vScroller()]) {
      if (!s) continue;
      ctx.fillStyle = 'rgba(255,255,255,0.05)';
      ctx.beginPath(); ctx.roundRect(s.track.x, s.track.y, s.track.w, s.track.h, SCROLLER / 2); ctx.fill();
      ctx.fillStyle = this.drag && this.drag.type === 'scroller' ? 'rgba(255,255,255,0.45)' : 'rgba(255,255,255,0.25)';
      ctx.beginPath(); ctx.roundRect(s.knob.x, s.knob.y, s.knob.w, s.knob.h, SCROLLER / 2); ctx.fill();
    }
  }

  hScroller() {
    if (this.maxScrollX <= 0.5) return null;
    const trailing = this.maxScrollY > 0.5 ? SCROLLER + 2 : 0;
    const track = { x: 4, y: this.height - SCROLLER - 2, w: this.width - 8 - trailing, h: SCROLLER };
    const kw = Math.max(36, track.w * this.width / this.contentWidth);
    return { track, knob: { x: track.x + (track.w - kw) * this.scrollX / this.maxScrollX, y: track.y, w: kw, h: SCROLLER } };
  }

  vScroller() {
    if (this.maxScrollY <= 0.5) return null;
    const bottom = this.maxScrollX > 0.5 ? SCROLLER + 4 : 2;
    const track = { x: this.width - SCROLLER - 2, y: RULER_H + 2, w: SCROLLER, h: Math.max(0, this.height - RULER_H - 2 - bottom) };
    const kh = Math.max(24, track.h * this.trackViewportHeight / this.layout.contentHeight);
    return { track, knob: { x: track.x, y: track.y + (track.h - kh) * this.scrollY / this.maxScrollY, w: SCROLLER, h: kh } };
  }

  // MARK: Hit testing

  hitClip(p, includeFadeHandles = true) {
    const row = this.rowAtViewY(p.y);
    if (!row) return null;
    const track = row.track;
    const t = this.rawTime(p.x), slop = 2 / this.pps;
    const clip = track.clips.find(c => M.clipContains(c, t)) || track.clips.find(c => t >= c.start - slop && t < M.clipEnd(c) + slop);
    if (!clip) return null;
    const r = this.clipRect(clip, row);
    if (!(p.x >= r.x - 2 && p.x <= r.x + r.w + 2 && p.y >= r.y && p.y <= r.y + r.h)) return null;
    if (includeFadeHandles && this.showsFadeHandles(clip, r)) {
      for (const isIn of [true, false]) {
        const c = this.fadeHandleCenter(clip, r, isIn);
        if (Math.hypot(c.x - p.x, c.y - p.y) <= 7) return { clip, track, row, rect: r, edge: null, fadeHandle: isIn };
      }
    }
    const handle = Math.min(TRIM_W, r.w / 3);
    const edge = p.x - r.x <= handle ? 'leading' : r.x + r.w - p.x <= handle ? 'trailing' : null;
    return { clip, track, row, rect: r, edge, fadeHandle: null };
  }

  showsFadeHandles(clip, r) {
    if (r.w < 56) return false;
    if (this.hover && this.hover.id === clip.id) return true;
    if (this.drag && this.drag.type === 'fade' && this.drag.clipID === clip.id) return true;
    return this.store.selection.has(clip.id);
  }

  fadeHandleCenter(clip, r, fadeIn) {
    const inset = 11, y = r.y + 6;
    if (fadeIn) return { x: Math.min(r.x + r.w - inset, Math.max(r.x + inset, this.x(clip.start + clip.fadeIn))), y };
    return { x: Math.max(r.x + inset, Math.min(r.x + r.w - inset, this.x(M.clipEnd(clip) - clip.fadeOut))), y };
  }

  // MARK: Mouse

  installMouse() {
    const pos = e => { const r = this.canvas.getBoundingClientRect(); return { x: e.clientX - r.left, y: e.clientY - r.top }; };
    this.canvas.addEventListener('mousedown', e => {
      if (e.button !== 0) return;
      e.preventDefault();
      if (document.activeElement && document.activeElement !== document.body) document.activeElement.blur();
      const p = pos(e);
      this.lastPoint = p;
      this.mouseDown(p, e);
      const move = ev => { this.lastPoint = pos(ev); this.continueDrag(this.lastPoint, ev); this.updateAutoscroll(); };
      const up = ev => {
        window.removeEventListener('mousemove', move);
        window.removeEventListener('mouseup', up);
        this.mouseUp(pos(ev));
      };
      window.addEventListener('mousemove', move);
      window.addEventListener('mouseup', up);
    });
    this.canvas.addEventListener('mousemove', e => { if (!this.drag) this.updateHover(pos(e)); });
    this.canvas.addEventListener('mouseleave', () => { if (!this.drag && this.hover) { this.hover = null; this.invalidate(); } });
    this.canvas.addEventListener('wheel', e => {
      e.preventDefault();
      const p = pos(e);
      if (e.ctrlKey || e.altKey) { this.zoomAt(Math.exp(-e.deltaY * 0.0015), p.x); return; }
      let dx = e.deltaX, dy = e.deltaY;
      if (e.shiftKey || (this.maxScrollY <= 0.5 && Math.abs(dy) > Math.abs(dx))) { dx = dy || dx; dy = 0; }
      this.scroll(dx, dy);
      if (this.drag && this.lastPoint) this.continueDrag(this.lastPoint, e);
    }, { passive: false });
    this.canvas.addEventListener('contextmenu', e => { e.preventDefault(); this.showContextMenu(pos(e), e); });
  }

  mouseDown(p, e) {
    const s = this.store;
    this.snapGuide = null;
    const hs = this.hScroller(), vs = this.vScroller();
    if (hs && inRect(p, { ...hs.track, y: hs.track.y - 2, h: hs.track.h + 4 })) {
      if (!inRect(p, hs.knob)) { this.scroll((p.x - (hs.knob.x + hs.knob.w / 2)) * this.contentWidth / hs.track.w, 0); }
      const k = this.hScroller().knob;
      this.drag = { type: 'scroller', horizontal: true, grab: inRect(p, hs.knob) ? p.x - k.x : k.w / 2 };
      return;
    }
    if (vs && inRect(p, { ...vs.track, x: vs.track.x - 2, w: vs.track.w + 4 })) {
      if (!inRect(p, vs.knob)) { this.scroll(0, (p.y - (vs.knob.y + vs.knob.h / 2)) * this.layout.contentHeight / vs.track.h); }
      const k = this.vScroller().knob;
      this.drag = { type: 'scroller', horizontal: false, grab: inRect(p, vs.knob) ? p.y - k.y : k.h / 2 };
      return;
    }
    if (p.y < RULER_H) {
      this.drag = { type: 'scrub' };
      this.scrub(p.x, false);
      return;
    }
    const toggle = e.shiftKey || e.ctrlKey;
    const hit = this.hitClip(p);
    if (!hit) {
      const origin = { time: this.rawTime(p.x), y: this.contentY(p.y) };
      const base = toggle ? new Set(s.selection) : new Set();
      if (!toggle && s.selection.size) s.setSelection([]);
      this.drag = { type: 'marquee', origin, current: origin, base };
      return;
    }
    const id = hit.clip.id;
    if (e.detail === 2) {
      const t = Math.min(Math.max(this.rawTime(p.x), hit.clip.start), Math.max(hit.clip.start, M.clipEnd(hit.clip) - s.frameDuration));
      this.app.playback.seek(t);
      if (hit.clip.text) { s.setSelection([id]); this.app.inspector.requestTextEditing(id); }
      this.drag = null;
      return;
    }
    const locked = hit.track.isLocked;
    if (hit.fadeHandle !== null && !locked) {
      if (!s.selection.has(id)) s.setSelection([id]);
      this.drag = { type: 'fade', clipID: id, isFadeIn: hit.fadeHandle, key: `timeline-fade-${M.uuid()}` };
      s.endCoalescing();
      return;
    }
    if (hit.edge && !locked && !toggle) {
      if (!s.selection.has(id)) s.setSelection([id]);
      this.drag = { type: 'trim', clipID: id, edge: hit.edge, originalEdge: hit.edge === 'leading' ? hit.clip.start : M.clipEnd(hit.clip),
        downTime: this.rawTime(p.x), key: `timeline-trim-${M.uuid()}`, last: null };
      s.endCoalescing();
      return;
    }
    let collapse = false;
    if (toggle) {
      if (s.selection.has(id)) { const n = new Set(s.selection); n.delete(id); s.setSelection(n); this.drag = null; return; }
      s.setSelection([...s.selection, id]);
    } else if (!s.selection.has(id)) {
      s.setSelection([id]);
    } else {
      collapse = s.selection.size > 1;
    }
    if (locked) { this.drag = null; return; }
    this.drag = this.makeMoveDrag(hit, p, collapse);
  }

  mouseUp(p) {
    this.stopAutoscroll();
    const d = this.drag;
    if (d) {
      if (d.type === 'scrub') this.scrub(p.x, true);
      else if (d.type === 'move') { if (d.started) this.store.endCoalescing(); else if (d.collapse) this.store.setSelection([d.anchor.id]); }
      else if (d.type === 'trim' || d.type === 'fade') this.store.endCoalescing();
    }
    this.drag = null;
    this.snapGuide = null;
    this.invalidate();
    this.updateHover(p);
  }

  continueDrag(p, e) {
    const d = this.drag;
    if (!d) return;
    switch (d.type) {
      case 'scrub': this.scrub(p.x, false); break;
      case 'move':
        if (!d.started) { if (Math.hypot(p.x - d.down.x, p.y - d.down.y) < 3) return; d.started = true; }
        this.updateMove(d, p);
        break;
      case 'trim': this.updateTrim(d, p); break;
      case 'fade': this.updateFade(d, p); break;
      case 'marquee':
        d.current = { time: this.rawTime(p.x), y: this.contentY(p.y) };
        this.applyMarquee(d);
        this.invalidate();
        break;
      case 'scroller': {
        if (d.horizontal) {
          const hs = this.hScroller(); if (!hs) return;
          const span = hs.track.w - hs.knob.w; if (span <= 0) return;
          this.scroll(((p.x - d.grab - hs.track.x) / span) * this.maxScrollX - this.scrollX, 0);
        } else {
          const vs = this.vScroller(); if (!vs) return;
          const span = vs.track.h - vs.knob.h; if (span <= 0) return;
          this.scroll(0, ((p.y - d.grab - vs.track.y) / span) * this.maxScrollY - this.scrollY);
        }
        break;
      }
      default: break;
    }
  }

  scrub(x, precise) {
    const s = this.store;
    let t = this.time(x);
    let guide = null;
    if (s.snappingEnabled) {
      const th = SNAP_PX / this.pps;
      const near = s.snapTargets().filter(v => Math.abs(v - s.playhead) > 1e-9).reduce((b, v) => (b === null || Math.abs(v - t) < Math.abs(b - t) ? v : b), null);
      if (near !== null && Math.abs(near - t) <= th) { t = near; guide = near; }
    }
    this.snapGuide = precise ? null : guide;
    this.app.playback.seek(t);
    this.invalidate();
  }

  makeMoveDrag(hit, p, collapse) {
    const s = this.store;
    const items = [];
    for (const track of s.project.tracks) {
      if (track.isLocked) continue;
      for (const c of track.clips) if (s.selection.has(c.id)) items.push({ id: c.id, trackID: track.id, start: c.start, duration: c.duration, kind: this.contentKind(c) });
    }
    const anchor = { id: hit.clip.id, trackID: hit.track.id, start: hit.clip.start, duration: hit.clip.duration, kind: this.contentKind(hit.clip) };
    if (!items.some(i => i.id === anchor.id)) items.push(anchor);
    const trackIDs = new Set(items.map(i => i.trackID));
    const kinds = new Set(s.project.tracks.filter(t => trackIDs.has(t.id)).map(t => t.kind));
    return { type: 'move', anchor, items, groupKind: kinds.size === 1 ? [...kinds][0] : null, down: p, downTime: this.rawTime(p.x),
      key: `timeline-move-${M.uuid()}`, collapse, started: false, applied: null };
  }

  kindOrdinal(trackID) {
    const tracks = this.store.project.tracks;
    const t = tracks.find(x => x.id === trackID);
    if (!t) return null;
    return tracks.filter(x => x.kind === t.kind).findIndex(x => x.id === trackID);
  }

  updateMove(d, p) {
    const s = this.store;
    const minStart = Math.min(...d.items.map(i => i.start));
    let delta = Math.max(this.rawTime(p.x) - d.downTime, -minStart);
    const moving = new Set(d.items.map(i => i.id));
    const th = SNAP_PX / this.pps;
    const aStart = d.anchor.start + delta, aEnd = aStart + d.anchor.duration;
    const d1 = s.snap(aStart, moving, th) - aStart, d2 = s.snap(aEnd, moving, th) - aEnd;
    let guide = null;
    if (d1 !== 0 && (d2 === 0 || Math.abs(d1) <= Math.abs(d2))) { delta += d1; guide = aStart + d1; }
    else if (d2 !== 0) { delta += d2; guide = aEnd + d2; }
    else delta = M.quantize(s.project.canvas, delta);
    delta = Math.max(delta, -minStart);
    const pointerRow = this.rowAtViewY(Math.min(Math.max(p.y, RULER_H), this.height - 1));
    this.snapGuide = guide;
    this.invalidate();
    if (d.items.length === 1) {
      let target = d.applied ? d.applied.trackID : d.anchor.trackID;
      if (pointerRow && !pointerRow.track.isLocked && M.trackAccepts(pointerRow.track, d.anchor.kind)) target = pointerRow.trackID;
      if (d.applied && d.applied.delta === delta && d.applied.trackID === target) return;
      s.moveClip(d.anchor.id, target, d.anchor.start + delta, d.key);
      d.applied = { delta, trackID: target, offset: 0 };
      return;
    }
    let offset = d.applied ? d.applied.offset : 0;
    if (d.groupKind && pointerRow && pointerRow.kind === d.groupKind) {
      const from = this.kindOrdinal(d.anchor.trackID), to = this.kindOrdinal(pointerRow.trackID);
      if (from !== null && to !== null) offset = to - from;
    }
    if (d.applied && d.applied.delta === delta && d.applied.offset === offset) return;
    d.applied = { delta, trackID: d.anchor.trackID, offset };
    const cur = M.locate(s.project, d.anchor.id);
    if (!cur) return;
    const curTrack = s.project.tracks[cur.track];
    const curDelta = curTrack.clips[cur.clip].start - d.anchor.start;
    const curOffset = (this.kindOrdinal(curTrack.id) || 0) - (this.kindOrdinal(d.anchor.trackID) || 0);
    s.moveClips(moving, delta - curDelta, offset - curOffset, d.key);
  }

  updateTrim(d, p) {
    const s = this.store;
    const raw = Math.max(0, d.originalEdge + this.rawTime(p.x) - d.downTime);
    const snapped = s.snap(raw, new Set([d.clipID]), SNAP_PX / this.pps);
    this.snapGuide = snapped !== raw ? snapped : null;
    const target = snapped !== raw ? snapped : M.quantize(s.project.canvas, raw);
    this.invalidate();
    if (d.last === target) return;
    d.last = target;
    s.trimClip(d.clipID, d.edge, target, d.key);
  }

  updateFade(d, p) {
    const s = this.store;
    const clip = s.clip(d.clipID);
    if (!clip) return;
    const t = this.rawTime(p.x), canvas = s.project.canvas;
    if (d.isFadeIn) {
      const v = M.quantize(canvas, Math.min(Math.max(0, t - clip.start), clip.duration - clip.fadeOut));
      if (v !== clip.fadeIn) s.updateClip(d.clipID, 'Fade In', c => { c.fadeIn = Math.max(0, v); }, { coalesce: d.key });
    } else {
      const v = M.quantize(canvas, Math.min(Math.max(0, M.clipEnd(clip) - t), clip.duration - clip.fadeIn));
      if (v !== clip.fadeOut) s.updateClip(d.clipID, 'Fade Out', c => { c.fadeOut = Math.max(0, v); }, { coalesce: d.key });
    }
    this.invalidate();
  }

  applyMarquee(d) {
    const t0 = Math.min(d.origin.time, d.current.time), t1 = Math.max(d.origin.time, d.current.time);
    const y0 = Math.min(d.origin.y, d.current.y), y1 = Math.max(d.origin.y, d.current.y);
    const sel = new Set(d.base);
    if (t1 - t0 > 0 || y1 - y0 > 0) {
      for (const r of this.layout.rows) {
        if (!(r.y + r.height - INSET > y0 && r.y + INSET < y1)) continue;
        for (const c of r.track.clips) if (M.clipEnd(c) > t0 && c.start < t1) sel.add(c.id);
      }
    }
    this.store.setSelection(sel);
  }

  marqueeRect(d) {
    const a = { x: this.x(d.origin.time), y: this.viewY(d.origin.y) }, b = { x: this.x(d.current.time), y: this.viewY(d.current.y) };
    return { x: Math.min(a.x, b.x), y: Math.min(a.y, b.y), w: Math.abs(a.x - b.x), h: Math.abs(a.y - b.y) };
  }

  // MARK: Autoscroll near the edges while dragging

  autoscrollVelocity(p) {
    const d = this.drag;
    if (!d || !['scrub', 'move', 'trim', 'fade', 'marquee'].includes(d.type)) return { dx: 0, dy: 0 };
    const edge = 24;
    let dx = 0, dy = 0;
    if (p.x < edge) dx = -(edge - p.x); else if (p.x > this.width - edge) dx = p.x - (this.width - edge);
    if (d.type !== 'scrub') {
      if (p.y < RULER_H + 8 && p.y > 0) dy = -(RULER_H + 8 - p.y) / 2; else if (p.y > this.height - 12) dy = (p.y - this.height + 12) / 2;
    }
    return { dx: Math.max(-60, Math.min(60, dx * 0.6)), dy: Math.max(-20, Math.min(20, dy)) };
  }

  updateAutoscroll() {
    const v = this.autoscrollVelocity(this.lastPoint);
    if (!v.dx && !v.dy) { this.stopAutoscroll(); return; }
    if (this.autoscrollTimer) return;
    this.autoscrollTimer = setInterval(() => {
      if (!this.lastPoint) return;
      const w = this.autoscrollVelocity(this.lastPoint);
      if (!w.dx && !w.dy) { this.stopAutoscroll(); return; }
      this.scroll(w.dx, w.dy);
      this.continueDrag(this.lastPoint, {});
    }, 1000 / 60);
  }

  stopAutoscroll() { clearInterval(this.autoscrollTimer); this.autoscrollTimer = null; }

  updateHover(p) {
    let hv = null;
    let cursor = '';
    const hs = this.hScroller(), vs = this.vScroller();
    if ((hs && inRect(p, hs.track)) || (vs && inRect(p, vs.track))) hv = { type: 'scroller' };
    else {
      const hit = this.hitClip(p);
      if (hit) {
        if (hit.fadeHandle !== null) { hv = { type: 'fade', id: hit.clip.id }; cursor = 'pointer'; }
        else if (hit.edge && !hit.track.isLocked) { hv = { type: 'trim', id: hit.clip.id }; cursor = hit.edge === 'leading' ? 'w-resize' : 'e-resize'; }
        else hv = { type: 'clip', id: hit.clip.id };
      }
    }
    this.canvas.style.cursor = cursor;
    if (JSON.stringify(hv) !== JSON.stringify(this.hover)) { this.hover = hv; this.invalidate(); }
  }

  // MARK: Context menus

  showContextMenu(p, e) {
    if (p.y < RULER_H) return;
    const s = this.store;
    const hit = this.hitClip(p, false);
    if (hit) {
      if (!s.selection.has(hit.clip.id)) s.setSelection([hit.clip.id]);
      const sel = s.selectedClips;
      const ph = s.playhead, half = s.frameDuration / 2;
      const detachable = sel.filter(c => s.canDetachAudio(c));
      contextMenu(e.clientX, e.clientY, [
        { label: 'Split at Playhead', shortcut: 'Ctrl+B', enabled: sel.some(c => ph > c.start + half && ph < M.clipEnd(c) - half), action: () => s.splitAtPlayhead() },
        '-',
        { label: 'Duplicate', shortcut: 'Ctrl+D', action: () => s.duplicateSelection() },
        { label: 'Join Clips', shortcut: 'Ctrl+J', enabled: s.canJoinSelection, action: () => s.joinSelection() },
        ...(detachable.length ? [{ label: detachable.length > 1 ? `Detach Audio (${detachable.length} clips)` : 'Detach Audio', action: () => this.app.detachAudio(detachable) }] : []),
        '-',
        { label: 'Fade In 0.5s', action: () => s.setFades(0.5, null) },
        { label: 'Fade In 1s', action: () => s.setFades(1, null) },
        { label: 'Fade Out 0.5s', action: () => s.setFades(null, 0.5) },
        { label: 'Fade Out 1s', action: () => s.setFades(null, 1) },
        { label: 'Remove Fades', enabled: sel.some(c => c.fadeIn > 0 || c.fadeOut > 0), action: () => s.setFades(0, 0) },
        '-',
        { label: 'Delete', shortcut: 'Del', action: () => s.deleteSelection(false) },
        { label: 'Ripple Delete', shortcut: 'Shift+Del', action: () => s.deleteSelection(true) },
      ]);
      return;
    }
    const row = this.rowAtViewY(p.y);
    const time = this.time(p.x);
    const titleTrack = row && row.kind === 'video' && !row.track.isLocked ? row.trackID : null;
    contextMenu(e.clientX, e.clientY, [
      { label: 'Add Title Here', shortcut: 'Ctrl+T', action: () => s.addTextClip({ time: M.quantize(s.project.canvas, time), trackID: titleTrack }) },
      { label: 'Paste at Playhead', shortcut: 'Ctrl+V', enabled: s.canPaste, action: () => s.pasteAtPlayhead() },
      { label: 'Close Gaps', action: () => s.closeGaps() },
      { label: 'Select All', shortcut: 'Ctrl+A', action: () => s.selectAll() },
      '-',
      { label: 'Add Video Track', action: () => s.addTrack('video') },
      { label: 'Add Audio Track', action: () => s.addTrack('audio') },
      ...(row ? ['-', { label: `Remove Track ${row.name}`, action: () => s.removeTrack(row.trackID) }] : []),
    ]);
  }

  // MARK: Drops (bin items and Explorer files) with a placement preview

  installDrops() {
    const pos = e => { const r = this.canvas.getBoundingClientRect(); return { x: e.clientX - r.left, y: e.clientY - r.top }; };
    const source = e => {
      const types = [...e.dataTransfer.types];
      if (types.includes('Files')) {
        // Paths are only readable on drop; during the drag the item count and types are known.
        const items = [...e.dataTransfer.items].filter(i => i.kind === 'file');
        return { files: items.map(i => i.type) };
      }
      if (types.includes('text/plain') && this.app.draggingMedia) return { bin: true };
      return null;
    };
    this.wrap.addEventListener('dragover', e => {
      const src = source(e);
      if (!src) return;
      e.preventDefault();
      e.stopPropagation();
      e.dataTransfer.dropEffect = 'copy';
      this.dropPreview = this.makeDropPreview(this.previewEntries(e, src), pos(e));
      this.invalidate();
    });
    this.wrap.addEventListener('dragleave', () => { this.dropPreview = null; this.invalidate(); });
    this.wrap.addEventListener('drop', async e => {
      e.preventDefault();
      e.stopPropagation();
      this.app.hideDropHighlight();
      const p = pos(e);
      const paths = droppedPathsOf(e);
      const id = mediaIDFromDrag(e);
      this.dropPreview = null;
      this.invalidate();
      const projects = paths.filter(f => f.toLowerCase().endsWith(`.${M.FILE_EXTENSION}`));
      if (projects.length) { this.app.documents.openFiles(projects); return; }
      const key = `drop-${M.uuid()}`;
      let items = [];
      if (paths.length) items = await this.app.documents.importPaths(paths, key);
      else if (id && this.store.media(id)) items = [this.store.media(id)];
      if (!items.length) return;
      const entries = items.map(m => ({ kind: m.kind, title: m.name, duration: m.kind === 'image' ? DROP_DEFAULT : Math.max(m.duration, this.store.frameDuration) }));
      const preview = this.makeDropPreview(entries, p);
      if (preview) this.place(items, preview, key);
    });
  }

  previewEntries(e, src) {
    if (src.files) {
      return src.files.map(type => ({ kind: type.startsWith('audio') ? 'audio' : type.startsWith('image') ? 'image' : 'video', title: 'Media', duration: DROP_DEFAULT }));
    }
    const m = this.app.draggingMedia ? this.store.media(this.app.draggingMedia) : null;
    if (m) return [{ kind: m.kind, title: m.name, duration: m.kind === 'image' ? DROP_DEFAULT : Math.max(m.duration, this.store.frameDuration) }];
    return [{ kind: 'video', title: 'Media', duration: DROP_DEFAULT }];
  }

  makeDropPreview(entries, p) {
    if (!entries.length) return null;
    const s = this.store;
    const first = entries[0];
    const trackKind = first.kind === 'audio' ? 'audio' : 'video';
    const start = M.quantize(s.project.canvas, s.snap(this.time(p.x), new Set(), SNAP_PX / this.pps));
    const row = this.rowAtViewY(p.y);
    const segments = entries.map(x => ({ title: x.title, duration: x.duration }));
    if (row && !row.track.isLocked && M.trackAccepts(row.track, first.kind)) return { start, segments, trackKind, trackID: row.trackID, explicit: true };
    const predicted = s.project.tracks.find(t => t.kind === trackKind && R.allowsAutomaticPlacement(t) && R.isFree(t, start, first.duration));
    return { start, segments, trackKind, trackID: predicted ? predicted.id : null, explicit: false };
  }

  /// Adds `items` one after another from the preview position (one undo step) and selects them.
  place(items, preview, key) {
    const s = this.store;
    let t = preview.start;
    const added = [];
    for (const item of items) {
      const tr = preview.explicit && preview.trackID ? this.track(preview.trackID) : null;
      const explicit = tr && M.trackAccepts(tr, item.kind) ? tr.id : null;
      const id = s.addClip(item.id, { trackID: explicit, time: t, coalesce: key });
      if (id) added.push(id);
      const c = id && s.clip(id);
      t = c ? M.clipEnd(c) : t + (item.kind === 'image' ? DROP_DEFAULT : item.duration);
    }
    s.endCoalescing();
    if (added.length > 1) s.setSelection(added);
  }
}

function inRect(p, r) { return p.x >= r.x && p.x <= r.x + r.w && p.y >= r.y && p.y <= r.y + r.h; }

function ellipsize(ctx, text, width) {
  if (width <= 0) return '';
  if (ctx.measureText(text).width <= width) return text;
  let lo = 0, hi = text.length;
  while (lo < hi) { const mid = (lo + hi + 1) >> 1; if (ctx.measureText(text.slice(0, mid) + '...').width <= width) lo = mid; else hi = mid - 1; }
  return lo > 0 ? text.slice(0, lo) + '...' : '';
}

module.exports = { Timeline };
