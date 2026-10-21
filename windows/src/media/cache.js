'use strict';
// Decoded media for the UI and engine: still images, poster frames, filmstrips, waveforms and
// audio buffers. Replaces AssetCache.swift, ThumbnailCache.swift and WaveformCache.swift.
// Entries are keyed by media url; failures are remembered until `retryFailed()` (called when the
// window regains focus, so a reconnected drive reloads).

const fs = require('fs');
const path = require('path');
const ff = require('./ffmpeg');
const { mediaPath } = require('../core/store');

const SAMPLE_RATE = 48000;
const WAVE_BUCKETS_PER_SECOND = 100;
const FILMSTRIP_FRAMES = 24;

class MediaCache {
  constructor() {
    this.entries = new Map(); // key -> { promise, value, error }
    this.listeners = [];
  }

  onChange(fn) { this.listeners.push(fn); }
  changed() { for (const fn of this.listeners) fn(); }

  /// Starts (once) loading `kind` for `media`; returns the value when ready, else null.
  /// `kind`: 'still' | 'poster' | 'filmstrip' | 'waveform' | 'audio'.
  get(kind, media) {
    const key = `${kind}|${media.url}`;
    let e = this.entries.get(key);
    if (!e) {
      e = { value: null, error: null };
      this.entries.set(key, e);
      e.promise = this.load(kind, media).then(v => { e.value = v; this.changed(); return v; },
        err => { e.error = err; console.error(`EditRush: loading ${kind} for ${media.name} failed:`, err); this.changed(); return null; });
    }
    return e.value;
  }

  /// Promise for `kind` of `media` (null when it failed).
  ready(kind, media) {
    this.get(kind, media);
    return this.entries.get(`${kind}|${media.url}`).promise;
  }

  error(kind, media) {
    const e = this.entries.get(`${kind}|${media.url}`);
    return e ? e.error : null;
  }

  /// Forgets failed entries so they load again.
  retryFailed() {
    let any = false;
    for (const [k, e] of this.entries) if (e.error) { this.entries.delete(k); any = true; }
    if (any) this.changed();
  }

  /// Forgets everything about `url` (after relinking).
  forget(url) {
    for (const k of [...this.entries.keys()]) if (k.endsWith(`|${url}`)) this.entries.delete(k);
  }

  load(kind, media) {
    const file = mediaPath(media);
    if (!fs.existsSync(file)) return Promise.reject(new Error(`missing file ${file}`));
    switch (kind) {
      case 'still': return still(file, media);
      case 'poster': return media.kind === 'image' ? still(file, media) : poster(file, media);
      case 'filmstrip': return filmstrip(file, media);
      case 'waveform': return waveform(file, media);
      case 'audio': return audioBuffer(file);
      default: return Promise.reject(new Error(`unknown cache kind ${kind}`));
    }
  }
}

function loadImage(url) {
  return new Promise((resolve, reject) => {
    const img = new Image();
    img.decoding = 'async';
    img.onload = () => resolve(img);
    img.onerror = () => reject(new Error(`could not decode image ${url}`));
    img.src = url;
  });
}

/// Formats Chromium cannot display; ffmpeg decodes them to PNG first.
const CONVERTED_IMAGE_EXTENSIONS = new Set(['tif', 'tiff', 'heic', 'heif']);
/// Long-side limit for converted stills (a 45 MP phone photo becomes 8192 px wide).
const MAX_CONVERTED_DIMENSION = 8192;

function still(file, media) {
  const ext = path.extname(file).slice(1).toLowerCase();
  return CONVERTED_IMAGE_EXTENSIONS.has(ext) ? convertedImage(file) : loadImage(media.url);
}

/// Decodes `file` with ffmpeg (which applies HEIC rotation and grid tiles) into an <img>.
async function convertedImage(file) {
  const m = MAX_CONVERTED_DIMENSION;
  const { stdout } = await ff.run('ffmpeg', ['-v', 'error', '-i', file, '-frames:v', '1',
    '-vf', `scale='min(${m},iw)':'min(${m},ih)':force_original_aspect_ratio=decrease,format=rgba`,
    '-f', 'image2pipe', '-vcodec', 'png', '-compression_level', '1', 'pipe:1']);
  if (!stdout.length) throw new Error(`ffmpeg decoded no image from ${file}`);
  const url = URL.createObjectURL(new Blob([stdout], { type: 'image/png' }));
  return loadImage(url);
}

async function jpegToImage(buffer) {
  const blob = new Blob([buffer], { type: 'image/jpeg' });
  return createImageBitmap(blob);
}

async function poster(file, media) {
  const t = Math.min(1, media.duration / 3);
  const { stdout } = await ff.run('ffmpeg', ['-v', 'error', '-ss', t.toFixed(3), '-i', file, '-frames:v', '1',
    '-vf', 'scale=320:-2', '-f', 'image2pipe', '-vcodec', 'mjpeg', '-q:v', '4', 'pipe:1']);
  if (!stdout.length) throw new Error('ffmpeg produced no poster frame');
  return jpegToImage(stdout);
}

/// { image, frames, interval }: `frames` thumbnails side by side; frame i shows source time i * interval.
async function filmstrip(file, media) {
  // One keyframe-seek per thumbnail: decoding the whole file is far too slow for long recordings.
  const frames = FILMSTRIP_FRAMES;
  const interval = media.duration / frames;
  const thumbs = [];
  for (let i = 0; i < frames; i++) {
    const t = Math.min(media.duration - 0.05, (i + 0.5) * interval);
    const { stdout } = await ff.run('ffmpeg', ['-v', 'error', '-ss', t.toFixed(3), '-i', file, '-an', '-frames:v', '1',
      '-vf', 'scale=-2:72', '-f', 'image2pipe', '-vcodec', 'mjpeg', '-q:v', '5', 'pipe:1']);
    if (!stdout.length) throw new Error(`ffmpeg produced no filmstrip frame at ${t.toFixed(2)}s`);
    thumbs.push(await jpegToImage(stdout));
  }
  const w = thumbs[0].width, hgt = thumbs[0].height;
  const strip = new OffscreenCanvas(w * frames, hgt);
  const ctx = strip.getContext('2d');
  thumbs.forEach((b, i) => ctx.drawImage(b, i * w, 0, w, hgt));
  return { image: strip.transferToImageBitmap(), frames, interval };
}

/// { peaks: Float32Array (max |sample| per bucket), bucketsPerSecond }.
async function waveform(file) {
  const rate = 8000;
  const { stdout } = await ff.run('ffmpeg', ['-v', 'error', '-i', file, '-vn', '-ac', '1', '-ar', String(rate), '-f', 'f32le', 'pipe:1']);
  const samples = new Float32Array(stdout.buffer, stdout.byteOffset, Math.floor(stdout.length / 4));
  const per = rate / WAVE_BUCKETS_PER_SECOND;
  const peaks = new Float32Array(Math.ceil(samples.length / per));
  for (let b = 0; b < peaks.length; b++) {
    let m = 0;
    const end = Math.min(samples.length, (b + 1) * per);
    for (let i = b * per; i < end; i++) { const v = Math.abs(samples[i]); if (v > m) m = v; }
    peaks[b] = m;
  }
  return { peaks, bucketsPerSecond: WAVE_BUCKETS_PER_SECOND };
}

/// Stereo AudioBuffer of the whole file at 48 kHz.
async function audioBuffer(file) {
  const { stdout } = await ff.run('ffmpeg', ['-v', 'error', '-i', file, '-vn', '-ac', '2', '-ar', String(SAMPLE_RATE), '-f', 'f32le', 'pipe:1'], { maxBuffer: 2 ** 31 });
  const frames = Math.floor(stdout.length / 8);
  if (!frames) throw new Error('ffmpeg decoded no audio');
  const interleaved = new Float32Array(stdout.buffer.slice(stdout.byteOffset, stdout.byteOffset + frames * 8));
  const buf = new AudioBuffer({ numberOfChannels: 2, length: frames, sampleRate: SAMPLE_RATE });
  const l = buf.getChannelData(0), r = buf.getChannelData(1);
  for (let i = 0; i < frames; i++) { l[i] = interleaved[2 * i]; r[i] = interleaved[2 * i + 1]; }
  return buf;
}

module.exports = { MediaCache, SAMPLE_RATE };
