'use strict';
// Exports a project to an MP4 / MOV file. Replaces Exporter.swift.
//
// The timeline is split into segments (engine/exportplan.js):
// * 'video' and 'still' segments are made by ffmpeg alone: it decodes, scales and encodes the
//   plain full-frame video itself (or repeats one still frame), with any still layers above it
//   drawn once by the compositor into a PNG overlay. Up to DIRECT_JOBS of these run at once.
// * 'canvas' segments draw every frame with the same compositor as the preview: video clips are
//   decoded by one ffmpeg process per clip (raw RGBA at display size) and the composed frames are
//   piped into an ffmpeg encoder.
// Every segment is encoded with the same settings (NVIDIA NVENC when it works on this machine,
// else libx264 / libx265), then the segments are joined without re-encoding and the audio mix
// (rendered by an OfflineAudioContext) is added. Everything is written into a temporary folder
// beside the destination; the finished movie replaces the destination only when the export
// succeeds.

const fs = require('fs');
const path = require('path');
const M = require('../core/model');
const ff = require('../media/ffmpeg');
const compositor = require('./compositor');
const audio = require('./audio');
const { planSegments } = require('./exportplan');
const { mediaPath } = require('../core/store');

const Resolutions = { p720: '720p', p1080: '1080p', p2160: '4K', canvas: 'Project Size' };
const Codecs = { h264: 'H.264', hevc: 'HEVC (H.265)' };
const Containers = { mp4: 'MP4', mov: 'MOV' };
const DIRECT_JOBS = 2;
const DIRECT_CHUNK_SECONDS = 10;
const TO_BT709 = 'scale=out_color_matrix=bt709:out_range=tv,format=yuv420p';

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

// MARK: - Encoder choice

const encoderCache = new Map();

/// { name, args, hardware } for `codec` ('h264' | 'hevc'). NVENC is used when a test encode
/// succeeds on this machine (NVIDIA GPU and driver present); otherwise the CPU encoder, and the
/// reason is logged.
function pickEncoder(codec, { cpuOnly = false } = {}) {
  if (cpuOnly) return Promise.resolve(cpuEncoder(codec, 'CPU encoder requested'));
  if (!encoderCache.has(codec)) {
    encoderCache.set(codec, (async () => {
      const nvenc = codec === 'hevc' ? 'hevc_nvenc' : 'h264_nvenc';
      try {
        await ff.run('ffmpeg', ['-v', 'error', '-f', 'lavfi', '-i', 'color=c=black:s=256x256:r=30', '-frames:v', '3', '-c:v', nvenc, '-f', 'null', '-']);
        const args = codec === 'hevc'
          ? ['-c:v', 'hevc_nvenc', '-preset', 'p5', '-tune', 'hq', '-rc', 'vbr', '-cq', '21', '-b:v', '0']
          : ['-c:v', 'h264_nvenc', '-preset', 'p5', '-tune', 'hq', '-rc', 'vbr', '-cq', '19', '-b:v', '0', '-profile:v', 'high'];
        console.info(`EditRush export: using ${nvenc}`);
        return { name: nvenc, args, hardware: true };
      } catch (e) {
        return cpuEncoder(codec, `${nvenc} is not available on this machine: ${e.message}`);
      }
    })());
  }
  return encoderCache.get(codec);
}

function cpuEncoder(codec, reason) {
  console.info(`EditRush export: using the CPU encoder (${reason})`);
  const args = codec === 'hevc'
    ? ['-c:v', 'libx265', '-crf', '20', '-preset', 'medium', '-x265-params', 'log-level=error']
    : ['-c:v', 'libx264', '-crf', '17', '-preset', 'medium'];
  return { name: codec === 'hevc' ? 'libx265' : 'libx264', args, hardware: false };
}

/// The colour matrix ffmpeg should assume for a video file. Untagged video is treated as BT.709,
/// as the preview (Chromium) does; ffmpeg's own default for untagged video is BT.601.
const matrixCache = new Map();
async function inputMatrix(media) {
  if (!matrixCache.has(media.url)) {
    const { stdout } = await ff.run('ffprobe', ['-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=color_space', '-of', 'csv=p=0', mediaPath(media)]);
    const space = stdout.toString().trim();
    matrixCache.set(media.url, /bt470bg|smpte170m|bt601/.test(space) ? 'bt601' : 'bt709');
  }
  return matrixCache.get(media.url);
}

// MARK: - Raw frame decoding for canvas segments

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

/// Decodes one video clip's frames from timeline frame `startFrame` on, in order, at the canvas
/// frame rate and its display size.
class ClipDecoder {
  constructor(clip, media, width, height, fps, startFrame, matrix) {
    this.width = width;
    this.height = height;
    this.firstFrame = startFrame;
    this.delivered = startFrame - 1;
    this.last = null;
    this.stderr = '';
    this.canvas = document.createElement('canvas');
    this.canvas.width = width; this.canvas.height = height;
    this.ctx = this.canvas.getContext('2d');
    const offset = startFrame / fps - clip.start;
    const args = ['-v', 'error', '-ss', (clip.sourceIn + offset).toFixed(6), '-i', mediaPath(media), '-an', '-sn',
      '-t', (clip.duration - offset + 1).toFixed(6),
      '-vf', `fps=${rateString(fps)},scale=${width}:${height}:flags=bicubic:in_color_matrix=${matrix}`,
      '-f', 'rawvideo', '-pix_fmt', 'rgba', 'pipe:1'];
    this.proc = ff.spawn('ffmpeg', args);
    this.proc.stderr.on('data', d => { this.stderr += d.toString(); });
    this.reader = new FrameReader(this.proc.stdout, width * height * 4);
  }

  /// The frame for timeline frame `n` drawn into this decoder's canvas. Past the end of the
  /// source the last frame is held.
  async frame(n) {
    while (this.delivered < n) {
      const f = await this.reader.next();
      if (!f) break;
      this.last = f;
      this.delivered++;
    }
    if (!this.last) throw new Error(`ffmpeg decoded no frames for a clip (${this.stderr.trim() || 'no error output'})`);
    this.ctx.putImageData(new ImageData(new Uint8ClampedArray(this.last.buffer, this.last.byteOffset, this.last.length), this.width, this.height), 0, 0);
    return this.canvas;
  }

  /// Stops the decoder. Its stdout is destroyed too: a paused stream with unread data would keep
  /// the process from ever reporting 'close'.
  close() {
    if (running(this.proc)) this.proc.kill();
    this.proc.stdout.destroy();
  }
}

/// True while a child process has not exited (a killed process keeps exitCode null and sets signalCode).
function running(p) { return p.exitCode === null && p.signalCode === null; }

// MARK: - Exporter

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
    this.procs = new Set();
    /// Test switches: false draws every frame with the compositor (no ffmpeg-only segments);
    /// true encodes with libx264 / libx265 even where NVENC works.
    this.directSegments = true;
    this.cpuEncoder = false;
  }

  onChange(fn) { this.listeners.push(fn); }
  emit() { for (const fn of this.listeners) fn(); }
  get isExporting() { return this.state === 'exporting'; }

  cancel() {
    if (!this.isExporting) return;
    this.cancelled = true;
    for (const p of this.procs) if (running(p)) p.kill();
    this.emit();
  }
  reset() { if (!this.isExporting) { this.state = 'idle'; this.progress = 0; this.remaining = null; this.message = null; this.emit(); } }

  async export(project, outPath, settings) {
    if (this.isExporting) return;
    this.state = 'exporting'; this.progress = 0; this.remaining = null; this.message = null; this.outputPath = outPath; this.cancelled = false; this.stats = null;
    this.emit();
    // Work folder beside the destination (same drive, so the final rename is a move, not a copy).
    const work = path.join(path.dirname(outPath), `.${path.basename(outPath, path.extname(outPath))}.exporting-${M.uuid()}`);
    const created = [];
    try {
      fs.mkdirSync(work);
      const file = name => { const f = path.join(work, name); created.push(f); return f; };
      await this.run(project, settings, outPath, file);
      if (this.cancelled) throw new CancelError();
      this.progress = 1;
      this.state = 'finished';
    } catch (e) {
      if (e instanceof CancelError || this.cancelled) { this.state = 'cancelled'; } else {
        console.error('EditRush export failed', e);
        this.state = 'failed';
        this.message = e.message;
      }
    } finally {
      for (const p of this.procs) if (running(p)) { p.kill(); p.stdout.destroy(); }
      await Promise.all([...this.procs].map(p => (running(p) ? new Promise(r => p.once('exit', r)) : null)));
      this.procs.clear();
      // Only the files this export created are removed, then the (now empty) folder itself.
      for (const f of created) if (fs.existsSync(f)) fs.unlinkSync(f);
      if (fs.existsSync(work)) fs.rmdirSync(work);
      this.emit();
    }
  }

  /// Runs ffmpeg to completion, tracked for cancel. `onLine` receives stdout lines.
  runTool(args, onLine = null) {
    return new Promise((resolve, reject) => {
      const p = ff.spawn('ffmpeg', args);
      this.procs.add(p);
      let err = '', buf = '';
      p.stderr.on('data', d => { err += d.toString(); if (err.length > 100000) err = err.slice(-50000); });
      p.stdout.on('data', d => {
        if (!onLine) return;
        buf += d.toString();
        const lines = buf.split(/\r?\n/);
        buf = lines.pop();
        for (const l of lines) onLine(l);
      });
      p.on('error', reject);
      p.on('close', code => {
        this.procs.delete(p);
        if (this.cancelled) reject(new CancelError());
        else if (code === 0) resolve();
        else reject(new Error(`ffmpeg failed (code ${code}): ${err.trim().split(/\r?\n/).slice(-3).join(' | ')}`));
      });
    });
  }

  async run(project, settings, outPath, file) {
    const canvas = project.canvas;
    const size = outputSize(settings, canvas);
    const scale = size.width / canvas.width;
    const fps = canvas.frameRate;
    const duration = M.projectDuration(project);
    if (!(duration > 0)) throw new Error('The project is empty.');
    const frames = Math.max(1, Math.round(duration * fps));
    const started = performance.now();

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

    for (const m of used.values()) if (m.kind === 'image') { if (!(await this.cache.ready('still', m))) throw new Error(`Could not read ${m.name}`); }
    const audible = audio.audibleClips(project);
    for (const { media } of audible) if (!(await this.cache.ready('audio', media))) throw new Error(`Could not decode the audio of ${media.name}`);
    if (this.cancelled) throw new CancelError();
    const wav = file('mix.wav');
    fs.writeFileSync(wav, audio.wavBytes(await audio.renderMix(project, m => this.cache.get('audio', m), 48000)));

    const encoder = await pickEncoder(settings.codec, { cpuOnly: this.cpuEncoder });
    const encode = [...encoder.args, '-colorspace', 'bt709', '-color_primaries', 'bt709', '-color_trc', 'bt709',
      '-video_track_timescale', '90000', '-an'];
    // Long video segments are cut into pieces so the direct pool can encode them in parallel.
    const chunk = Math.max(1, Math.round(DIRECT_CHUNK_SECONDS * fps));
    const segments = planSegments(project, frames, { direct: this.directSegments }).flatMap(s => {
      if (s.kind !== 'video' || s.to - s.from <= chunk * 1.5) return [s];
      const parts = [];
      for (let f = s.from; f < s.to; f += chunk) parts.push({ ...s, from: f, to: Math.min(s.to, f + chunk) });
      if (parts.length > 1 && parts[parts.length - 1].to - parts[parts.length - 1].from < chunk / 2) {
        parts[parts.length - 2].to = parts.pop().to;
      }
      return parts;
    });
    segments.forEach((s, i) => { s.file = file(`seg${String(i).padStart(4, '0')}.mp4`); s.done = 0; });

    const stats = { encoder: encoder.name, frames, canvasFrames: 0, directFrames: 0, segments: segments.length };
    const report = () => {
      const done = segments.reduce((n, s) => n + s.done, 0);
      this.progress = Math.min(0.99, done / frames * 0.98);
      const elapsed = (performance.now() - started) / 1000;
      this.remaining = done > frames * 0.03 ? elapsed / done * (frames - done) : null;
      this.emit();
    };

    // Direct segments run in a small pool while canvas segments are drawn one after another.
    const direct = segments.filter(s => s.kind !== 'canvas');
    const pool = Array.from({ length: Math.min(DIRECT_JOBS, direct.length) }, async () => {
      while (direct.length) {
        if (this.cancelled) throw new CancelError();
        const s = direct.shift();
        await this.directSegment(project, s, size, scale, fps, encode, file, report);
        stats.directFrames += s.to - s.from;
      }
    });
    const canvasWork = (async () => {
      for (const s of segments.filter(x => x.kind === 'canvas')) {
        if (this.cancelled) throw new CancelError();
        await this.canvasSegment(project, s, size, scale, fps, encode, report);
        stats.canvasFrames += s.to - s.from;
      }
    })();
    const results = await Promise.allSettled([...pool, canvasWork]);
    const failure = results.find(r => r.status === 'rejected');
    if (failure) throw failure.reason;

    // Join the segments without re-encoding and add the sound.
    const list = file('segments.txt');
    fs.writeFileSync(list, segments.map(s => `file '${s.file.replace(/\\/g, '/').replace(/'/g, "'\\''")}'`).join('\n') + '\n');
    const joined = file(`joined${path.extname(outPath)}`);
    await this.runTool(['-v', 'error', '-y', '-f', 'concat', '-safe', '0', '-i', list, '-i', wav, '-map', '0:v', '-map', '1:a',
      '-c:v', 'copy', ...(settings.codec === 'hevc' ? ['-tag:v', 'hvc1'] : []), '-c:a', 'aac', '-b:a', '192k',
      ...(settings.container === 'mp4' ? ['-movflags', '+faststart'] : []), joined]);
    if (this.cancelled) throw new CancelError();
    fs.renameSync(joined, outPath);

    stats.seconds = +((performance.now() - started) / 1000).toFixed(2);
    stats.fps = +(frames / stats.seconds).toFixed(1);
    this.stats = stats;
    console.info('EditRush export stats', JSON.stringify(stats));
  }

  /// A 'video' or 'still' segment made by ffmpeg alone.
  async directSegment(project, s, size, scale, fps, encode, file, report) {
    const t = s.from / fps;
    const n = s.to - s.from;
    const R = rateString(fps);
    let overlay = null;
    if (s.overlay.length || !s.base) {
      // Still layers (titles, images) drawn once by the compositor, exactly as in the preview.
      const c = document.createElement('canvas');
      c.width = size.width; c.height = size.height;
      const missing = compositor.composeFrame(c.getContext('2d'), size.width, size.height, project, t, layer => {
        const img = this.cache.get('still', layer.media);
        return img ? { image: img, width: img.naturalWidth, height: img.naturalHeight } : null;
      }, { transparent: !!s.base, skip: s.base ? new Set([s.base]) : null });
      if (missing) throw new Error(`still layers at ${t.toFixed(2)}s could not be drawn`);
      overlay = file(`overlay${String(s.from).padStart(7, '0')}.png`);
      const blob = await new Promise(r => c.toBlob(r, 'image/png'));
      fs.writeFileSync(overlay, Buffer.from(await blob.arrayBuffer()));
    }
    let args;
    if (s.base) {
      const clip = M.findClip(project, s.base);
      const media = M.findMedia(project, clip.mediaID);
      const matrix = await inputMatrix(media);
      const ss = clip.sourceIn + (t - clip.start);
      let graph = `[0:v]fps=${R},scale=${size.width}:${size.height}:flags=bicubic:in_color_matrix=${matrix}:out_color_matrix=bt709:out_range=tv,setsar=1,format=yuv420p`;
      graph += overlay ? `[b];[1:v]scale=out_color_matrix=bt709:out_range=tv,format=yuva420p[o];[b][o]overlay=format=yuv420,format=yuv420p[v]` : '[v]';
      args = ['-ss', ss.toFixed(6), '-i', mediaPath(media), ...(overlay ? ['-loop', '1', '-i', overlay] : []), '-filter_complex', graph, '-map', '[v]'];
    } else {
      args = ['-loop', '1', '-framerate', R, '-i', overlay, '-vf', TO_BT709];
    }
    await this.runTool(['-v', 'error', '-y', '-nostats', '-progress', 'pipe:1', ...args, '-frames:v', String(n), '-r', R, ...encode, s.file],
      line => { const m = /^frame=(\d+)/.exec(line); if (m) { s.done = Math.min(n, Number(m[1])); report(); } });
    s.done = n;
    report();
  }

  /// A 'canvas' segment: every frame drawn by the compositor and piped to the encoder.
  async canvasSegment(project, s, size, scale, fps, encode, report) {
    const enc = ff.spawn('ffmpeg', ['-v', 'error', '-y', '-f', 'rawvideo', '-pix_fmt', 'rgba', '-s', `${size.width}x${size.height}`,
      '-framerate', rateString(fps), '-i', 'pipe:0', '-vf', TO_BT709, ...encode, s.file]);
    this.procs.add(enc);
    let encErr = '';
    enc.stderr.on('data', d => { encErr += d.toString(); });
    const encDone = new Promise((resolve, reject) => {
      enc.on('error', reject);
      enc.on('close', code => {
        this.procs.delete(enc);
        if (this.cancelled) reject(new CancelError());
        else if (code === 0) resolve();
        else reject(new Error(`the encoder failed (code ${code}): ${encErr.trim().split(/\r?\n/).slice(-3).join(' | ')}`));
      });
    });
    encDone.catch(() => {}); // awaited below; avoids an unhandled rejection while frames are written
    const write = buf => new Promise((resolve, reject) => {
      if (enc.stdin.destroyed) { reject(this.cancelled ? new CancelError() : new Error(`the encoder stopped: ${encErr.trim()}`)); return; }
      if (enc.stdin.write(buf)) resolve(); else enc.stdin.once('drain', resolve);
    });

    const out = document.createElement('canvas');
    out.width = size.width; out.height = size.height;
    const ctx = out.getContext('2d', { willReadFrequently: true });
    const decoders = new Map();
    try {
      for (let n = s.from; n < s.to; n++) {
        if (this.cancelled) throw new CancelError();
        const t = n / fps;
        const layers = compositor.activeLayers(project, t);
        const activeIDs = new Set();
        for (const layer of layers) {
          if (!layer.media || layer.media.kind !== 'video') continue;
          activeIDs.add(layer.clip.id);
          if (!decoders.has(layer.clip.id)) decoders.set(layer.clip.id, await this.makeDecoder(project, layer, scale, fps, n));
        }
        for (const [id, d] of decoders) if (!activeIDs.has(id)) { d.close(); decoders.delete(id); }
        const videoFrames = new Map();
        for (const id of activeIDs) videoFrames.set(id, await decoders.get(id).frame(n));
        const missingLayers = compositor.composeFrame(ctx, size.width, size.height, project, t, layer => {
          if (layer.media.kind === 'image') {
            const img = this.cache.get('still', layer.media);
            return img ? { image: img, width: img.naturalWidth, height: img.naturalHeight } : null;
          }
          const c = videoFrames.get(layer.clip.id);
          return c ? { image: c, width: c.width, height: c.height } : null;
        });
        if (missingLayers) throw new Error(`a frame at ${t.toFixed(2)}s could not be drawn (${missingLayers} layer(s) unavailable)`);
        const data = ctx.getImageData(0, 0, size.width, size.height).data;
        await write(Buffer.from(data.buffer, data.byteOffset, data.byteLength));
        s.done = n + 1 - s.from;
        if (n % 5 === 0) { report(); await new Promise(r => setTimeout(r, 0)); }
      }
    } finally {
      for (const d of decoders.values()) d.close();
    }
    enc.stdin.end();
    await encDone;
    report();
  }

  async makeDecoder(project, layer, scale, fps, startFrame) {
    const content = compositor.contentSize(project, layer);
    const rect = M.clipRect(content, project.canvas, layer.clip.transform, false);
    // Decode at the displayed size, but never above the media's own size (the canvas scales up).
    const k = Math.min(1, rect.width * scale / content.width);
    const w = Math.max(2, Math.round(content.width * k)), h = Math.max(2, Math.round(content.height * k));
    const d = new ClipDecoder(layer.clip, layer.media, w, h, fps, startFrame, await inputMatrix(layer.media));
    this.procs.add(d.proc);
    d.proc.on('exit', () => this.procs.delete(d.proc));
    return d;
  }
}

class CancelError extends Error { constructor() { super('cancelled'); } }

module.exports = { Exporter, Resolutions, Codecs, Containers, defaultSettings, outputSize, rateString, pickEncoder };
