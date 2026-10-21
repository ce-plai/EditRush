'use strict';
// Renders a title's TextStyle into a canvas. Port of Sources/EditRushCore/Engine/TextRenderer.swift,
// using the canvas 2D text API instead of Core Text.
//
// The canvas-pixel size (`size`) is the text clip's base content size for `clipRect`. Rasters can
// be made at a multiple of that size so titles shown larger stay sharp.

const RASTER_SCALES = [0.5, 0.75, 1, 1.5, 2, 3, 4];
const MAX_RASTER = 8192;

function rasterScale(scale) {
  if (!Number.isFinite(scale)) return 1;
  return RASTER_SCALES.find(s => s >= scale - 1e-6) ?? RASTER_SCALES[RASTER_SCALES.length - 1];
}

const css = c => `rgba(${Math.round(c.r * 255)},${Math.round(c.g * 255)},${Math.round(c.b * 255)},${c.a})`;

function fontString(style, px) {
  const fam = style.fontFamily.replace(/"/g, '');
  return `${style.isItalic ? 'italic ' : ''}${style.isBold ? 'bold ' : ''}${px}px "${fam}", "Segoe UI", sans-serif`;
}

let measureCtx = null;
function measurer() {
  if (!measureCtx) measureCtx = document.createElement('canvas').getContext('2d');
  return measureCtx;
}

/// Layout in canvas pixels.
function makeLayout(style, canvasHeight) {
  const px = Math.max(4, style.fontSize * canvasHeight);
  const lines = (style.text.length ? style.text : ' ').split('\n');
  const ctx = measurer();
  ctx.font = fontString(style, px);
  const lineHeight = Math.ceil(px * 1.2);
  const widths = lines.map(l => ctx.measureText(l).width);
  const textW = Math.ceil(Math.max(1, ...widths)) + 2;
  const textH = lineHeight * lines.length + 2;
  const outline = Math.max(0, style.outlineWidth) * px;
  const hasBox = style.backgroundColor.a > 0.001;
  const padX = hasBox ? Math.ceil(px * 0.35) : 0;
  const padY = hasBox ? Math.ceil(px * 0.18) : 0;
  const shadowMargin = style.shadow ? Math.ceil(px * 0.16) : 0;
  const margin = Math.max(shadowMargin, Math.ceil(outline) + 2);
  const boxW = textW + 2 * padX, boxH = textH + 2 * padY;
  return {
    px, lines, widths, lineHeight, outline,
    size: { width: boxW + 2 * margin, height: boxH + 2 * margin },
    box: hasBox ? { x: margin, y: margin, width: boxW, height: boxH } : null,
    text: { x: margin + padX, y: margin + padY, width: textW, height: textH },
  };
}

function render(layout, style, scale) {
  const w = Math.max(1, Math.ceil(layout.size.width * scale)), h = Math.max(1, Math.ceil(layout.size.height * scale));
  const out = document.createElement('canvas');
  out.width = w; out.height = h;
  const ctx = out.getContext('2d');
  const sx = w / layout.size.width, sy = h / layout.size.height;
  ctx.scale(sx, sy);

  if (layout.box) {
    const b = layout.box, r = Math.min(layout.px * 0.22, b.height / 2);
    ctx.fillStyle = css(style.backgroundColor);
    ctx.beginPath();
    ctx.roundRect(b.x, b.y, b.width, b.height, r);
    ctx.fill();
  }

  // Stroke + fill are drawn into their own layer so the shadow falls behind the group, not per pass.
  const layer = document.createElement('canvas');
  layer.width = w; layer.height = h;
  const lc = layer.getContext('2d');
  lc.scale(sx, sy);
  lc.font = fontString(style, layout.px);
  lc.textBaseline = 'middle';
  lc.lineJoin = 'round';
  const t = layout.text;
  layout.lines.forEach((line, i) => {
    const lw = layout.widths[i];
    const x = style.alignment === 'left' ? t.x + 1 : style.alignment === 'right' ? t.x + t.width - 1 - lw : t.x + (t.width - lw) / 2;
    const y = t.y + 1 + layout.lineHeight * (i + 0.5);
    if (layout.outline > 0) {
      lc.strokeStyle = css(style.outlineColor);
      lc.lineWidth = 2 * layout.outline;
      lc.strokeText(line, x, y);
    }
    lc.fillStyle = css(style.color);
    lc.fillText(line, x, y);
  });

  ctx.setTransform(1, 0, 0, 1, 0, 0);
  if (style.shadow) {
    const px = layout.px * sy;
    ctx.shadowColor = 'rgba(0,0,0,0.65)';
    ctx.shadowBlur = px * 0.1;
    ctx.shadowOffsetY = px * 0.03;
  }
  ctx.drawImage(layer, 0, 0);
  return out;
}

/// LRU cache of layouts and rasters keyed by (style, canvas height).
const cache = new Map();
const LIMIT = 96;

function entry(style, canvasHeight) {
  const key = JSON.stringify(style) + '|' + canvasHeight;
  let e = cache.get(key);
  if (e) { cache.delete(key); cache.set(key, e); return e; }
  e = { layout: makeLayout(style, canvasHeight), images: new Map() };
  cache.set(key, e);
  if (cache.size > LIMIT) {
    for (const k of [...cache.keys()].slice(0, cache.size - LIMIT / 2)) cache.delete(k);
  }
  return e;
}

/// Size in canvas pixels of the rendered text (including box padding and shadow margin).
function size(style, canvasHeight) { return entry(style, canvasHeight).layout.size; }

/// Canvas holding the text rasterized at `rasterScale(displayScale)` x `size`.
function image(style, canvasHeight, displayScale = 1) {
  const e = entry(style, canvasHeight);
  const maxScale = MAX_RASTER / Math.max(1, e.layout.size.width, e.layout.size.height);
  let s = rasterScale(displayScale);
  if (s > maxScale) s = [...RASTER_SCALES].reverse().find(v => v <= maxScale) ?? RASTER_SCALES[0];
  let img = e.images.get(s);
  if (!img) { img = render(e.layout, style, s); e.images.set(s, img); }
  return img;
}

/// Drops cached rasters (call after fonts finish loading).
function clearCache() { cache.clear(); }

module.exports = { size, image, rasterScale, clearCache, fontString };
