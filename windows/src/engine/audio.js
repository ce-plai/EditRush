'use strict';
// Audio mix shared by live playback (AudioContext) and export (OfflineAudioContext).
// Replaces CompositionBuilder's audio tracks and AVAudioMix: per-clip volume 0...2 with linear
// fade ramps, track mute, clip mute.

const M = require('../core/model');

/// Clips that make sound: [{ clip, media }]. Video tracks contribute their video clips' embedded
/// audio; audio tracks contribute every clip (including audio detached from video files).
function audibleClips(project) {
  const out = [];
  for (const track of project.tracks) {
    if (track.isMuted) continue;
    for (const clip of track.clips) {
      if (clip.audioMuted || !clip.mediaID) continue;
      const media = M.findMedia(project, clip.mediaID);
      if (!media || media.kind === 'image' || !media.hasAudio) continue;
      if (track.kind === 'video' && media.kind !== 'video') continue;
      out.push({ clip, media });
    }
  }
  return out;
}

/// Schedules every audible clip from timeline time `from` onward, with timeline time `from`
/// playing at context time `when`. `buffer(media)` returns a decoded AudioBuffer or null (that
/// clip is skipped). Returns the created source nodes (stop them to cancel).
function schedule(ctx, destination, project, from, when, buffer) {
  const nodes = [];
  for (const { clip, media } of audibleClips(project)) {
    const end = M.clipEnd(clip);
    if (end <= from) continue;
    const buf = buffer(media);
    if (!buf) continue;
    const startT = Math.max(from, clip.start);
    const offset = clip.sourceIn + (startT - clip.start);
    const length = Math.min(end - startT, buf.duration - offset);
    if (!(length > 0)) continue;

    const at = tl => when + (tl - from);
    const volume = Math.max(0, Math.min(2, clip.volume));
    const g = ctx.createGain();
    const gainAt = tl => volume * M.fadeFactor(clip, Math.min(tl, end - 1e-9));
    g.gain.setValueAtTime(gainAt(startT), at(startT));
    if (clip.fadeIn > 0 && clip.start + clip.fadeIn > startT) {
      g.gain.linearRampToValueAtTime(volume, at(clip.start + clip.fadeIn));
    }
    if (clip.fadeOut > 0) {
      const fs = Math.max(startT, end - clip.fadeOut);
      if (fs > startT) g.gain.setValueAtTime(gainAt(fs), at(fs));
      g.gain.linearRampToValueAtTime(0, at(end));
    }
    g.connect(destination);
    const src = ctx.createBufferSource();
    src.buffer = buf;
    src.connect(g);
    src.start(at(startT), offset, length);
    nodes.push(src);
  }
  return nodes;
}

/// Renders the whole mix offline. Resolves a stereo AudioBuffer of the project's duration.
async function renderMix(project, buffer, sampleRate) {
  const duration = Math.max(M.frameDuration(project.canvas), M.projectDuration(project));
  const ctx = new OfflineAudioContext({ numberOfChannels: 2, length: Math.ceil(duration * sampleRate), sampleRate });
  schedule(ctx, ctx.destination, project, 0, 0, buffer);
  return ctx.startRendering();
}

/// 16-bit PCM WAV bytes of a stereo AudioBuffer.
function wavBytes(buf) {
  const n = buf.length, ch = buf.numberOfChannels;
  const out = Buffer.alloc(44 + n * ch * 2);
  out.write('RIFF', 0); out.writeUInt32LE(36 + n * ch * 2, 4); out.write('WAVE', 8);
  out.write('fmt ', 12); out.writeUInt32LE(16, 16); out.writeUInt16LE(1, 20); out.writeUInt16LE(ch, 22);
  out.writeUInt32LE(buf.sampleRate, 24); out.writeUInt32LE(buf.sampleRate * ch * 2, 28); out.writeUInt16LE(ch * 2, 32);
  out.writeUInt16LE(16, 34); out.write('data', 36); out.writeUInt32LE(n * ch * 2, 40);
  const data = [];
  for (let c = 0; c < ch; c++) data.push(buf.getChannelData(c));
  let o = 44;
  for (let i = 0; i < n; i++) {
    for (let c = 0; c < ch; c++) {
      const v = Math.max(-1, Math.min(1, data[c][i]));
      out.writeInt16LE(Math.round(v < 0 ? v * 32768 : v * 32767), o);
      o += 2;
    }
  }
  return out;
}

module.exports = { audibleClips, schedule, renderMix, wavBytes };
