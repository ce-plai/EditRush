'use strict';
// Probing media files with ffprobe. Port of Sources/EditRushCore/Media/MediaImporter.swift.

const fs = require('fs');
const path = require('path');
const M = require('../core/model');
const ff = require('./ffmpeg');

const videoExtensions = new Set(['mp4', 'mov', 'm4v']);
const audioExtensions = new Set(['mp3', 'wav', 'ogg', 'oga', 'opus', 'm4a', 'aac', 'aif', 'aiff', 'flac']);
const imageExtensions = new Set(['png', 'jpg', 'jpeg', 'gif', 'bmp', 'webp']);
const supportedExtensions = new Set([...videoExtensions, ...audioExtensions, ...imageExtensions]);

const ext = f => path.extname(f).slice(1).toLowerCase();
const isSupported = f => supportedExtensions.has(ext(f));

class MediaError extends Error {
  constructor(file, reason) { super(`Could not import ${file}: ${reason}`); this.file = file; this.reason = reason; }
}

/// Replaces folders with their supported, non-hidden files (one level deep, sorted by name).
function expandFolders(paths) {
  const files = [];
  for (const p of paths) {
    let st = null;
    try { st = fs.statSync(p); } catch { files.push(p); continue; }
    if (!st.isDirectory()) { files.push(p); continue; }
    const children = fs.readdirSync(p, { withFileTypes: true })
      .filter(d => d.isFile() && !d.name.startsWith('.') && isSupported(d.name))
      .map(d => d.name)
      .sort((a, b) => a.localeCompare(b, undefined, { numeric: true, sensitivity: 'base' }));
    files.push(...children.map(n => path.join(p, n)));
  }
  return files;
}

/// Probes many files (4 at a time). Returns { items, failures: [{ path, reason }] } in input order.
async function importFiles(paths) {
  const files = expandFolders(paths);
  const results = new Array(files.length);
  let next = 0;
  const worker = async () => {
    while (next < files.length) {
      const i = next++;
      try { results[i] = { item: await probe(files[i]) }; } catch (e) {
        if (!(e instanceof MediaError)) console.error(`EditRush probe failed for ${files[i]}:`, e);
        results[i] = { failure: { path: files[i], reason: e instanceof MediaError ? e.reason : `the file's format or codec isn't supported (${e.message})` } };
      }
    }
  };
  await Promise.all(Array.from({ length: Math.min(4, files.length) }, worker));
  return { items: results.filter(r => r.item).map(r => r.item), failures: results.filter(r => r.failure).map(r => r.failure) };
}

const displayName = f => path.basename(f, path.extname(f)) || path.basename(f);

function parseRate(s) {
  if (!s || s === '0/0') return 0;
  const [n, d] = s.split('/').map(Number);
  return d ? n / d : n;
}

/// Rotation (degrees) of a video stream from its display matrix side data or rotate tag.
function streamRotation(s) {
  const side = (s.side_data_list || []).find(d => d.rotation !== undefined);
  if (side) return Number(side.rotation) || 0;
  if (s.tags && s.tags.rotate) return Number(s.tags.rotate) || 0;
  return 0;
}

/// Reads kind, duration, display size (after rotation), frame rate and audio presence.
async function probe(file) {
  const name = path.basename(file);
  if (!isSupported(file)) throw new MediaError(name, 'unsupported file type');
  if (!fs.existsSync(file)) throw new MediaError(name, "the file doesn't exist");
  try { fs.accessSync(file, fs.constants.R_OK); } catch { throw new MediaError(name, "the file couldn't be read"); }

  let info;
  try {
    const { stdout } = await ff.run('ffprobe', ['-v', 'error', '-print_format', 'json', '-show_format', '-show_streams', file]);
    info = JSON.parse(stdout.toString('utf8'));
  } catch (e) {
    throw new MediaError(name, imageExtensions.has(ext(file)) ? "the image couldn't be read" : "the file's format or codec isn't supported");
  }
  const streams = info.streams || [];
  const url = M.pathToFileURL(file);

  if (imageExtensions.has(ext(file))) {
    const v = streams.find(s => s.codec_type === 'video');
    if (!v || !(v.width > 0 && v.height > 0)) throw new MediaError(name, "the image couldn't be read");
    let w = v.width, h = v.height;
    if (Math.abs(streamRotation(v)) % 180 === 90) [w, h] = [h, w];
    return { id: M.uuid(), url, name: displayName(file), kind: 'image', duration: 0, pixelWidth: w, pixelHeight: h, frameRate: 0, hasAudio: false };
  }

  // Cover art in audio files shows up as an attached-picture video stream; it is not video.
  const video = streams.find(s => s.codec_type === 'video' && !(s.disposition && s.disposition.attached_pic));
  const audio = streams.find(s => s.codec_type === 'audio');
  if (!streams.length) throw new MediaError(name, 'no video or audio found in the file');
  if (!video && !audio) throw new MediaError(name, "the file's format or codec isn't supported");

  let seconds = Number(info.format && info.format.duration);
  if (!(seconds > 0.001)) {
    const s = video || audio;
    seconds = Number(s.duration);
  }
  if (!(Number.isFinite(seconds) && seconds > 0.001)) throw new MediaError(name, 'the file has no playable length');

  if (video && videoExtensions.has(ext(file))) {
    let w = video.width, h = video.height;
    if (!(w > 0 && h > 0)) throw new MediaError(name, "the file's format or codec isn't supported");
    if (Math.abs(streamRotation(video)) % 180 === 90) [w, h] = [h, w];
    // Square pixels: apply the sample aspect ratio to the width.
    const sar = video.sample_aspect_ratio && video.sample_aspect_ratio !== '0:1' ? video.sample_aspect_ratio.split(':').map(Number) : null;
    if (sar && sar[0] > 0 && sar[1] > 0 && sar[0] !== sar[1]) {
      if (Math.abs(streamRotation(video)) % 180 === 90) h = Math.round(h * sar[0] / sar[1]); else w = Math.round(w * sar[0] / sar[1]);
    }
    let rate = parseRate(video.avg_frame_rate);
    if (!(rate > 0)) rate = parseRate(video.r_frame_rate);
    // Clips are bounded by the picture: audio that runs past the last frame is dropped.
    const videoEnd = Number(video.start_time || 0) + Number(video.duration || 0);
    if (Number(video.duration) > 0.001 && Number.isFinite(videoEnd)) seconds = Math.min(seconds, videoEnd);
    return { id: M.uuid(), url, name: displayName(file), kind: 'video', duration: seconds, pixelWidth: w, pixelHeight: h,
      frameRate: Number.isFinite(rate) ? rate : 0, hasAudio: !!audio };
  }
  if (!audio) throw new MediaError(name, 'no video or audio found in the file');
  return { id: M.uuid(), url, name: displayName(file), kind: 'audio', duration: seconds, pixelWidth: 0, pixelHeight: 0, frameRate: 0, hasAudio: true };
}

module.exports = { videoExtensions, audioExtensions, imageExtensions, supportedExtensions, isSupported, expandFolders, importFiles, probe, MediaError };
