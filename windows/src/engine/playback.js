'use strict';
// Live preview: plays the project into a canvas with sound. Replaces PlaybackController.swift.
//
// * The AudioContext clock is the master clock while playing; the playhead follows it.
// * Each visible video clip near the playhead gets its own muted <video> element (pooled by clip
//   id). While playing, elements play along and are re-seeked when they drift; while paused they
//   are seeked to the exact frame and the canvas redraws when the seek lands.
// * Audio is scheduled with Web Audio (engine/audio.js) and rescheduled after every edit.
// * `seek(t)` is the only way the UI should move the playhead.

const M = require('../core/model');
const compositor = require('./compositor');
const audio = require('./audio');
const { mediaPath } = require('../core/store');

const MAX_PREVIEW_DIMENSION = 1920;
const PREROLL = 1.5;
const DRIFT = 0.2;
const POOL_LIMIT = 10;

class PlaybackController {
  constructor(store, cache, canvas) {
    this.store = store;
    this.cache = cache;
    this.canvas = canvas;
    this.ctx2d = canvas.getContext('2d');
    this.isPlaying = false;
    this.audioCtx = null;
    this.master = null;
    this.nodes = [];
    this.clock = null; // { ctxTime, timeline }
    this.videos = new Map(); // clip id -> { el, mediaUrl, lastUse }
    this.needsDraw = true;
    this.listeners = [];
    this.lastError = null;

    store.on('project', () => {
      if (this.isPlaying) this.rescheduleAudio();
      this.preloadAudio();
      this.invalidate();
    });
    store.on('ui', () => this.invalidate());
    cache.onChange(() => this.invalidate());
    this.loop = this.loop.bind(this);
    requestAnimationFrame(this.loop);
    this.preloadAudio();
  }

  onState(fn) { this.listeners.push(fn); }
  emitState() { for (const fn of this.listeners) fn(); }
  invalidate() { this.needsDraw = true; }

  // MARK: Transport

  async play() {
    const p = this.store.project;
    const duration = M.projectDuration(p);
    if (duration <= 0 || this.isPlaying) return;
    if (this.store.playhead >= duration - M.frameDuration(p.canvas) / 2) this.store.setPlayhead(0);
    this.ensureAudio();
    if (this.audioCtx.state === 'suspended') await this.audioCtx.resume();
    this.isPlaying = true;
    this.clock = { ctxTime: this.audioCtx.currentTime + 0.05, timeline: this.store.playhead };
    this.rescheduleAudio();
    this.emitState();
  }

  pause() {
    if (!this.isPlaying) return;
    const t = this.currentTime();
    this.isPlaying = false;
    this.stopAudio();
    for (const v of this.videos.values()) if (!v.el.paused) v.el.pause();
    this.store.setPlayhead(Math.max(0, Math.min(t, M.projectDuration(this.store.project))));
    this.emitState();
  }

  togglePlay() { if (this.isPlaying) this.pause(); else this.play(); }

  /// Moves the playhead (clamped to 0...duration). While playing, playback continues from there.
  seek(t) {
    const d = M.projectDuration(this.store.project);
    const clamped = Math.max(0, Math.min(Number.isFinite(t) ? t : 0, d));
    this.store.setPlayhead(clamped);
    if (this.isPlaying) {
      this.clock = { ctxTime: this.audioCtx.currentTime + 0.05, timeline: clamped };
      this.rescheduleAudio();
    }
    this.invalidate();
  }

  stepFrames(n) { if (this.isPlaying) this.pause(); this.seek(this.store.playhead + n * this.store.frameDuration); }
  goToStart() { this.seek(0); }
  goToEnd() { if (this.isPlaying) this.pause(); this.seek(M.projectDuration(this.store.project)); }

  currentTime() {
    if (!this.isPlaying) return this.store.playhead;
    return this.clock.timeline + Math.max(0, this.audioCtx.currentTime - this.clock.ctxTime);
  }

  // MARK: Audio

  ensureAudio() {
    if (this.audioCtx) return;
    this.audioCtx = new AudioContext({ sampleRate: 48000, latencyHint: 'interactive' });
    this.master = this.audioCtx.createGain();
    this.master.connect(this.audioCtx.destination);
  }

  stopAudio() {
    for (const n of this.nodes) { try { n.stop(); } catch { /* never started */ } n.disconnect(); }
    this.nodes = [];
  }

  rescheduleAudio() {
    this.stopAudio();
    const now = this.audioCtx.currentTime;
    const from = this.currentTime();
    this.clock = { ctxTime: Math.max(now, this.clock.ctxTime), timeline: from };
    this.nodes = audio.schedule(this.audioCtx, this.master, this.store.project, from, this.clock.ctxTime,
      media => this.cache.get('audio', media));
  }

  /// Starts decoding every audible media; reschedules when one arrives during playback.
  preloadAudio() {
    for (const { media } of audio.audibleClips(this.store.project)) {
      if (this.cache.get('audio', media) || this.cache.error('audio', media)) continue;
      this.cache.ready('audio', media).then(buf => { if (buf && this.isPlaying) this.rescheduleAudio(); });
    }
  }

  // MARK: Frame loop

  loop() {
    requestAnimationFrame(this.loop);
    const p = this.store.project;
    if (this.isPlaying) {
      const d = M.projectDuration(p);
      let t = this.currentTime();
      if (t >= d) {
        t = d;
        this.pause();
        this.store.setPlayhead(d);
      } else {
        this.store.setPlayhead(t);
      }
      this.needsDraw = true;
    }
    this.syncVideos();
    if (this.needsDraw) {
      this.needsDraw = false;
      this.draw();
    }
  }

  /// Output size of the preview canvas for the project (canvas aspect, capped).
  renderSize() {
    const c = this.store.project.canvas;
    const box = this.canvas.getBoundingClientRect();
    const dpr = window.devicePixelRatio || 1;
    const fit = Math.min(box.width * dpr / c.width, box.height * dpr / c.height, MAX_PREVIEW_DIMENSION / Math.max(c.width, c.height), 1);
    return { width: Math.max(2, Math.round(c.width * fit)), height: Math.max(2, Math.round(c.height * fit)) };
  }

  draw() {
    const p = this.store.project;
    const size = this.renderSize();
    if (this.canvas.width !== size.width || this.canvas.height !== size.height) {
      this.canvas.width = size.width;
      this.canvas.height = size.height;
    }
    const t = compositor.displayTime(p, this.isPlaying ? this.currentTime() : this.store.playhead);
    compositor.composeFrame(this.ctx2d, size.width, size.height, p, t, layer => this.resolve(layer, t));
  }

  resolve(layer, t) {
    const m = layer.media;
    if (m.kind === 'image') {
      const img = this.cache.get('still', m);
      return img ? { image: img, width: img.naturalWidth, height: img.naturalHeight } : null;
    }
    const v = this.videos.get(layer.clip.id);
    if (!v || v.el.readyState < 2 || !v.el.videoWidth) return null;
    return { image: v.el, width: v.el.videoWidth, height: v.el.videoHeight };
  }

  /// Creates, positions, plays and retires the <video> elements around the playhead.
  syncVideos() {
    const p = this.store.project;
    const t = compositor.displayTime(p, this.isPlaying ? this.currentTime() : this.store.playhead);
    const now = performance.now();
    const wanted = new Set();
    for (const track of p.tracks) {
      if (track.kind !== 'video' || track.isHidden) continue;
      for (const clip of track.clips) {
        const media = clip.mediaID ? M.findMedia(p, clip.mediaID) : null;
        if (!media || media.kind !== 'video') continue;
        const active = M.clipContains(clip, t);
        const upcoming = !active && clip.start > t && clip.start - t < PREROLL;
        if (!active && !upcoming) continue;
        wanted.add(clip.id);
        const v = this.videoFor(clip, media);
        v.lastUse = now;
        const target = compositor.sourceTime(clip, media, active ? t : clip.start);
        const el = v.el;
        if (active && this.isPlaying) {
          const pastEnd = clip.sourceIn + (t - clip.start) >= media.duration;
          if (pastEnd) { if (!el.paused) el.pause(); }
          else if (el.paused) { if (Math.abs(el.currentTime - target) > 0.05) el.currentTime = target; el.play().catch(e => { if (e.name !== 'AbortError') console.error('EditRush video play failed', media.name, e); }); }
          if (!el.seeking && Math.abs(el.currentTime - target) > DRIFT) el.currentTime = target;
        } else {
          if (!el.paused) el.pause();
          if (!el.seeking && Math.abs(el.currentTime - target) > 1e-3) el.currentTime = target;
        }
      }
    }
    for (const [id, v] of this.videos) {
      if (wanted.has(id)) continue;
      if (!v.el.paused) v.el.pause();
    }
    if (this.videos.size > POOL_LIMIT) {
      const idle = [...this.videos].filter(([id]) => !wanted.has(id)).sort((a, b) => a[1].lastUse - b[1].lastUse);
      for (const [id, v] of idle.slice(0, this.videos.size - POOL_LIMIT)) {
        v.el.removeAttribute('src');
        v.el.load();
        this.videos.delete(id);
      }
    }
  }

  videoFor(clip, media) {
    let v = this.videos.get(clip.id);
    if (v && v.mediaUrl === media.url) return v;
    if (v) { v.el.removeAttribute('src'); v.el.load(); }
    const el = document.createElement('video');
    el.muted = true;
    el.preload = 'auto';
    el.playsInline = true;
    el.addEventListener('seeked', () => this.invalidate());
    el.addEventListener('loadeddata', () => this.invalidate());
    el.addEventListener('error', () => {
      this.lastError = `Could not play ${media.name}: ${el.error ? el.error.message || `media error ${el.error.code}` : 'unknown error'} (${mediaPath(media)})`;
      console.error('EditRush video element error', this.lastError);
      this.emitState();
    });
    el.src = media.url;
    v = { el, mediaUrl: media.url, lastUse: performance.now() };
    this.videos.set(clip.id, v);
    return v;
  }
}

module.exports = { PlaybackController };
