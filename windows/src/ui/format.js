'use strict';
// Time formatting and the timeline ruler scale. Port of TimelineLayout.swift's RulerScale /
// TimelineFormat.

const pad = (n, w = 2) => String(n).padStart(w, '0');

/// "m:ss" or "h:mm:ss" for whole-second ruler labels.
function rulerTime(t) {
  const total = Math.floor(t + 0.0005);
  const hh = Math.floor(total / 3600), m = Math.floor(total / 60) % 60, s = total % 60;
  return hh > 0 ? `${hh}:${pad(m)}:${pad(s)}` : `${m}:${pad(s)}`;
}

/// "HH:MM:SS:FF" at `frameRate` (non-drop).
function timecode(t, frameRate) {
  const fps = Math.max(1, Math.round(frameRate));
  const frames = Math.max(0, Math.floor(Math.max(0, t) * frameRate + 0.001));
  const ff = frames % fps, total = Math.floor(frames / fps);
  return `${pad(Math.floor(total / 3600))}:${pad(Math.floor(total / 60) % 60)}:${pad(total % 60)}:${pad(ff)}`;
}

/// "4.5s" or "1:12".
function shortDuration(d) { return d < 60 ? `${d.toFixed(1)}s` : rulerTime(d); }

/// Tick spacing for the ruler: { major, divisions, majorFrames }.
function rulerScale(pps, frameRate, minSpacing = 76) {
  const fps = Math.max(1, Math.round(frameRate));
  const divisionsFor = (frames, spacing) => {
    for (let d = frames; d >= 1; d--) if (frames % d === 0 && spacing / d >= 7) return d;
    return 1;
  };
  for (const f of [1, 2, 5, 10, 15].filter(f => f < fps)) {
    const s = f / fps;
    if (s * pps >= minSpacing) return { major: s, divisions: divisionsFor(f, s * pps), majorFrames: f };
  }
  const steps = [[1, [10, 5, 2]], [2, [4, 2]], [5, [5]], [10, [10, 5, 2]], [15, [3]], [30, [6, 3]], [60, [12, 6, 4, 2]],
    [120, [4, 2]], [300, [5]], [600, [10, 2]], [900, [3]], [1800, [6, 3]], [3600, [12, 6, 4, 2]], [7200, [4, 2]],
    [18000, [5]], [36000, [10, 2]]];
  for (const [s, subs] of steps) {
    if (s * pps >= minSpacing || s === 36000) {
      return { major: s, divisions: subs.find(n => s * pps / n >= 7) ?? 1, majorFrames: null };
    }
  }
  return { major: 3600, divisions: 1, majorFrames: null };
}

function rulerLabel(scale, t, frameRate) {
  if (scale.majorFrames !== null) {
    const fps = Math.max(1, Math.round(frameRate));
    const frame = Math.round(t * fps) % fps;
    if (frame !== 0) return `${frame}f`;
  }
  return rulerTime(t);
}

function number(v, decimals = 0) { return v.toFixed(decimals); }

module.exports = { rulerTime, timecode, shortDuration, rulerScale, rulerLabel, number };
