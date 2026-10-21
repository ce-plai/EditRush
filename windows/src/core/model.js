'use strict';
// Project model. Mirrors Sources/EditRushCore/Model/Project.swift and writes the same JSON,
// so .editrush files open in both the macOS and the Windows build.
//
// Conventions (shared contract):
// * All times are seconds (numbers). Edit operations quantize to canvas frames.
// * Canvas space: pixels of the project canvas, origin TOP-LEFT, +y DOWN.
// * Video tracks render in the order they appear in `project.tracks` (first = bottom layer, "V1").
//   The timeline shows video tracks in reverse order (top row = top layer) above the audio tracks.
// * Video tracks hold video, image and text clips. Audio tracks hold audio clips only.
//   A video clip's embedded audio plays from the video clip itself until it is detached.
//   `audioMuted` silences a clip's audio on any track.
// * Clips on one track never overlap and `track.clips` is kept sorted by `start`.
// * Fades multiply a clip's opacity (video) and volume (audio) by `fadeFactor(clip, t)`.

const crypto = require('crypto');

const FILE_EXTENSION = 'editrush';
const CURRENT_VERSION = 1;

function uuid() { return crypto.randomUUID().toUpperCase(); }

const MediaKinds = ['video', 'audio', 'image'];
const FilterPresets = ['none', 'vivid', 'warm', 'cool', 'mono', 'noir', 'sepia', 'chrome', 'fade', 'instant',
  'process', 'tonal', 'transfer', 'blur', 'sharpen', 'comic'];
const FilterNames = {
  none: 'None', vivid: 'Vivid', warm: 'Warm', cool: 'Cool', mono: 'Mono', noir: 'Noir', sepia: 'Sepia',
  chrome: 'Chrome', fade: 'Faded', instant: 'Instant', process: 'Process', tonal: 'Tonal', transfer: 'Transfer',
  blur: 'Soft Blur', sharpen: 'Sharpen', comic: 'Comic',
};

function rgba(r, g, b, a = 1) { return { r, g, b, a }; }
const BLACK = () => rgba(0, 0, 0);
const WHITE = () => rgba(1, 1, 1);
const CLEAR = () => rgba(0, 0, 0, 0);

function defaultTransform() {
  return { scale: 1, offsetX: 0, offsetY: 0, rotation: 0, opacity: 1, flipHorizontal: false, flipVertical: false, fitMode: 'fit' };
}
function isIdentityTransform(t) {
  const d = defaultTransform();
  return Object.keys(d).every(k => t[k] === d[k]);
}
function defaultColor() {
  return { exposure: 0, brightness: 0, contrast: 1, saturation: 1, temperature: 0, vignette: 0 };
}
function isIdentityColor(c) {
  const d = defaultColor();
  return Object.keys(d).every(k => c[k] === d[k]);
}

/// Windows default font: the macOS default "Helvetica Neue" is not installed on Windows.
const DEFAULT_FONT = 'Segoe UI';

function defaultTextStyle(text = 'Title') {
  return {
    text, fontFamily: DEFAULT_FONT, isBold: true, isItalic: false, fontSize: 0.1, color: WHITE(),
    backgroundColor: CLEAR(), alignment: 'center', shadow: true, outlineWidth: 0, outlineColor: BLACK(),
  };
}

function makeClip({ mediaID = null, start, duration, sourceIn = 0, text = null }) {
  const c = {
    id: uuid(), start, duration, sourceIn,
    transform: defaultTransform(), color: defaultColor(), filter: 'none', filterIntensity: 1,
    fadeIn: 0, fadeOut: 0, volume: 1, audioMuted: false,
  };
  if (mediaID) c.mediaID = mediaID;
  if (text) c.text = text;
  return c;
}

const clipEnd = c => c.start + c.duration;
const clipSourceOut = c => c.sourceIn + c.duration;
const isText = c => c.text != null;
const clipContains = (c, t) => t >= c.start && t < c.start + c.duration;

/// Opacity / volume multiplier from fades at timeline time `t` (0...1).
function fadeFactor(c, t) {
  if (!clipContains(c, t)) return 0;
  let f = 1;
  if (c.fadeIn > 0) f = Math.min(f, (t - c.start) / c.fadeIn);
  if (c.fadeOut > 0) f = Math.min(f, (clipEnd(c) - t) / c.fadeOut);
  return Math.max(0, Math.min(1, f));
}

function makeTrack(kind) {
  return { id: uuid(), kind, clips: [], isMuted: false, isHidden: false, isLocked: false };
}
const trackEnd = t => t.clips.reduce((m, c) => Math.max(m, clipEnd(c)), 0);
/// `kind` null = text clip.
function trackAccepts(track, kind) {
  return track.kind === 'video' ? kind !== 'audio' : kind === 'audio';
}

function defaultCanvas(width = 1920, height = 1080, frameRate = 30) {
  return { width, height, frameRate, backgroundColor: BLACK() };
}
const frameDuration = canvas => 1 / Math.max(1, canvas.frameRate);
/// Rounds `t` to the nearest frame boundary.
const quantize = (canvas, t) => Math.round(t * canvas.frameRate) / canvas.frameRate;

const CanvasPresets = [
  { name: 'Landscape 16:9 (1080p)', width: 1920, height: 1080 },
  { name: 'Landscape 16:9 (4K)', width: 3840, height: 2160 },
  { name: 'Portrait 9:16', width: 1080, height: 1920 },
  { name: 'Square 1:1', width: 1080, height: 1080 },
  { name: 'Social 4:5', width: 1080, height: 1350 },
];

function emptyProject() {
  return {
    version: CURRENT_VERSION, name: 'Untitled', canvas: defaultCanvas(), media: [],
    tracks: [makeTrack('video'), makeTrack('video'), makeTrack('audio'), makeTrack('audio')],
  };
}

const projectDuration = p => p.tracks.reduce((m, t) => Math.max(m, trackEnd(t)), 0);
const findMedia = (p, id) => (id ? p.media.find(m => m.id === id) || null : null);
const trackIndex = (p, id) => p.tracks.findIndex(t => t.id === id);

/// { track, clip } indices of a clip, or null.
function locate(p, clipID) {
  for (let ti = 0; ti < p.tracks.length; ti++) {
    const ci = p.tracks[ti].clips.findIndex(c => c.id === clipID);
    if (ci >= 0) return { track: ti, clip: ci };
  }
  return null;
}
function findClip(p, id) {
  const l = locate(p, id);
  return l ? p.tracks[l.track].clips[l.clip] : null;
}
function trackContaining(p, clipID) {
  const l = locate(p, clipID);
  return l ? p.tracks[l.track] : null;
}
/// 1-based display name, e.g. "V1", "A2".
function displayName(p, trackID) {
  const t = p.tracks.find(x => x.id === trackID);
  if (!t) return '?';
  const same = p.tracks.filter(x => x.kind === t.kind);
  return (t.kind === 'video' ? 'V' : 'A') + (same.findIndex(x => x.id === trackID) + 1);
}

// MARK: - Geometry shared by the compositor and the preview overlay

/// Content size in canvas pixels before the user's scale (content fit/filled to the canvas).
function baseSize(content, canvas, fit) {
  if (!(content.width > 0 && content.height > 0)) return { width: canvas.width, height: canvas.height };
  const sx = canvas.width / content.width, sy = canvas.height / content.height;
  const s = fit === 'fit' ? Math.min(sx, sy) : Math.max(sx, sy);
  return { width: content.width * s, height: content.height * s };
}

/// The clip's displayed rectangle BEFORE rotation, in canvas space (top-left origin, +y down).
/// Text clips are not fit to the canvas; their base size is the rendered text size.
function clipRect(content, canvas, transform, text) {
  const base = text ? content : baseSize(content, canvas, transform.fitMode);
  const w = base.width * transform.scale, h = base.height * transform.scale;
  const cx = canvas.width / 2 + transform.offsetX * canvas.width;
  const cy = canvas.height / 2 + transform.offsetY * canvas.height;
  return { x: cx - w / 2, y: cy - h / 2, width: w, height: h };
}

// MARK: - File paths <-> file URLs (the Swift build stores URL.absoluteString)

function pathToFileURL(p) { return require('url').pathToFileURL(p).href; }
function fileURLToPath(u) { return require('url').fileURLToPath(u); }

// MARK: - Decoding (.editrush JSON)

class ProjectFileError extends Error {}

/// Validates and returns a project decoded from JSON text. Throws ProjectFileError with the
/// path of the first problem, like the Swift decoder.
function decodeProject(text) {
  let raw;
  try { raw = JSON.parse(text); } catch { throw new ProjectFileError("The file isn't a valid EditRush project (not JSON)."); }
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) {
    throw new ProjectFileError("The file isn't a valid EditRush project (not JSON).");
  }
  if (typeof raw.version === 'number' && raw.version > CURRENT_VERSION) {
    throw new ProjectFileError(`This project was saved by a newer version of EditRush (format ${raw.version}; this version reads up to ${CURRENT_VERSION}). Please update EditRush to open it.`);
  }
  const bad = (path, what) => { throw new ProjectFileError(`The file isn't a valid EditRush project (${what} at ${path}).`); };
  const num = (o, k, path) => { if (typeof o[k] !== 'number') bad(`${path}.${k}`, o[k] === undefined ? `missing ${k}` : 'expected a number'); return o[k]; };
  const str = (o, k, path) => { if (typeof o[k] !== 'string') bad(`${path}.${k}`, o[k] === undefined ? `missing ${k}` : 'expected a string'); return o[k]; };
  const bool = (o, k, path) => { if (typeof o[k] !== 'boolean') bad(`${path}.${k}`, o[k] === undefined ? `missing ${k}` : 'expected a boolean'); return o[k]; };
  const obj = (o, k, path) => { if (!o[k] || typeof o[k] !== 'object') bad(`${path}.${k}`, `missing ${k}`); return o[k]; };
  const arr = (o, k, path) => { if (!Array.isArray(o[k])) bad(`${path}.${k}`, `missing ${k}`); return o[k]; };
  const oneOf = (o, k, path, values) => { const v = str(o, k, path); if (!values.includes(v)) bad(`${path}.${k}`, `unknown value "${v}"`); return v; };
  const color = (o, k, path) => { const c = obj(o, k, path); const p = `${path}.${k}`; return rgba(num(c, 'r', p), num(c, 'g', p), num(c, 'b', p), num(c, 'a', p)); };

  const p = { version: num(raw, 'version', 'root'), name: str(raw, 'name', 'root') };
  const cv = obj(raw, 'canvas', 'root');
  p.canvas = { width: num(cv, 'width', 'canvas'), height: num(cv, 'height', 'canvas'), frameRate: num(cv, 'frameRate', 'canvas'),
    backgroundColor: color(cv, 'backgroundColor', 'canvas') };
  p.media = arr(raw, 'media', 'root').map((m, i) => {
    const path = `media.${i}`;
    return { id: str(m, 'id', path), url: str(m, 'url', path), name: str(m, 'name', path), kind: oneOf(m, 'kind', path, MediaKinds),
      duration: num(m, 'duration', path), pixelWidth: num(m, 'pixelWidth', path), pixelHeight: num(m, 'pixelHeight', path),
      frameRate: num(m, 'frameRate', path), hasAudio: bool(m, 'hasAudio', path) };
  });
  p.tracks = arr(raw, 'tracks', 'root').map((t, ti) => {
    const path = `tracks.${ti}`;
    const track = { id: str(t, 'id', path), kind: oneOf(t, 'kind', path, ['video', 'audio']), isMuted: bool(t, 'isMuted', path),
      isHidden: bool(t, 'isHidden', path), isLocked: bool(t, 'isLocked', path) };
    track.clips = arr(t, 'clips', path).map((c, ci) => {
      const cp = `${path}.clips.${ci}`;
      const xf = obj(c, 'transform', cp), xp = `${cp}.transform`;
      const co = obj(c, 'color', cp), cop = `${cp}.color`;
      const clip = {
        id: str(c, 'id', cp), start: num(c, 'start', cp), duration: num(c, 'duration', cp), sourceIn: num(c, 'sourceIn', cp),
        transform: { scale: num(xf, 'scale', xp), offsetX: num(xf, 'offsetX', xp), offsetY: num(xf, 'offsetY', xp),
          rotation: num(xf, 'rotation', xp), opacity: num(xf, 'opacity', xp), flipHorizontal: bool(xf, 'flipHorizontal', xp),
          flipVertical: bool(xf, 'flipVertical', xp), fitMode: oneOf(xf, 'fitMode', xp, ['fit', 'fill']) },
        color: { exposure: num(co, 'exposure', cop), brightness: num(co, 'brightness', cop), contrast: num(co, 'contrast', cop),
          saturation: num(co, 'saturation', cop), temperature: num(co, 'temperature', cop), vignette: num(co, 'vignette', cop) },
        filter: oneOf(c, 'filter', cp, FilterPresets), filterIntensity: num(c, 'filterIntensity', cp),
        fadeIn: num(c, 'fadeIn', cp), fadeOut: num(c, 'fadeOut', cp), volume: num(c, 'volume', cp), audioMuted: bool(c, 'audioMuted', cp),
      };
      if (c.mediaID != null) clip.mediaID = str(c, 'mediaID', cp);
      if (c.label != null) clip.label = str(c, 'label', cp);
      if (c.text != null) {
        const s = c.text, sp = `${cp}.text`;
        clip.text = { text: str(s, 'text', sp), fontFamily: str(s, 'fontFamily', sp), isBold: bool(s, 'isBold', sp),
          isItalic: bool(s, 'isItalic', sp), fontSize: num(s, 'fontSize', sp), color: color(s, 'color', sp),
          backgroundColor: color(s, 'backgroundColor', sp), alignment: oneOf(s, 'alignment', sp, ['left', 'center', 'right']),
          shadow: bool(s, 'shadow', sp), outlineWidth: num(s, 'outlineWidth', sp), outlineColor: color(s, 'outlineColor', sp) };
      }
      return clip;
    });
    return track;
  });
  return p;
}

/// Pretty JSON with sorted keys, like the Swift encoder (`.prettyPrinted, .sortedKeys`).
function encodeProject(p) {
  const sortKeys = v => {
    if (Array.isArray(v)) return v.map(sortKeys);
    if (v && typeof v === 'object') {
      const o = {};
      for (const k of Object.keys(v).sort()) if (v[k] !== undefined && v[k] !== null) o[k] = sortKeys(v[k]);
      return o;
    }
    return v;
  };
  return JSON.stringify(sortKeys(p), null, 2);
}

const clone = v => structuredClone(v);

/// Deep structural equality for plain JSON values.
function deepEqual(a, b) {
  if (a === b) return true;
  if (typeof a !== typeof b || a === null || b === null || typeof a !== 'object') return false;
  if (Array.isArray(a) !== Array.isArray(b)) return false;
  if (Array.isArray(a)) {
    if (a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++) if (!deepEqual(a[i], b[i])) return false;
    return true;
  }
  const ka = Object.keys(a).filter(k => a[k] !== undefined), kb = Object.keys(b).filter(k => b[k] !== undefined);
  if (ka.length !== kb.length) return false;
  for (const k of ka) if (!deepEqual(a[k], b[k])) return false;
  return true;
}

module.exports = {
  FILE_EXTENSION, CURRENT_VERSION, uuid, MediaKinds, FilterPresets, FilterNames, rgba, BLACK, WHITE, CLEAR,
  defaultTransform, isIdentityTransform, defaultColor, isIdentityColor, DEFAULT_FONT, defaultTextStyle, makeClip,
  clipEnd, clipSourceOut, isText, clipContains, fadeFactor, makeTrack, trackEnd, trackAccepts, defaultCanvas,
  frameDuration, quantize, CanvasPresets, emptyProject, projectDuration, findMedia, trackIndex, locate, findClip,
  trackContaining, displayName, baseSize, clipRect, pathToFileURL, fileURLToPath, ProjectFileError, decodeProject,
  encodeProject, clone, deepEqual,
};
