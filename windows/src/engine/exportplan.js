'use strict';
// Splits an export into runs of frames ("segments") and decides how each run is made:
//
//   'video'  - the bottom layer is one plain, full-frame video clip and everything above it is
//              still (images / titles, no fades). ffmpeg decodes, scales and encodes the run
//              itself; the still layers above are drawn once by the compositor into an overlay.
//   'still'  - no video and nothing changes: the compositor draws one frame, ffmpeg repeats it.
//   'canvas' - anything else (fades, transformed / colour-adjusted / filtered video, video over
//              video, held last frames): every frame is drawn by the compositor, as in the preview.
//
// Pure (no DOM), so it is unit-tested in node.

const M = require('../core/model');
const compositor = require('./compositor');

/// Direct runs shorter than this are drawn by the compositor: starting an ffmpeg process costs
/// more than drawing a few frames.
const MIN_DIRECT_FRAMES = 12;

/// True when `clip` shows `media` unchanged over the whole canvas.
function isPlainFullFrame(clip, media, canvas) {
  const xf = clip.transform;
  if (!(media.pixelWidth > 0 && media.pixelHeight > 0)) return false;
  const sameAspect = Math.abs(media.pixelWidth / media.pixelHeight - canvas.width / canvas.height) < 1e-3;
  const unfiltered = clip.filter === 'none' || clip.filterIntensity <= 0;
  return sameAspect && unfiltered && M.isIdentityColor(clip.color) && xf.scale === 1 && xf.offsetX === 0 && xf.offsetY === 0
    && xf.rotation % 360 === 0 && xf.opacity === 1 && !xf.flipHorizontal && !xf.flipVertical;
}

/// True when a fade of `clip` is in progress at `t` (its opacity changes frame to frame).
function fading(clip, t) {
  return (clip.fadeIn > 0 && t < clip.start + clip.fadeIn) || (clip.fadeOut > 0 && t >= M.clipEnd(clip) - clip.fadeOut);
}

/// How frame `n` can be made: { key, kind, base, overlay } where frames with equal keys can share
/// one segment.
function classify(project, n, fps) {
  const t = n / fps;
  const layers = compositor.activeLayers(project, t);
  if (layers.some(l => fading(l.clip, t))) return { key: 'canvas', kind: 'canvas' };
  const videos = layers.filter(l => l.media && l.media.kind === 'video');
  const ids = layers.map(l => l.clip.id);
  if (!videos.length) return { key: `still|${ids.join(',')}`, kind: 'still', base: null, overlay: ids };
  const v = videos[0];
  if (videos.length === 1 && layers[0] === v && isPlainFullFrame(v.clip, v.media, project.canvas)) {
    const mediaFrame = v.media.frameRate > 0 ? 1 / v.media.frameRate : 1 / 30;
    const held = v.clip.sourceIn + (t - v.clip.start) > v.media.duration - mediaFrame / 2;
    if (!held) return { key: `video|${ids.join(',')}`, kind: 'video', base: v.clip.id, overlay: ids.slice(1) };
  }
  return { key: 'canvas', kind: 'canvas' };
}

/// Segments covering frames [0, frames): [{ kind, from, to, base, overlay }], `to` exclusive.
/// `direct: false` puts every frame on the canvas path.
function planSegments(project, frames, { direct = true } = {}) {
  const fps = project.canvas.frameRate;
  const runs = [];
  for (let n = 0; n < frames; n++) {
    const c = direct ? classify(project, n, fps) : { key: 'canvas', kind: 'canvas' };
    const last = runs[runs.length - 1];
    if (last && last.key === c.key) last.to = n + 1;
    else runs.push({ ...c, from: n, to: n + 1 });
  }
  // Short direct runs go to the canvas path; neighbouring canvas runs merge.
  const out = [];
  for (const r of runs) {
    const kind = r.kind !== 'canvas' && r.to - r.from < MIN_DIRECT_FRAMES ? 'canvas' : r.kind;
    const last = out[out.length - 1];
    if (kind === 'canvas' && last && last.kind === 'canvas') { last.to = r.to; continue; }
    out.push(kind === 'canvas' ? { kind, from: r.from, to: r.to } : { kind, from: r.from, to: r.to, base: r.base, overlay: r.overlay });
  }
  return out;
}

module.exports = { planSegments, isPlainFullFrame, MIN_DIRECT_FRAMES };
