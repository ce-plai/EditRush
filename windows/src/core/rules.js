'use strict';
// Pure timeline editing rules. Port of Sources/EditRushCore/Store/TimelineRules.swift.
// They keep the track invariants: frame-quantized times, sorted non-overlapping clips,
// >= 1 frame durations, valid property ranges.

const M = require('./model');

const EPS = 1e-6;

/// True when [start, start + duration) overlaps no clip on `track` other than `excluding`.
function isFree(track, start, duration, excluding = new Set()) {
  const end = start + duration;
  return !track.clips.some(c => !excluding.has(c.id) && c.start < end - EPS && start < M.clipEnd(c) - EPS);
}

/// The start >= 0 closest to `desired` where a clip of `duration` fits without overlapping
/// clips other than `excluding`. Ties prefer the earlier start; the space after the last clip always fits.
function nearestFreeStart(track, duration, desired, excluding = new Set()) {
  desired = Math.max(0, desired);
  let best = null;
  const consider = (lo, hi) => {
    if (!(hi >= lo - EPS)) return;
    const candidate = Math.min(Math.max(desired, lo), Math.max(lo, hi));
    if (best === null || Math.abs(candidate - desired) < Math.abs(best - desired) - EPS) best = candidate;
  };
  let gapStart = 0;
  for (const c of [...track.clips].sort((a, b) => a.start - b.start)) {
    if (excluding.has(c.id)) continue;
    consider(gapStart, c.start - duration);
    gapStart = Math.max(gapStart, M.clipEnd(c));
  }
  consider(gapStart, Infinity);
  return best ?? gapStart;
}

/// Automatic placement (no explicit target track) may use unlocked, visible tracks.
const allowsAutomaticPlacement = t => !t.isLocked && !t.isHidden;

/// Rounds `t` down / up to a frame boundary (tolerating floating-point noise).
function floorFrame(t, canvas) { const fps = Math.max(1, canvas.frameRate); return Math.floor(t * fps + 1e-6) / fps; }
function ceilFrame(t, canvas) { const fps = Math.max(1, canvas.frameRate); return Math.ceil(t * fps - 1e-6) / fps; }

/// True for clips that play a time range of their media (video and audio).
function playsSourceRange(clip, p) {
  if (!clip.mediaID) return false;
  const m = M.findMedia(p, clip.mediaID);
  return !m || m.kind !== 'image';
}

/// Source duration bounding a clip's media range, or null when unbounded.
function sourceDuration(clip, p) {
  const m = M.findMedia(p, clip.mediaID);
  if (!m || m.kind === 'image' || !(m.duration > 0)) return null;
  return m.duration;
}

function clamp(v, lo, hi, d) {
  if (!Number.isFinite(v)) return d;
  return Math.min(hi, Math.max(lo, v));
}

/// Clamps every clip property to its valid range (mutates `c`).
function normalize(c, p) {
  const canvas = p.canvas;
  const frame = M.frameDuration(canvas);
  c.start = Number.isFinite(c.start) ? Math.max(0, M.quantize(canvas, c.start)) : 0;
  c.duration = Number.isFinite(c.duration) ? Math.max(frame, M.quantize(canvas, c.duration)) : frame;
  if (playsSourceRange(c, p)) {
    c.sourceIn = Number.isFinite(c.sourceIn) ? Math.max(0, c.sourceIn) : 0;
    const total = sourceDuration(c, p);
    if (total !== null) {
      c.sourceIn = Math.min(c.sourceIn, Math.max(0, total - frame));
      c.duration = Math.max(frame, Math.min(c.duration, floorFrame(total - c.sourceIn, canvas)));
    }
  } else {
    c.sourceIn = 0;
  }
  const t = c.transform;
  t.opacity = clamp(t.opacity, 0, 1, 1);
  t.scale = clamp(t.scale, 0.02, 20, 1);
  t.offsetX = clamp(t.offsetX, -100, 100, 0);
  t.offsetY = clamp(t.offsetY, -100, 100, 0);
  t.rotation = clamp(t.rotation, -36000, 36000, 0);
  c.volume = clamp(c.volume, 0, 2, 1);
  c.filterIntensity = clamp(c.filterIntensity, 0, 1, 1);
  const col = c.color;
  col.exposure = clamp(col.exposure, -2, 2, 0);
  col.brightness = clamp(col.brightness, -1, 1, 0);
  col.contrast = clamp(col.contrast, 0.25, 2, 1);
  col.saturation = clamp(col.saturation, 0, 2, 1);
  col.temperature = clamp(col.temperature, -1, 1, 0);
  col.vignette = clamp(col.vignette, 0, 1, 0);
  if (c.text) {
    c.text.fontSize = clamp(c.text.fontSize, 0.01, 0.6, 0.1);
    c.text.outlineWidth = clamp(c.text.outlineWidth, 0, 1, 0);
  }
  clampFades(c);
}

/// Fades >= 0 with fadeIn + fadeOut <= duration (both scaled down proportionally when too long).
function clampFades(c) {
  let fin = Number.isFinite(c.fadeIn) ? Math.max(0, c.fadeIn) : 0;
  let fout = Number.isFinite(c.fadeOut) ? Math.max(0, c.fadeOut) : 0;
  const total = fin + fout;
  if (total > c.duration) { const k = c.duration / total; fin *= k; fout *= k; }
  c.fadeIn = fin; c.fadeOut = fout;
}

function sortClips(p, ti) { p.tracks[ti].clips.sort((a, b) => a.start - b.start); }

/// Inserts a new track: video tracks go above the existing video tracks, audio tracks are appended.
function insertTrack(kind, p) {
  const track = M.makeTrack(kind);
  if (kind === 'video') {
    let last = -1;
    p.tracks.forEach((t, i) => { if (t.kind === 'video') last = i; });
    p.tracks.splice(last + 1, 0, track);
    return last + 1;
  }
  p.tracks.push(track);
  return p.tracks.length - 1;
}

/// Picks the track for a new clip and inserts it. Returns the track index.
/// The preferred track is used when compatible and unlocked (the clip moves to its nearest free
/// start there), else the first visible, unlocked compatible track that is free (bottom-up, or
/// top-down with `topmostFirst`), else a new track.
function place(clip, kind, preferredTrack, topmostFirst, p) {
  let ti;
  const pi = preferredTrack ? M.trackIndex(p, preferredTrack) : -1;
  if (pi >= 0 && p.tracks[pi].kind === kind && !p.tracks[pi].isLocked) {
    clip.start = M.quantize(p.canvas, nearestFreeStart(p.tracks[pi], clip.duration, clip.start));
    ti = pi;
  } else {
    let candidates = p.tracks.map((t, i) => i).filter(i => p.tracks[i].kind === kind && allowsAutomaticPlacement(p.tracks[i]));
    if (topmostFirst) candidates.reverse();
    const found = candidates.find(i => isFree(p.tracks[i], clip.start, clip.duration));
    ti = found !== undefined ? found : insertTrack(kind, p);
  }
  p.tracks[ti].clips.push(clip);
  sortClips(p, ti);
  return ti;
}

/// Sorted, disjoint ranges {lo, hi} of shifts d for which every clip of `group` ([{track, clip}]),
/// moved by d on its track, stays >= 0 and overlaps no clip outside `excluding`.
function validShifts(group, excluding, p) {
  const gapsByTrack = new Map();
  let result = [{ lo: -Infinity, hi: Infinity }];
  for (const { track: ti, clip: c } of group) {
    let gaps = gapsByTrack.get(ti);
    if (!gaps) {
      gaps = [];
      let gapStart = 0;
      for (const o of p.tracks[ti].clips) {
        if (excluding.has(o.id)) continue;
        if (o.start > gapStart) gaps.push({ lo: gapStart, hi: o.start });
        gapStart = Math.max(gapStart, M.clipEnd(o));
      }
      gaps.push({ lo: gapStart, hi: Infinity });
      gapsByTrack.set(ti, gaps);
    }
    const fits = [];
    for (const g of gaps) {
      const lo = g.lo - c.start, hi = g.hi - M.clipEnd(c);
      if (hi >= lo - EPS) fits.push({ lo, hi: Math.max(lo, hi) });
    }
    result = intersect(result, fits);
    if (!result.length) break;
  }
  return result;
}

function intersect(a, b) {
  const r = [];
  let i = 0, j = 0;
  while (i < a.length && j < b.length) {
    const lo = Math.max(a[i].lo, b[j].lo), hi = Math.min(a[i].hi, b[j].hi);
    if (hi >= lo - EPS) r.push({ lo, hi: Math.max(lo, hi) });
    if (a[i].hi < b[j].hi) i++; else j++;
  }
  return r;
}

/// The value in `ranges` closest to `d` (ties prefer the smaller value), or null when empty.
function nearest(d, ranges) {
  let best = null;
  for (const r of ranges) {
    const candidate = Math.min(Math.max(d, r.lo), r.hi);
    if (best === null || Math.abs(candidate - d) < Math.abs(best - d) - EPS) best = candidate;
  }
  return best;
}

/// True when `t` is at least one frame inside the clip on both sides.
function canSplit(c, t, frame) { return t - c.start >= frame - EPS && M.clipEnd(c) - t >= frame - EPS; }

/// Splits clip `id` at the frame-quantized time `t`; returns the right part's id or null.
function split(id, t, p) {
  const l = M.locate(p, id);
  if (!l || p.tracks[l.track].isLocked) return null;
  const canvas = p.canvas;
  t = M.quantize(canvas, t);
  const original = p.tracks[l.track].clips[l.clip];
  if (!canSplit(original, t, M.frameDuration(canvas))) return null;
  const left = M.clone(original);
  left.duration = M.quantize(canvas, t - original.start);
  left.fadeOut = 0;
  clampFades(left);
  const right = M.clone(original);
  right.id = M.uuid();
  right.start = t;
  right.duration = M.quantize(canvas, M.clipEnd(original) - t);
  if (playsSourceRange(original, p)) right.sourceIn = original.sourceIn + left.duration;
  right.fadeIn = 0;
  clampFades(right);
  p.tracks[l.track].clips[l.clip] = left;
  p.tracks[l.track].clips.splice(l.clip + 1, 0, right);
  return right.id;
}

/// True when `b` continues `a` seamlessly: same media and continuous source range
/// (images and identical text styles are always continuous).
function continues(a, b, p, frame) {
  if (!(Math.abs(M.clipEnd(a) - b.start) < frame / 2)) return false;
  if (a.text) return !a.mediaID && !b.mediaID && M.deepEqual(a.text, b.text);
  if (b.text || !a.mediaID || a.mediaID !== b.mediaID) return false;
  if (!playsSourceRange(a, p)) return true;
  return Math.abs(M.clipSourceOut(a) - b.sourceIn) < frame / 2;
}

module.exports = {
  EPS, isFree, nearestFreeStart, allowsAutomaticPlacement, floorFrame, ceilFrame, playsSourceRange, sourceDuration,
  normalize, clampFades, sortClips, insertTrack, place, validShifts, intersect, nearest, canSplit, split, continues,
};
