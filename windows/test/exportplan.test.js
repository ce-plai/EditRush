'use strict';
const test = require('node:test');
const assert = require('node:assert');
const M = require('../src/core/model');
const { planSegments, MIN_DIRECT_FRAMES } = require('../src/engine/exportplan');

function project() {
  const p = M.emptyProject();
  p.media.push({ id: 'V', url: 'file:///C:/x/v.mp4', name: 'v', kind: 'video', duration: 60, pixelWidth: 2560, pixelHeight: 1440, frameRate: 30, hasAudio: true });
  p.media.push({ id: 'SQ', url: 'file:///C:/x/sq.mp4', name: 'sq', kind: 'video', duration: 60, pixelWidth: 1080, pixelHeight: 1080, frameRate: 30, hasAudio: false });
  p.media.push({ id: 'I', url: 'file:///C:/x/i.png', name: 'i', kind: 'image', duration: 0, pixelWidth: 400, pixelHeight: 400, frameRate: 0, hasAudio: false });
  return p;
}
const clip = (mediaID, start, duration, extra = {}) => Object.assign(M.makeClip({ mediaID, start, duration }), extra);
const title = (start, duration) => M.makeClip({ start, duration, text: M.defaultTextStyle('Hi') });
const shape = segs => segs.map(s => `${s.kind}:${s.from}-${s.to}`);

test('a plain full-frame clip is one direct video segment', () => {
  const p = project();
  p.tracks[0].clips.push(clip('V', 0, 10));
  assert.deepStrictEqual(shape(planSegments(p, 300)), ['video:0-300']);
});

test('fade frames are drawn on the canvas, the rest goes direct', () => {
  const p = project();
  p.tracks[0].clips.push(clip('V', 0, 10, { fadeIn: 1, fadeOut: 0.5 }));
  assert.deepStrictEqual(shape(planSegments(p, 300)), ['canvas:0-30', 'video:30-285', 'canvas:285-300']);
});

test('a title over plain video splits into video segments with and without overlay', () => {
  const p = project();
  p.tracks[0].clips.push(clip('V', 0, 10));
  const t = title(2, 3);
  p.tracks[1].clips.push(t);
  const segs = planSegments(p, 300);
  assert.deepStrictEqual(shape(segs), ['video:0-60', 'video:60-150', 'video:150-300']);
  assert.deepStrictEqual(segs[1].overlay, [t.id]);
  assert.deepStrictEqual(segs[0].overlay, []);
});

test('transformed, colour-adjusted, filtered or non-matching-aspect video uses the canvas', () => {
  for (const extra of [{ transform: { ...M.defaultTransform(), scale: 0.5 } }, { color: { ...M.defaultColor(), saturation: 0.5 } },
    { filter: 'sepia' }]) {
    const p = project();
    p.tracks[0].clips.push(clip('V', 0, 2, extra));
    assert.deepStrictEqual(shape(planSegments(p, 60)), ['canvas:0-60'], JSON.stringify(extra));
  }
  const p = project();
  p.tracks[0].clips.push(clip('SQ', 0, 2));
  assert.deepStrictEqual(shape(planSegments(p, 60)), ['canvas:0-60']);
});

test('a filter at zero intensity is plain', () => {
  const p = project();
  p.tracks[0].clips.push(clip('V', 0, 2, { filter: 'sepia', filterIntensity: 0 }));
  assert.deepStrictEqual(shape(planSegments(p, 60)), ['video:0-60']);
});

test('video over video uses the canvas; stills and gaps are still segments', () => {
  const p = project();
  p.tracks[0].clips.push(clip('V', 0, 2), clip('I', 4, 2));
  p.tracks[1].clips.push(clip('V', 1, 1, { transform: { ...M.defaultTransform(), scale: 0.3 } }));
  assert.deepStrictEqual(shape(planSegments(p, 180)), ['video:0-30', 'canvas:30-60', 'still:60-120', 'still:120-180']);
});

test(`direct runs shorter than ${MIN_DIRECT_FRAMES} frames merge into the canvas`, () => {
  const p = project();
  p.tracks[0].clips.push(clip('V', 0, 10, { fadeIn: 1 }));
  p.tracks[1].clips.push(title(1.2, 2));
  // Frames 30-35 would be a 6-frame plain run between the fade and the title.
  const segs = planSegments(p, 300);
  assert.deepStrictEqual(shape(segs), ['canvas:0-36', 'video:36-96', 'video:96-300']);
});

test('frames past the end of the source (held last frame) use the canvas', () => {
  const p = project();
  p.media[0].duration = 5;
  p.tracks[0].clips.push(clip('V', 0, 6));
  assert.deepStrictEqual(shape(planSegments(p, 180)), ['video:0-150', 'canvas:150-180']);
});

test('direct: false puts everything on the canvas', () => {
  const p = project();
  p.tracks[0].clips.push(clip('V', 0, 10));
  assert.deepStrictEqual(shape(planSegments(p, 300, { direct: false })), ['canvas:0-300']);
});
