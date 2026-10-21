'use strict';
// Draws one frame of a project into a canvas 2D context. Used by the live preview and by the
// exporter, so both produce the same picture. Replaces VideoCompositor.swift / CompositionBuilder's
// video composition.

const M = require('../core/model');
const color = require('./color');
const text = require('./text');

/// The timeline time whose frame is shown at `t` (the end of the timeline shows the last frame).
function displayTime(project, t) {
  const d = M.projectDuration(project);
  return Math.max(0, Math.min(t, d - M.frameDuration(project.canvas) / 2));
}

/// Visual layers active at `t`, bottom to top: [{ clip, track, media }].
function activeLayers(project, t) {
  const layers = [];
  for (const track of project.tracks) {
    if (track.kind !== 'video' || track.isHidden) continue;
    for (const clip of track.clips) {
      if (clip.start > t) break;
      if (!M.clipContains(clip, t)) continue;
      const media = clip.mediaID ? M.findMedia(project, clip.mediaID) : null;
      if (!clip.text && (!media || media.kind === 'audio')) continue;
      layers.push({ clip, track, media });
    }
  }
  return layers;
}

/// Opacity x fade at `t`.
function layerAlpha(clip, t) {
  const opacity = Math.max(0, Math.min(1, clip.transform.opacity));
  if (!(clip.fadeIn > 0 || clip.fadeOut > 0)) return opacity;
  const inside = Math.min(Math.max(t, clip.start), M.clipEnd(clip) - 1e-9);
  return opacity * M.fadeFactor(clip, inside);
}

/// Base content size (canvas pixels for text, media display size otherwise) or null.
function contentSize(project, layer) {
  if (layer.clip.text) return text.size(layer.clip.text, project.canvas.height);
  const m = layer.media;
  if (m && m.pixelWidth > 0 && m.pixelHeight > 0) return { width: m.pixelWidth, height: m.pixelHeight };
  return null;
}

/// Source time (seconds into the media) shown by a video clip at timeline time `t`.
/// A clip that runs past the end of its media holds the last frame.
function sourceTime(clip, media, t) {
  const lastFrame = media.frameRate > 0 ? 1 / media.frameRate : 1 / 30;
  return Math.max(0, Math.min(clip.sourceIn + (t - clip.start), media.duration - lastFrame / 2));
}

const scratch = [];
function scratchCanvas(i, w, h) {
  let c = scratch[i];
  if (!c) { c = document.createElement('canvas'); scratch[i] = c; }
  if (c.width !== w || c.height !== h) { c.width = w; c.height = h; }
  const ctx = c.getContext('2d');
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.globalAlpha = 1;
  ctx.globalCompositeOperation = 'source-over';
  ctx.filter = 'none';
  ctx.clearRect(0, 0, w, h);
  return c;
}

const cssColor = c => `rgba(${Math.round(c.r * 255)},${Math.round(c.g * 255)},${Math.round(c.b * 255)},${c.a})`;

/// Draws the frame at timeline time `t` into `ctx` (size outW x outH).
/// `resolve(layer, t, scale)` returns a drawable { image, width, height } for media layers, or
/// null when the frame is not available (the layer is skipped). Text layers are rendered here.
/// Returns the number of media layers that were not available.
function composeFrame(ctx, outW, outH, project, t, resolve) {
  const canvas = project.canvas;
  const scale = outW / Math.max(1, canvas.width);
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.globalAlpha = 1;
  ctx.globalCompositeOperation = 'source-over';
  ctx.filter = 'none';
  ctx.fillStyle = cssColor(canvas.backgroundColor);
  ctx.clearRect(0, 0, outW, outH);
  ctx.fillRect(0, 0, outW, outH);
  let missing = 0;

  for (const layer of activeLayers(project, t)) {
    const clip = layer.clip;
    const alpha = layerAlpha(clip, t);
    if (alpha <= 0.001) continue;
    const content = contentSize(project, layer);
    if (!content) continue;
    const rect = M.clipRect(content, canvas, clip.transform, !!clip.text);
    if (!(rect.width > 0.01 && rect.height > 0.01)) continue;

    let src;
    if (clip.text) {
      const img = text.image(clip.text, canvas.height, scale * Math.max(0, clip.transform.scale));
      src = { image: img, width: img.width, height: img.height };
    } else {
      src = resolve(layer, t, scale);
      if (!src) { missing++; continue; }
    }

    const w = rect.width * scale, h = rect.height * scale;
    const p = clip.text ? { matrix: null, spatial: null, vignette: 0 } : color.plan(clip);
    // Whole-image drawImage: the source-rectangle form uses unrotated coordinates for rotated video.
    let drawable = src.image;

    if (p.spatial || p.vignette > 0) {
      // Render the layer at its destination size first, then place it.
      const lw = Math.max(1, Math.min(8192, Math.round(w))), lh = Math.max(1, Math.min(8192, Math.round(h)));
      const lc = scratchCanvas(0, lw, lh);
      const l = lc.getContext('2d');
      l.filter = color.baseFilter(p);
      l.drawImage(src.image, 0, 0, lw, lh);
      if (p.spatial) {
        l.filter = color.spatialFilter(p, lw, lh);
        l.globalAlpha = p.spatial.mix;
        l.drawImage(src.image, 0, 0, lw, lh);
        l.globalAlpha = 1;
      }
      l.filter = 'none';
      color.drawVignette(l, lw, lh, p.vignette);
      drawable = lc;
      ctx.filter = 'none';
    } else {
      ctx.filter = color.baseFilter(p);
    }

    const xf = clip.transform;
    ctx.save();
    ctx.globalAlpha = alpha;
    ctx.imageSmoothingQuality = 'high';
    ctx.translate((rect.x + rect.width / 2) * scale, (rect.y + rect.height / 2) * scale);
    if (xf.rotation) ctx.rotate(xf.rotation * Math.PI / 180);
    ctx.scale(xf.flipHorizontal ? -1 : 1, xf.flipVertical ? -1 : 1);
    ctx.drawImage(drawable, -w / 2, -h / 2, w, h);
    ctx.restore();
    ctx.filter = 'none';
  }
  return missing;
}

module.exports = { displayTime, activeLayers, layerAlpha, contentSize, sourceTime, composeFrame };
