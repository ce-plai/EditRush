'use strict';
// Exports a project to an MP4 / MOV file. Replaces Exporter.swift.
//
// Frames are drawn by the same compositor as the preview. Video clips are decoded by one ffmpeg
// process per clip (raw RGBA at the canvas frame rate, already at display size); the composed
// frames are piped into an ffmpeg encoder together with the audio mix rendered by an
// OfflineAudioContext. The movie is written to a temporary file beside the destination, which
// replaces the destination only when the export succeeds.

const fs = require('fs');
const path = require('path');
const M = require('../core/model');
const ff = require('../media/ffmpeg');
const compositor = require('./compositor');
const audio = require('./audio');
const { mediaPath } = require('../core/store');

const Resolutions = { p720: '720p', p1080: '1080p', p2160: '4K', canvas: 'Project Size' };
const Codecs = { h264: 'H.264', hevc: 'HEVC (H.265)' };
const Containers = { mp4: 'MP4', mov: 'MOV' };

function defaultSettings() { return { resolution: 'p1080', codec: 'h264', container: 'mp4' }; }

/// Output pixel size: the SHORT side matches the resolution, aspect kept, even dimensions.
function outputSize(settings, canvas) {
  const short = { p720: 720, p1080: 1080, p2160: 2160 }[settings.resolution];
  if (!short) return { width: canvas.width - (canvas.width % 2), height: canvas.height - (canvas.height % 2) };
  const s = short / Math.min(canvas.width, canvas.height);
  const even = v => Math.round(v / 2) * 2;
  return { width: even(canvas.width * s), height: even(canvas.height * s) };
}

/// ffmpeg rate string (exact for NTSC 1000/1001 rates).
function rateString(fps) {
  const r = Math.round(fps);
  if (Math.abs(fps - r) < 0.001) return String(r);
  const ntsc = Math.round(fps * 1001 / 1000);
  if (Math.abs(fps - ntsc * 1000 / 1001) < 0.001) return `${ntsc * 1000}/1001`;
  return fps.toFixed(6);
}

/// Reads fixed-size frames from a process's stdout.
class FrameReader {
  constructor(stream, frameBytes) {
    this.stream = stream;
    this.frameBytes = frameBytes;
    this.chunks = [];
    this.queued = 0;
    this.ended = false;
    this.waiter = null;
    stream.on('data', d => {
      this.chunks.push(d);
      this.queued += d.length;
      if (this.queued > frameBytes * 4) stream.pause();
      this.wake();
    });
    stream.on('end', () => { this.ended = true; this.wake(); });
  }
  wake() { if (this.waiter) { const w = this.waiter; this.waiter = null; w(); } }
  /// Next frame as a Buffer, or null at end of stream.
  async next() {
    while (this.queued < this.frameBytes) {
      if (this.ended) return null;
      if (this.stream.isPaused()) this.stream.resume();
      await new Promise(r => { this.waiter = r; });
    }
    const frame = Buffer.allocUnsafe(this.frameBytes);
    let filled = 0;
    while (filled < this.frameBytes) {
      const c = this.chunks[0];
      const take = Math.min(c.length, this.frameBytes - filled);
      c.copy(frame, filled, 0, take);
      filled += take;
      if (take === c.length) this.chunks.shift(); else this.chunks[0] = c.subarray(take);
    }
    this.queued -= this.frameBytes;
    if (this.queued <= this.frameBytes * 2 && this.stream.isPaused()) this.stream.resume();
    return frame;
  }
}

/// Decodes one video clip's frames, in order, at the canvas frame rate and its display size.
class ClipDecoder {
  constructor(clip, media, width, height, fps) {
    this.clip = clip;
    this.width = width;
    this.height = height;
    this.firstFrame = Math.round(clip.start * fps);
    this.delivered = -1;
    this.last = null;
    this.stderr = '';
    this.canvas = document.createElement('canvas');
    this.canvas.width = width; this.canvas.height = height;
    this.ctx = this.canvas.getContext('2d');
    const args = ['-v', 'error', '-ss', clip.sourceIn.toFixed(6), '-i', mediaPath(media), '-an', '-sn',
      '-t', (clip.duration + 1).toFixed(6), '-vf', `fps=${rateString(fps)},scale=${width}:${height}:flags=bicubic`,
      '-f', 'rawvideo', '-pix_fmt', 'rgba', 'pipe:1'];
    this.proc = ff.spawn('ffmpeg', args);
    this.proc.stderr.on('data', d => { this.stderr += d.toString(); });
    this.reader = new FrameReader(this.proc.stdout, width * height * 4);
  }

  /// The frame for timeline frame `n` drawn into this decoder's canvas. Past the end of the
  /// source the last frame is held.
  async frame(n) {
    const k = n - this.firstFrame;
    while (this.delivered < k) {
      const f = await this.reader.next();
      if (!f) break;
      this.last = f;
      this.delivered++;
    }
    if (!this.last) throw new Error(`ffmpeg decoded no frames for a clip (${this.stderr.trim() || 'no error output'})`);
    this.ctx.putImageData(new ImageData(new Uint8ClampedArray(this.last.buffer, this.last.byteOffset, this.last.length), this.width, this.height), 0, 0);
    return this.canvas;
  }

  close() { if (this.proc.exitCode === null) this.proc.kill(); }
}

class Exporter {
  constructor(cache) {
    this.cache = cache;
    this.state = 'idle'; // idle | exporting | finished | failed | cancelled
    this.progress = 0;
    this.remaining = null; // seconds, estimated
    this.message = null;
    this.outputPath = null;
    this.cancelled = false;
    this.listeners = [];
  }

  onChange(fn) { this.listeners.push(fn); }
  emit() { for (const fn of this.listeners) fn(); }
  get isExporting() { return this.state === 'exporting'; }

  cancel() { if (this.isExporting) { this.cancelled = true; this.emit(); } }
  reset() { if (!this.isExporting) { this.state = 'idle'; this.progress = 0; this.remaining = null; this.message = null; this.emit(); } }

  async export(project, outPath, settings) {
    if (this.isExporting) return;
    this.state = 'exporting'; this.progress = 0; this.remaining = null; this.message = null; this.outputPath = outPath; this.cancelled = false;
    this.emit();
    const temp = path.join(path.dirname(outPath), `.${path.basename(outPath, path.extname(outPath))}.exporting-${M.uuid()}${path.extname(outPath)}`);
    const wav = temp + '.wav';
    const decoders = new Map();
    let encoder = null;
    try {
      await this.run(project, settings, temp, wav, decoders, e => { encoder = e; });
      if (this.cancelled) throw new CancelError();
      fs.renameSync(temp, outPath);
      this.progress = 1;
      this.state = 'finished';
    } catch (e) {
      if (e instanceof CancelError || this.cancelled) { this.state = 'cancelled'; } else {
        console.error('EditRush export failed', e);
        this.state = 'failed';
        this.message = e.message;
      }
    } finally {
      for (const d of decoders.values()) d.close();
      if (encoder && encoder.exitCode === null) encoder.kill();
      for (const f of [temp, wav]) if (fs.existsSync(f)) fs.unlinkSync(f);
      this.emit();
    }
  }

  async run(project, settings, temp, wav, decoders, setEncoder) {
    const canvas = project.canvas;
    const size = outputSize(settings, canvas);
    const scale = size.width / canvas.width;
    const fps = canvas.frameRate;
    const duration = M.projectDuration(project);
    if (!(duration > 0)) throw new Error('The project is empty.');
    const frames = Math.max(1, Math.round(duration * fps));

    // Missing media used by visible or audible clips fails the export up front.
    const used = new Map();
    for (const track of project.tracks) {
      for (const clip of track.clips) {
        const m = clip.mediaID ? M.findMedia(project, clip.mediaID) : null;
        if (!m) continue;
        if (track.kind === 'video' && track.isHidden && m.kind !== 'video') continue;
        used.set(m.id, m);
      }
    }
    const missing = [...used.values()].filter(m => !fs.existsSync(mediaPath(m))).map(m => m.name).sort();
    if (missing.length) throw new Error(`Missing media: ${missing.join(', ')}`);

    // Stills and audio first.
    for (const m of used.values()) if (m.kind === 'image') { if (!(await this.cache.ready('still', m))) throw new Error(`Could not read ${m.name}`); }
    const audible = audio.audibleClips(project);
    for (const { media } of audible) if (!(await this.cache.ready('audio', media))) throw new Error(`Could not decode the audio of ${media.name}`);
    if (this.cancelled) throw new CancelError();
    const mix = await audio.renderMix(project, m => this.cache.get('audio', m), 48000);
    fs.writeFileSync(wav, audio.wavBytes(mix));

    const venc = settings.codec === 'hevc'
      ? ['-c:v', 'libx265', '-crf', '20', '-preset', 'medium', '-tag:v', 'hvc1', '-x265-params', 'log-level=error']
      : ['-c:v', 'libx264', '-crf', '17', '-preset', 'medium'];
    const args = ['-v', 'error', '-y', '-f', 'rawvideo', '-pix_fmt', 'rgba', '-s', `${size.width}x${size.height}`,
      '-framerate', rateString(fps), '-i', 'pipe:0', '-i', wav, '-map', '0:v', '-map', '1:a',
      '-vf', 'scale=out_color_matrix=bt709:out_range=tv,format=yuv420p', ...venc,
      '-colorspace', 'bt709', '-color_primaries', 'bt709', '-color_trc', 'bt709',
      '-c:a', 'aac', '-b:a', '192k', ...(settings.container === 'mp4' ? ['-movflags', '+faststart'] : []), temp];
    const enc = ff.spawn('ffmpeg', args);
    setEncoder(enc);
    let encErr = '';
    enc.stderr.on('data', d => { encErr += d.toString(); });
    const encDone = new Promise((resolve, reject) => {
      enc.on('error', reject);
      enc.on('close', code => code === 0 ? resolve() : reject(new Error(`the encoder failed (code ${code}): ${encErr.trim().split(/\r?\n/).slice(-3).join(' | ')}`)));
    });
    encDone.catch(() => {}); // observed below; avoids an unhandled rejection while frames are written
    const write = buf => new Promise((resolve, reject) => {
      if (enc.stdin.destroyed) { reject(new Error(`the encoder stopped: ${encErr.trim()}`)); return; }
      if (enc.stdin.write(buf)) resolve(); else enc.stdin.once('drain', resolve);
    });

    const out = document.createElement('canvas');
    out.width = size.width; out.height = size.height;
    const ctx = out.getContext('2d', { willReadFrequently: true });
    const started = performance.now();
    // Milliseconds spent per stage, logged when the export ends (see `stats`).
    const ms = { decode: 0, compose: 0, readback: 0, write: 0 };
    let mark = performance.now();
    const lap = k => { const now = performance.now(); ms[k] += now - mark; mark = now; };

    for (let n = 0; n < frames; n++) {
      if (this.cancelled) throw new CancelError();
      const t = n / fps;
      const layers = compositor.activeLayers(project, t);
      // Open decoders for clips that start now; close the ones that ended.
      const activeIDs = new Set();
      for (const layer of layers) {
        if (!layer.media || layer.media.kind !== 'video') continue;
        activeIDs.add(layer.clip.id);
        if (!decoders.has(layer.clip.id)) decoders.set(layer.clip.id, this.makeDecoder(project, layer, scale, fps));
      }
      for (const [id, d] of decoders) if (!activeIDs.has(id)) { d.close(); decoders.delete(id); }

      const videoFrames = new Map();
      lap('compose');
      for (const id of activeIDs) videoFrames.set(id, await decoders.get(id).frame(n));
      lap('decode');
      const missingLayers = compositor.composeFrame(ctx, size.width, size.height, project, t, layer => {
        if (layer.media.kind === 'image') {
          const img = this.cache.get('still', layer.media);
          return img ? { image: img, width: img.naturalWidth, height: img.naturalHeight } : null;
        }
        const c = videoFrames.get(layer.clip.id);
        return c ? { image: c, width: c.width, height: c.height } : null;
      });
      if (missingLayers) throw new Error(`a frame at ${t.toFixed(2)}s could not be drawn (${missingLayers} layer(s) unavailable)`);
      lap('compose');
      const data = ctx.getImageData(0, 0, size.width, size.height).data;
      lap('readback');
      await write(Buffer.from(data.buffer, data.byteOffset, data.byteLength));
      lap('write');

      this.progress = (n + 1) / frames * 0.99;
      const elapsed = (performance.now() - started) / 1000;
      this.remaining = n > 10 ? elapsed / (n + 1) * (frames - n - 1) : null;
      if (n % 5 === 0) { this.emit(); await new Promise(r => setTimeout(r, 0)); }
    }
    enc.stdin.end();
    await encDone;
    lap('write');
    const total = (performance.now() - started) / 1000;
    this.stats = { frames, seconds: total, fps: frames / total, ms: Object.fromEntries(Object.entries(ms).map(([k, v]) => [k, Math.round(v)])) };
    console.info('EditRush export stats', JSON.stringify(this.stats));
  }

  makeDecoder(project, layer, scale, fps) {
    const content = compositor.contentSize(project, layer);
    const rect = M.clipRect(content, project.canvas, layer.clip.transform, false);
    // Decode at the displayed size, but never above the media's own size (the canvas scales up).
    const k = Math.min(1, rect.width * scale / content.width);
    const w = Math.max(2, Math.round(content.width * k)), h = Math.max(2, Math.round(content.height * k));
    return new ClipDecoder(layer.clip, layer.media, w, h, fps);
  }
}

class CancelError extends Error { constructor() { super('cancelled'); } }

module.exports = { Exporter, Resolutions, Codecs, Containers, defaultSettings, outputSize, rateString };
