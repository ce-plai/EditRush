'use strict';
// Per-clip colour adjustments and filter presets, shared by the preview and the exporter.
// Replaces Sources/EditRushCore/Engine/FilterRenderer.swift (Core Image is not available on Windows).
//
// Everything that is a per-pixel affine colour transform (exposure, brightness, contrast,
// saturation, temperature and the colour presets, including the intensity mix) is folded into ONE
// 3x4 matrix and applied with an SVG feColorMatrix through the canvas 2D `filter` property.
// Blur, Sharpen and Comic are spatial / non-linear and are drawn as a second pass mixed by intensity.
// Vignette is a radial darkening drawn over the layer.

const M = require('../core/model');

// 3x4 affine colour matrix: [r'; g'; b'] = A * [r; g; b] + o, stored row-major as 12 numbers
// [a00 a01 a02 o0  a10 a11 a12 o1  a20 a21 a22 o2], values in 0...1 colour units.
const IDENTITY = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0];
const LR = 0.2126, LG = 0.7152, LB = 0.0722;

/// a then b (b applied to the output of a).
function then(a, b) {
  const r = new Array(12);
  for (let i = 0; i < 3; i++) {
    for (let j = 0; j < 3; j++) r[i * 4 + j] = b[i * 4] * a[j] + b[i * 4 + 1] * a[4 + j] + b[i * 4 + 2] * a[8 + j];
    r[i * 4 + 3] = b[i * 4] * a[3] + b[i * 4 + 1] * a[7] + b[i * 4 + 2] * a[11] + b[i * 4 + 3];
  }
  return r;
}
const lerp = (a, b, k) => a.map((v, i) => v + (b[i] - v) * k);
const gain = (r, g, b) => [r, 0, 0, 0, 0, g, 0, 0, 0, 0, b, 0];
const offset = (r, g, b) => [1, 0, 0, r, 0, 1, 0, g, 0, 0, 1, b];
function saturation(s) {
  const i = 1 - s;
  return [LR * i + s, LG * i, LB * i, 0, LR * i, LG * i + s, LB * i, 0, LR * i, LG * i, LB * i + s, 0];
}
const contrast = c => [c, 0, 0, 0.5 * (1 - c), 0, c, 0, 0.5 * (1 - c), 0, 0, c, 0.5 * (1 - c)];
/// +amount = warmer (more red/orange), -amount = cooler (more blue).
const temperature = a => gain(1 + 0.16 * a, 1 + 0.03 * a, 1 - 0.2 * a);
/// Exposure in EV stops applied to gamma-encoded values (2^ev in linear light).
const exposure = ev => { const k = Math.pow(2, ev / 2.2); return gain(k, k, k); };
const chain = (...ms) => ms.reduce((acc, m) => then(acc, m), IDENTITY);
const SEPIA = [0.393, 0.769, 0.189, 0, 0.349, 0.686, 0.168, 0, 0.272, 0.534, 0.131, 0];

/// Matrix for the user's colour adjustments.
function adjustmentMatrix(c) {
  return chain(exposure(c.exposure), saturation(c.saturation), offset(c.brightness, c.brightness, c.brightness),
    contrast(c.contrast), temperature(c.temperature));
}

/// Affine colour presets; null for spatial presets and 'none'.
function presetMatrix(filter) {
  switch (filter) {
    case 'vivid': return chain(saturation(1.35), contrast(1.08));
    case 'warm': return chain(temperature(0.45), saturation(1.08));
    case 'cool': return chain(temperature(-0.45), saturation(0.95));
    case 'mono': return saturation(0);
    case 'noir': return chain(saturation(0), contrast(1.4), offset(-0.03, -0.03, -0.03));
    case 'sepia': return lerp(IDENTITY, SEPIA, 0.9);
    case 'chrome': return chain(saturation(1.25), contrast(1.12), gain(1.02, 1.0, 0.98));
    case 'fade': return chain(saturation(0.72), contrast(0.82), offset(0.05, 0.05, 0.06));
    case 'instant': return chain(saturation(0.88), gain(1.06, 1.02, 0.9), contrast(0.92), offset(0.03, 0.02, 0.0));
    case 'process': return chain(saturation(0.85), gain(0.94, 1.02, 1.08), contrast(1.06), offset(0.0, 0.02, 0.04));
    case 'tonal': return chain(saturation(0), contrast(0.88), offset(0.02, 0.02, 0.02));
    case 'transfer': return chain(saturation(1.1), gain(1.08, 1.0, 0.86), contrast(1.04), offset(0.02, 0.0, -0.01));
    default: return null;
  }
}

const SPATIAL = new Set(['blur', 'sharpen', 'comic']);

/// Describes how to draw a clip: { matrix (null = identity), spatial: { kind, mix } | null, vignette }.
function plan(clip) {
  const mix = Math.max(0, Math.min(1, clip.filterIntensity));
  const hasFilter = clip.filter !== 'none' && mix > 0;
  let matrix = M.isIdentityColor(clip.color) ? null : adjustmentMatrix(clip.color);
  let spatial = null;
  if (hasFilter) {
    const preset = presetMatrix(clip.filter);
    if (preset) {
      const base = matrix || IDENTITY;
      matrix = lerp(base, then(base, preset), mix);
    } else if (SPATIAL.has(clip.filter)) {
      spatial = { kind: clip.filter, mix };
    }
  }
  return { matrix, spatial, vignette: Math.max(0, Math.min(1, clip.color.vignette)) };
}

// MARK: - SVG filters (canvas `filter: url(#id)`)

const svgNS = 'http://www.w3.org/2000/svg';
let defs = null;
const filterIDs = new Map();

function ensureDefs() {
  if (defs) return defs;
  const svg = document.createElementNS(svgNS, 'svg');
  svg.setAttribute('width', '0');
  svg.setAttribute('height', '0');
  svg.style.position = 'absolute';
  defs = document.createElementNS(svgNS, 'defs');
  svg.appendChild(defs);
  document.body.appendChild(svg);
  return defs;
}

function addFilter(key, build) {
  if (filterIDs.has(key)) return filterIDs.get(key);
  const id = `f${filterIDs.size}`;
  const f = document.createElementNS(svgNS, 'filter');
  f.setAttribute('id', id);
  f.setAttribute('color-interpolation-filters', 'sRGB');
  f.setAttribute('x', '0'); f.setAttribute('y', '0'); f.setAttribute('width', '1'); f.setAttribute('height', '1');
  build(f);
  ensureDefs().appendChild(f);
  filterIDs.set(key, id);
  return id;
}

function matrixFilter(m) {
  const values = [m[0], m[1], m[2], 0, m[3], m[4], m[5], m[6], 0, m[7], m[8], m[9], m[10], 0, m[11], 0, 0, 0, 1, 0]
    .map(v => +v.toFixed(5)).join(' ');
  return `url(#${addFilter(`m:${values}`, f => {
    const e = document.createElementNS(svgNS, 'feColorMatrix');
    e.setAttribute('type', 'matrix');
    e.setAttribute('values', values);
    f.appendChild(e);
  })})`;
}

function sharpenFilter() {
  return `url(#${addFilter('sharpen', f => {
    const e = document.createElementNS(svgNS, 'feConvolveMatrix');
    e.setAttribute('order', '3');
    e.setAttribute('kernelMatrix', '0 -0.6 0 -0.6 3.4 -0.6 0 -0.6 0');
    e.setAttribute('edgeMode', 'duplicate');
    e.setAttribute('preserveAlpha', 'true');
    f.appendChild(e);
  })})`;
}

function comicFilter() {
  return `url(#${addFilter('comic', f => {
    const sat = document.createElementNS(svgNS, 'feColorMatrix');
    sat.setAttribute('type', 'saturate');
    sat.setAttribute('values', '1.6');
    f.appendChild(sat);
    const ct = document.createElementNS(svgNS, 'feComponentTransfer');
    for (const ch of ['feFuncR', 'feFuncG', 'feFuncB']) {
      const fn = document.createElementNS(svgNS, ch);
      fn.setAttribute('type', 'discrete');
      fn.setAttribute('tableValues', '0 0.25 0.5 0.75 1');
      ct.appendChild(fn);
    }
    f.appendChild(ct);
  })})`;
}

/// CSS filter string for the base pass ('' = none).
function baseFilter(p) { return p.matrix ? matrixFilter(p.matrix) : 'none'; }

/// CSS filter string for the spatial pass at the given destination size.
function spatialFilter(p, destWidth, destHeight) {
  const base = p.matrix ? matrixFilter(p.matrix) + ' ' : '';
  switch (p.spatial.kind) {
    case 'blur': return `${base}blur(${Math.max(1, Math.min(destWidth, destHeight) * 0.012).toFixed(2)}px)`;
    case 'sharpen': return base + sharpenFilter();
    case 'comic': return base + comicFilter();
    default: throw new Error(`Unknown spatial filter ${p.spatial.kind}`);
  }
}

/// Darkens the edges of what is already drawn in `ctx` within (0, 0, w, h).
function drawVignette(ctx, w, h, strength) {
  if (strength <= 0) return;
  const r = Math.hypot(w, h) / 2 * 0.9;
  const g = ctx.createRadialGradient(w / 2, h / 2, r * 0.35, w / 2, h / 2, r);
  g.addColorStop(0, 'rgba(0,0,0,0)');
  g.addColorStop(1, `rgba(0,0,0,${Math.min(1, strength).toFixed(3)})`);
  ctx.save();
  ctx.globalCompositeOperation = 'source-atop';
  ctx.fillStyle = g;
  ctx.fillRect(0, 0, w, h);
  ctx.restore();
}

module.exports = { IDENTITY, then, adjustmentMatrix, presetMatrix, plan, baseFilter, spatialFilter, drawVignette };
