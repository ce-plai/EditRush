'use strict';
// Port of Tests/EditRushCoreTests/StoreTests.swift.

const test = require('node:test');
const { beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const M = require('../src/core/model');
const R = require('../src/core/rules');
const { EditorStore, UNDO_LIMIT } = require('../src/core/store');

// MARK: Fixtures

const MEDIA_DIR = 'file:///C:/editrush-tests/';

function mediaItem(file, kind, duration, extra = {}) {
  return {
    id: M.uuid(), url: MEDIA_DIR + file, name: file, kind, duration,
    pixelWidth: 0, pixelHeight: 0, frameRate: 0, hasAudio: false, ...extra,
  };
}

let video, silentVideo, audio, image, tempDir;

beforeEach(() => {
  video = mediaItem('video.mp4', 'video', 10, { pixelWidth: 1920, pixelHeight: 1080, frameRate: 30, hasAudio: true });
  silentVideo = mediaItem('silent.mov', 'video', 4, { pixelWidth: 640, pixelHeight: 360, frameRate: 30, hasAudio: false });
  audio = mediaItem('music.mp3', 'audio', 8, { hasAudio: true });
  image = mediaItem('photo.jpg', 'image', 0, { pixelWidth: 4000, pixelHeight: 3000 });
  tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'EditRushStoreTests-'));
});

/// Removes the temp dir this test created. Refuses to follow links / junctions.
function removeCreated(dir) {
  for (const name of fs.readdirSync(dir)) {
    const p = path.join(dir, name);
    const st = fs.lstatSync(p);
    if (st.isSymbolicLink()) throw new Error(`refusing to clean up link ${p}`);
    if (st.isDirectory()) removeCreated(p);
    else fs.unlinkSync(p);
  }
  fs.rmdirSync(dir);
}

afterEach(() => { removeCreated(tempDir); });

function makeStore() {
  const store = new EditorStore();
  store.addMedia([video, silentVideo, audio, image]);
  return store;
}

/// A store whose first video track holds clips at the given [start, duration] of `video`.
function storeWithV1(spans, sourceIns = null) {
  const p = M.emptyProject();
  p.media = [video, silentVideo, audio, image].map(M.clone);
  const ids = [];
  spans.forEach(([start, duration], i) => {
    const c = M.makeClip({ mediaID: video.id, start, duration, sourceIn: sourceIns ? sourceIns[i] : 0 });
    ids.push(c.id);
    p.tracks[0].clips.push(c);
  });
  return [new EditorStore(p), ids];
}

const sleep = ms => new Promise(r => setTimeout(r, ms));

function approx(actual, expected, msg, eps = 1e-9) {
  assert.ok(typeof actual === 'number' && Math.abs(actual - expected) <= eps,
    `${msg || 'value'}: expected ${expected}, got ${actual}`);
}

function sameProject(a, b, msg) {
  if (!M.deepEqual(a, b)) assert.deepStrictEqual(a, b, msg);
}

function sel(store) { return [...store.selection].sort(); }
function ids(...xs) { return xs.sort(); }
function trackOf(store, id) { const l = M.locate(store.project, id); return l ? l.track : null; }
function videoTracks(p) { return p.tracks.filter(t => t.kind === 'video'); }
function audioTracks(p) { return p.tracks.filter(t => t.kind === 'audio'); }

function assertInvariants(p, context = '') {
  const fps = p.canvas.frameRate;
  const check = (ok, what) => assert.ok(ok, `${what} ${context}`);
  for (const track of p.tracks) {
    for (const c of track.clips) {
      check(Math.abs(c.start * fps - Math.round(c.start * fps)) < 1e-6, 'unquantized start');
      check(Math.abs(c.duration * fps - Math.round(c.duration * fps)) < 1e-6, 'unquantized duration');
      check(c.duration >= M.frameDuration(p.canvas) - 1e-9, 'shorter than a frame');
      check(c.start >= 0, 'negative start');
      check(c.fadeIn >= 0 && c.fadeOut >= 0 && c.fadeIn + c.fadeOut <= c.duration + 1e-9, 'fades exceed duration');
      check(c.sourceIn >= 0, 'negative sourceIn');
      const m = M.findMedia(p, c.mediaID);
      if (m && m.kind !== 'image') check(M.clipSourceOut(c) <= m.duration + 1e-6, 'past the end of the source');
      if (track.kind === 'audio') check(c.mediaID != null && c.text == null, 'non-audio content on an audio track');
      else check(!m || m.kind !== 'audio', 'audio media on a video track');
    }
    for (let i = 0; i + 1 < track.clips.length; i++) {
      const a = track.clips[i], b = track.clips[i + 1];
      check(a.start <= b.start, 'unsorted');
      check(M.clipEnd(a) <= b.start + 1e-6, 'overlap');
    }
  }
}

// MARK: Media

test('addMedia dedupes by standardized URL', () => {
  const store = makeStore();
  assert.equal(store.project.media.length, 4);
  const dup = mediaItem('../editrush-tests/video.mp4', 'video', 10, { name: 'again' });
  const fresh = mediaItem('new.wav', 'audio', 2);
  const fresh2 = mediaItem('new.wav', 'audio', 2);
  store.addMedia([dup, fresh, fresh2]);
  assert.equal(store.project.media.length, 5);
  assert.equal(store.project.media[store.project.media.length - 1].id, fresh.id);
  const revision = store.revision;
  store.addMedia([dup]);
  assert.equal(store.revision, revision, 'no change, no revision bump');
});

test('removeMedia removes clips in one undo step', () => {
  const store = makeStore();
  const a = store.addClip(video.id, { time: 0 });
  const b = store.addClip(video.id, { time: 20 });
  const c = store.addClip(image.id, { time: 0 });
  store.setSelectedMedia(video.id);
  store.setSelection([a, b, c]);
  store.removeMedia(video.id);
  assert.equal(store.media(video.id), null);
  assert.equal(store.clip(a), null); assert.equal(store.clip(b), null);
  assert.notEqual(store.clip(c), null);
  assert.equal(store.selectedMediaID, null);
  assert.deepEqual(sel(store), [c]);
  assert.equal(store.undoActionName, 'Remove Media');
  store.undo();
  assert.notEqual(store.clip(a), null); assert.notEqual(store.clip(b), null);
  assert.notEqual(store.media(video.id), null);
});

// MARK: Nearest free start

test('nearestFreeStart', () => {
  const t = M.makeTrack('video');
  t.clips = [M.makeClip({ start: 2, duration: 2 }), M.makeClip({ start: 5, duration: 3 })]; // [2,4] [5,8]
  assert.equal(R.nearestFreeStart(t, 1, 0.5), 0.5);   // fits as desired
  assert.equal(R.nearestFreeStart(t, 1, 2.4), 1);     // before first clip is closer
  assert.equal(R.nearestFreeStart(t, 1, 3.6), 4);     // gap [4,5] fits exactly
  assert.equal(R.nearestFreeStart(t, 2, 3.6), 0);     // [4,5] too small; [0,2] is closer than 8
  assert.equal(R.nearestFreeStart(t, 2, 5.5), 8);     // after the last clip is closer
  assert.equal(R.nearestFreeStart(t, 3, 1), 8);       // nothing before fits
  assert.equal(R.nearestFreeStart(t, 1, -3), 0);      // clamped at 0
  assert.equal(R.nearestFreeStart(t, 2, 5, new Set([t.clips[1].id])), 5);
  assert.equal(R.isFree(t, 4, 1), true);
  assert.equal(R.isFree(t, 3.9, 1), false);
  assert.equal(R.isFree(M.makeTrack('video'), 0, 100), true);
});

// MARK: addClip / addTextClip

test('addClip defaults and selection', () => {
  const store = makeStore();
  store.playhead = 1.01;
  const v = store.addClip(video.id);
  const clip = store.clip(v);
  approx(clip.start, 1.0, 'quantized playhead');
  approx(clip.duration, 10);
  assert.deepEqual(sel(store), [v]);
  assert.equal(M.trackContaining(store.project, v).id, store.project.tracks[0].id);

  const i = store.addClip(image.id, { time: 20 });
  approx(store.clip(i).duration, 5);
  assert.equal(M.trackContaining(store.project, i).id, store.project.tracks[0].id, 'V1 is free at 20');

  const a = store.addClip(audio.id, { time: 0 });
  assert.equal(M.trackContaining(store.project, a).kind, 'audio');
  approx(store.clip(a).duration, 8);
  assert.equal(store.addClip(M.uuid()), null);
  assertInvariants(store.project);
});

test('addClip picks lowest free track then creates video track above video tracks', () => {
  const store = makeStore();
  const first = store.addClip(video.id, { time: 0 });
  const second = store.addClip(video.id, { time: 2 });
  assert.equal(trackOf(store, first), 0);
  assert.equal(trackOf(store, second), 1, 'V1 busy -> V2');
  const third = store.addClip(image.id, { time: 3 });
  assert.deepEqual(store.project.tracks.map(t => t.kind), ['video', 'video', 'video', 'audio', 'audio']);
  assert.equal(trackOf(store, third), 2, 'new video track inserted after the last video track');
  assert.equal(M.displayName(store.project, store.project.tracks[2].id), 'V3');
  assertInvariants(store.project);
});

test('add audio clip creates audio track at end', () => {
  const store = makeStore();
  store.addClip(audio.id, { time: 0 });
  store.addClip(audio.id, { time: 1 });
  const third = store.addClip(audio.id, { time: 2 });
  assert.equal(store.project.tracks.length, 5);
  assert.equal(trackOf(store, third), 4);
  assert.equal(store.project.tracks[4].kind, 'audio');
});

test('addClip on explicit track resolves overlap', () => {
  const store = makeStore();
  const v1 = store.project.tracks[0].id;
  store.addClip(image.id, { trackID: v1, time: 0 });    // [0,5]
  const b = store.addClip(image.id, { trackID: v1, time: 3 });
  assert.equal(trackOf(store, b), 0);
  approx(store.clip(b).start, 5);
  // Incompatible explicit track falls back to an audio track.
  const a = store.addClip(audio.id, { trackID: v1, time: 0 });
  assert.equal(M.trackContaining(store.project, a).kind, 'audio');
  assertInvariants(store.project);
});

test('addClip skips locked tracks', () => {
  const store = makeStore();
  store.setTrack(store.project.tracks[0].id, { locked: true });
  const id = store.addClip(image.id, { trackID: store.project.tracks[0].id, time: 0 });
  assert.equal(trackOf(store, id), 1);
});

test('addClip quantizes media duration down', () => {
  const store = makeStore();
  const odd = mediaItem('odd.mov', 'video', 2.019);
  store.addMedia([odd]);
  const id = store.addClip(odd.id, { time: 0 });
  approx(store.clip(id).duration, 2.0);
});

test('addTextClip uses topmost free video track', () => {
  const store = makeStore();
  const t1 = store.addTextClip({ time: 1 });
  assert.equal(trackOf(store, t1), 1, 'topmost video track');
  const text = store.clip(t1);
  approx(text.duration, 5);
  assert.deepEqual(text.text, M.defaultTextStyle());
  assert.equal(text.mediaID, undefined);
  const t2 = store.addTextClip({ time: 2, style: M.defaultTextStyle('Two') });
  assert.equal(trackOf(store, t2), 0, 'V2 busy -> V1');
  const t3 = store.addTextClip({ time: 3 });
  assert.equal(trackOf(store, t3), 2, 'new video track above');
  assert.equal(videoTracks(store.project).length, 3);
  assert.deepEqual(sel(store), [t3]);
  assertInvariants(store.project);
});

// MARK: Split

test('split video advances sourceIn and moves fades', () => {
  const [store, idList] = storeWithV1([[1, 6]], [2]);
  store.updateClip(idList[0], 'Fades', c => { c.fadeIn = 1; c.fadeOut = 1.5; });
  const right = store.split(idList[0], 3.01);
  assert.notEqual(right, null);
  const l = store.clip(idList[0]), r = store.clip(right);
  approx(l.start, 1); approx(l.duration, 2);
  approx(l.sourceIn, 2);
  approx(r.start, 3); approx(r.duration, 4);
  approx(r.sourceIn, 4);
  assert.equal(l.fadeIn, 1); assert.equal(l.fadeOut, 0);
  assert.equal(r.fadeIn, 0); assert.equal(r.fadeOut, 1.5);
  assert.notEqual(right, idList[0]);
  assert.deepEqual(sel(store), [right]);
  assertInvariants(store.project);
});

test('split clamps fades to new durations', () => {
  const [store, idList] = storeWithV1([[0, 6]]);
  store.updateClip(idList[0], 'Fades', c => { c.fadeIn = 3; c.fadeOut = 3; });
  const right = store.split(idList[0], 1);
  approx(store.clip(idList[0]).fadeIn, 1);
  approx(store.clip(right).fadeOut, 3);
});

test('split image keeps sourceIn zero', () => {
  const store = makeStore();
  const id = store.addClip(image.id, { time: 0 });
  const right = store.split(id, 2);
  assert.equal(store.clip(right).sourceIn, 0);
  approx(store.clip(right).duration, 3);
});

test('split no-op near edges and on locked tracks', () => {
  const [store, idList] = storeWithV1([[0, 2]]);
  assert.equal(store.split(idList[0], 0.01), null);
  assert.equal(store.split(idList[0], 1.99), null);
  assert.notEqual(store.split(idList[0], 1 / 30), null, 'exactly one frame in is allowed');
  store.undo();
  store.setTrack(store.project.tracks[0].id, { locked: true });
  assert.equal(store.split(idList[0], 1), null);
  assert.equal(store.project.tracks[0].clips.length, 1);
});

test('splitAtPlayhead prefers selected clips under playhead', () => {
  const store = makeStore();
  const a = store.addClip(video.id, { time: 0 });
  const b = store.addClip(image.id, { time: 0 });
  const c = store.addClip(audio.id, { time: 0 });
  store.playhead = 2;
  store.setSelection([b]);
  store.splitAtPlayhead();
  assert.equal(store.project.tracks[0].clips.length, 1, 'unselected video untouched');
  assert.equal(store.project.tracks[1].clips.length, 2);
  assert.equal(store.undoActionName, 'Split');

  // Selected clip not under the playhead -> split everything under the playhead (unlocked).
  store.setSelection([a]);
  store.playhead = 12;
  store.splitAtPlayhead();
  assert.equal(store.project.tracks[0].clips.length, 1, 'nothing under playhead at 12');

  store.setSelection([]);
  store.playhead = 1;
  store.setTrack(store.project.tracks[2].id, { locked: true });
  store.splitAtPlayhead();
  assert.equal(store.project.tracks[0].clips.length, 2);
  assert.equal(store.project.tracks[1].clips.length, 3);
  assert.equal(store.project.tracks[2].clips.length, 1, 'locked audio track untouched');
  assert.equal(store.selection.size, 2, 'right parts selected');
  assert.ok([...store.selection].every(id => Math.abs((store.clip(id) ? store.clip(id).start : -1) - 1) < 1e-9));
  assert.notEqual(store.clip(c), null);
  assertInvariants(store.project);
});

// MARK: Join

test('join after split restores clip', () => {
  const [store, idList] = storeWithV1([[0, 6]], [1]);
  store.updateClip(idList[0], 'Fades', c => { c.fadeIn = 0.5; c.fadeOut = 1; c.transform.scale = 0.5; });
  const original = M.clone(store.clip(idList[0]));
  const right = store.split(idList[0], 2);
  const right2 = store.split(right, 4);
  store.setSelection([idList[0], right, right2]);
  assert.equal(store.canJoinSelection, true);
  store.joinSelection();
  sameProject(store.project.tracks[0].clips, [original]);
  assert.deepEqual(sel(store), [idList[0]]);
  assert.equal(store.undoActionName, 'Join Clips');
});

test('join images and text after split', () => {
  const store = makeStore();
  const img = store.addClip(image.id, { time: 0 });
  const imgRight = store.split(img, 2);
  store.setSelection([img, imgRight]);
  assert.equal(store.canJoinSelection, true);
  store.joinSelection();
  approx(store.clip(img).duration, 5);

  const text = store.addTextClip({ time: 10 });
  const textRight = store.split(text, 12);
  store.setSelection([text, textRight]);
  assert.equal(store.canJoinSelection, true);
  store.updateClip(textRight, 'Edit Text', c => { if (c.text) c.text.text = 'Different'; });
  assert.equal(store.canJoinSelection, false, 'different text cannot merge');
});

test('join rejects invalid selections', () => {
  // Gap between clips.
  const [s1, gapIDs] = storeWithV1([[0, 2], [3, 2]], [0, 3]);
  s1.setSelection(gapIDs);
  assert.equal(s1.canJoinSelection, false);
  // Adjacent but non-continuous source.
  const [s2, jumpIDs] = storeWithV1([[0, 2], [2, 2]], [0, 5]);
  s2.setSelection(jumpIDs);
  assert.equal(s2.canJoinSelection, false);
  const before = s2.project;
  s2.joinSelection();
  sameProject(s2.project, before);
  assert.equal(s2.canUndo, false);
  // Single clip.
  s2.setSelection([jumpIDs[0]]);
  assert.equal(s2.canJoinSelection, false);
  // Different media.
  const store = makeStore();
  const a = store.addClip(silentVideo.id, { time: 0 });
  const b = store.addClip(video.id, { trackID: store.project.tracks[0].id, time: 4 });
  store.setSelection([a, b]);
  assert.equal(store.canJoinSelection, false);
  // Different tracks.
  const c = store.addClip(image.id, { trackID: store.project.tracks[1].id, time: 4 });
  store.setSelection([a, c]);
  assert.equal(store.canJoinSelection, false);
  // Locked track.
  const [s3, ids3] = storeWithV1([[0, 2], [2, 2]], [0, 2]);
  s3.setSelection(ids3);
  assert.equal(s3.canJoinSelection, true);
  s3.setTrack(s3.project.tracks[0].id, { locked: true });
  assert.equal(s3.canJoinSelection, false);
});

// MARK: Delete & gaps

test('delete non-ripple', () => {
  const [store, idList] = storeWithV1([[0, 2], [2, 2], [4, 2]]);
  store.setSelection([idList[1]]);
  store.deleteSelection(false);
  assert.deepEqual(store.project.tracks[0].clips.map(c => c.start), [0, 4]);
  assert.equal(store.selection.size, 0);
});

test('ripple delete multiple clips', () => {
  // [0,2] [2,4] gap [5,6] [6,9] [10,11]
  const [store, idList] = storeWithV1([[0, 2], [2, 2], [5, 1], [6, 3], [10, 1]]);
  store.setSelection([idList[1], idList[3]]);
  store.deleteSelection(true);
  const clips = store.project.tracks[0].clips;
  assert.deepEqual(clips.map(c => c.id), [idList[0], idList[2], idList[4]]);
  approx(clips[1].start, 3, 'shifted by 2');
  approx(clips[2].start, 5, 'shifted by 2 + 3');
  assert.equal(store.undoActionName, 'Ripple Delete');
  assertInvariants(store.project);
  store.undo();
  assert.deepEqual(store.project.tracks[0].clips.map(c => c.id), idList);
});

test('ripple delete only affects own track and respects lock', () => {
  const [store, idList] = storeWithV1([[0, 2], [2, 2]]);
  const other = store.addClip(image.id, { trackID: store.project.tracks[1].id, time: 3 });
  store.setSelection([idList[0]]);
  store.deleteSelection(true);
  approx(store.project.tracks[0].clips[0].start, 0);
  approx(store.clip(other).start, 3);

  store.setTrack(store.project.tracks[0].id, { locked: true });
  store.setSelection([idList[1]]);
  store.deleteSelection(false);
  assert.notEqual(store.clip(idList[1]), null);
});

test('closeGaps with selection and all', () => {
  const [store, idList] = storeWithV1([[1, 1], [3, 1], [6, 1]]);
  store.setSelection([idList[1]]);
  store.closeGaps();
  assert.deepEqual(store.project.tracks[0].clips.map(c => c.start), [1, 2, 5]);
  store.setSelection([]);
  store.closeGaps();
  assert.deepEqual(store.project.tracks[0].clips.map(c => c.start), [0, 1, 2]);
  assertInvariants(store.project);
});

// MARK: Duplicate

test('duplicate places copies after originals', () => {
  const [store, idList] = storeWithV1([[0, 2], [2, 2], [10, 1]]);
  store.setSelection([idList[0], idList[1]]);
  store.duplicateSelection();
  const clips = store.project.tracks[0].clips;
  assert.deepEqual(clips.map(c => c.start), [0, 2, 4, 6, 10]);
  assert.equal(store.selection.size, 2);
  assert.equal(store.selection.has(idList[0]), false);
  assert.deepEqual(ids(clips[2].id, clips[3].id), sel(store));
  assert.equal(clips[2].sourceIn, clips[0].sourceIn);
  assertInvariants(store.project);
});

// MARK: Move

test('moveClip resolves overlap and checks compatibility', () => {
  const [store, idList] = storeWithV1([[0, 2], [4, 2]]);
  assert.equal(store.moveClip(idList[0], store.project.tracks[0].id, 3.5), true);
  approx(store.clip(idList[0]).start, 2, 'nearest free start before the [4,6] clip');
  assert.equal(store.moveClip(idList[0], store.project.tracks[1].id, 3.51), true);
  assert.equal(trackOf(store, idList[0]), 1);
  approx(store.clip(idList[0]).start, 3.5);
  assert.equal(store.moveClip(idList[0], store.project.tracks[2].id, 0), false, 'video -> audio refused');
  assert.equal(store.moveClip(idList[0], M.uuid(), 0), false);
  assert.equal(store.moveClip(idList[0], store.project.tracks[1].id, -5), true);
  approx(store.clip(idList[0]).start, 0);
  assertInvariants(store.project);
});

test('moveClip refused for locked source or target', () => {
  const [store, idList] = storeWithV1([[0, 2]]);
  store.setTrack(store.project.tracks[1].id, { locked: true });
  assert.equal(store.moveClip(idList[0], store.project.tracks[1].id, 0), false);
  store.setTrack(store.project.tracks[1].id, { locked: false });
  store.setTrack(store.project.tracks[0].id, { locked: true });
  assert.equal(store.moveClip(idList[0], store.project.tracks[1].id, 0), false);
  assert.equal(trackOf(store, idList[0]), 0);
});

test('move coalescing is one undo step', () => {
  const [store, idList] = storeWithV1([[0, 2]]);
  const original = store.project;
  const v1 = store.project.tracks[0].id;
  for (let x = 0.5; x <= 5; x += 0.5) store.moveClip(idList[0], v1, x, `move-${idList[0]}`);
  store.endCoalescing();
  approx(store.clip(idList[0]).start, 5);
  store.undo();
  sameProject(store.project, original);
  assert.equal(store.canUndo, false);
  store.redo();
  approx(store.clip(idList[0]).start, 5);

  // After endCoalescing the same key starts a new step.
  store.moveClip(idList[0], v1, 6, `move-${idList[0]}`);
  store.endCoalescing();
  store.moveClip(idList[0], v1, 7, `move-${idList[0]}`);
  store.undo();
  approx(store.clip(idList[0]).start, 6);
});

// MARK: Trim

test('trim leading clamped by media start and neighbour', () => {
  // [0,1] then a 10 s source clip at [3,7] with sourceIn 1.
  const [store, idList] = storeWithV1([[0, 1], [3, 4]], [0, 1]);
  store.trimClip(idList[1], 'leading', 0);
  let c = store.clip(idList[1]);
  approx(c.start, 2, "sourceIn can't go below 0");
  approx(c.sourceIn, 0);
  approx(c.duration, 5);
  approx(M.clipEnd(c), 7);

  store.trimClip(idList[1], 'leading', 4);
  c = store.clip(idList[1]);
  approx(c.start, 4);
  approx(c.sourceIn, 2);
  approx(M.clipEnd(c), 7);

  // Neighbour clamp: second clip has plenty of source before it.
  const [s2, ids2] = storeWithV1([[0, 2], [3, 2]], [0, 5]);
  s2.trimClip(ids2[1], 'leading', 0.5);
  approx(s2.clip(ids2[1]).start, 2);
  approx(s2.clip(ids2[1]).sourceIn, 4);

  // 1-frame minimum.
  s2.trimClip(ids2[1], 'leading', 100);
  approx(s2.clip(ids2[1]).duration, 1 / 30);
  approx(M.clipEnd(s2.clip(ids2[1])), 5);
  assertInvariants(s2.project);
});

test('trim trailing clamped by media end and neighbour', () => {
  const [store, idList] = storeWithV1([[0, 2], [20, 1]], [3, 0]);
  store.trimClip(idList[0], 'trailing', 50);
  approx(store.clip(idList[0]).duration, 7, 'media is 10 s, sourceIn 3');
  store.trimClip(idList[0], 'trailing', -3);
  approx(store.clip(idList[0]).duration, 1 / 30);

  const [s2, ids2] = storeWithV1([[0, 2], [4, 1]]);
  s2.trimClip(ids2[0], 'trailing', 9);
  approx(M.clipEnd(s2.clip(ids2[0])), 4, 'stops at the next clip');
  assertInvariants(s2.project);
});

test('trim images and text are unbounded', () => {
  const store = makeStore();
  const img = store.addClip(image.id, { time: 10 });
  store.trimClip(img, 'trailing', 100);
  approx(M.clipEnd(store.clip(img)), 100);
  store.trimClip(img, 'leading', 0);
  approx(store.clip(img).start, 0);
  assert.equal(store.clip(img).sourceIn, 0);
  const text = store.addTextClip({ time: 0 });
  store.trimClip(text, 'trailing', 60);
  approx(store.clip(text).duration, 60);
});

test('trim clamps fades and respects lock', () => {
  const [store, idList] = storeWithV1([[0, 6]]);
  store.updateClip(idList[0], 'Fades', c => { c.fadeIn = 2; c.fadeOut = 2; });
  store.trimClip(idList[0], 'trailing', 2);
  const c = store.clip(idList[0]);
  approx(c.fadeIn + c.fadeOut, 2);
  approx(c.fadeIn, 1);

  store.setTrack(store.project.tracks[0].id, { locked: true });
  store.trimClip(idList[0], 'trailing', 5);
  approx(store.clip(idList[0]).duration, 2);
});

test('trim coalescing', () => {
  const [store, idList] = storeWithV1([[0, 2]]);
  const original = store.project;
  for (const t of [2.5, 3.0, 3.5, 4.0]) store.trimClip(idList[0], 'trailing', t, 'trim');
  store.endCoalescing();
  approx(store.clip(idList[0]).duration, 4);
  store.undo();
  sameProject(store.project, original);
});

// MARK: updateClip normalisation

test('updateClip clamps values', () => {
  const store = makeStore();
  const text = store.addTextClip({ time: 0 });
  store.updateClip(text, 'Edit', c => {
    c.transform.opacity = 3;
    c.transform.scale = 0;
    c.volume = -1;
    c.filterIntensity = 7;
    c.fadeIn = 4; c.fadeOut = 6;
    if (c.text) c.text.fontSize = 2;
    c.color.exposure = 9; c.color.brightness = -5; c.color.contrast = 0;
    c.color.saturation = 3; c.color.temperature = -4; c.color.vignette = 2;
    c.id = M.uuid();
  });
  const c = store.clip(text);
  assert.notEqual(c, null, 'id changes are ignored');
  assert.equal(c.transform.opacity, 1);
  assert.equal(c.transform.scale, 0.02);
  assert.equal(c.volume, 0);
  assert.equal(c.filterIntensity, 1);
  approx(c.fadeIn, 2, 'scaled proportionally: 4/10 x 5');
  approx(c.fadeOut, 3);
  assert.equal(c.text.fontSize, 0.6);
  assert.equal(c.color.exposure, 2); assert.equal(c.color.brightness, -1);
  assert.equal(c.color.contrast, 0.25); assert.equal(c.color.saturation, 2);
  assert.equal(c.color.temperature, -1); assert.equal(c.color.vignette, 1);

  store.updateClip(text, 'Edit', x => { x.transform.scale = 100; x.fadeIn = -1; if (x.text) x.text.fontSize = 0; });
  assert.equal(store.clip(text).transform.scale, 20);
  assert.equal(store.clip(text).fadeIn, 0);
  assert.equal(store.clip(text).text.fontSize, 0.01);
});

test('updateClip timing stays valid', () => {
  const [store, idList] = storeWithV1([[0, 2], [2, 2]]);
  store.updateClip(idList[0], 'Duration', c => { c.duration = 50; });
  approx(store.clip(idList[0]).duration, 10, 'bounded by 10 s source');
  assert.ok(store.clip(idList[0]).start >= 4 - 1e-9, 'moved off the neighbour');
  store.updateClip(idList[1], 'Start', c => { c.start = 1.234; });
  const s = store.clip(idList[1]).start * 30;
  approx(s, Math.round(s));
  assertInvariants(store.project);
});

test('updateClip with no change records no undo', () => {
  const [store, idList] = storeWithV1([[0, 2]]);
  store.updateClip(idList[0], 'Opacity', c => { c.transform.opacity = 1; });
  assert.equal(store.canUndo, false);
  store.updateClip(idList[0], 'Opacity', c => { c.transform.opacity = 5; });  // clamps to the current value
  assert.equal(store.canUndo, false);
});

test('updateClip slider coalescing', () => {
  const [store, idList] = storeWithV1([[0, 2]]);
  for (const v of [0.9, 0.7, 0.5, 0.3, 0.1]) {
    store.updateClip(idList[0], 'Opacity', c => { c.transform.opacity = v; }, { coalesce: `opacity-${idList[0]}` });
  }
  store.endCoalescing();
  store.updateClip(idList[0], 'Scale', c => { c.transform.scale = 2; });
  assert.equal(store.undoActionName, 'Scale');
  store.undo();
  approx(store.clip(idList[0]).transform.opacity, 0.1);
  store.undo();
  assert.equal(store.clip(idList[0]).transform.opacity, 1);
  assert.equal(store.canUndo, false);
  assert.equal(store.redoActionName, 'Opacity');
});

// MARK: Detach audio, fades

test('detachAudio', () => {
  const [store, idList] = storeWithV1([[1, 4]], [2]);
  store.updateClip(idList[0], 'Edit', c => { c.volume = 1.5; c.fadeIn = 0.5; c.fadeOut = 1; });
  store.detachAudio(idList[0]);
  assert.equal(store.clip(idList[0]).audioMuted, true);
  const a = store.project.tracks[2].clips[0];
  assert.ok(a);
  assert.equal(a.mediaID, video.id);
  assert.equal(a.start, 1); assert.equal(a.duration, 4); assert.equal(a.sourceIn, 2);
  assert.equal(a.volume, 1.5); assert.equal(a.fadeIn, 0.5); assert.equal(a.fadeOut, 1);
  assert.equal(store.undoActionName, 'Detach Audio');

  // Second detach is a no-op (already muted).
  const revision = store.revision;
  store.detachAudio(idList[0]);
  assert.equal(store.revision, revision);

  store.undo();
  assert.equal(store.clip(idList[0]).audioMuted, false);
  assert.equal(store.project.tracks[2].clips.length, 0);
});

test('detachAudio uses free or new audio track', () => {
  const [store, idList] = storeWithV1([[0, 4]]);
  store.addClip(audio.id, { time: 0 });   // A1 busy
  store.addClip(audio.id, { time: 2 });   // A2 busy
  store.detachAudio(idList[0]);
  assert.equal(store.project.tracks.length, 5);
  assert.equal(store.project.tracks[4].kind, 'audio');
  assert.equal(store.project.tracks[4].clips[0].mediaID, video.id);
  // Silent video / images cannot detach.
  const silent = store.addClip(silentVideo.id, { time: 30 });
  const revision = store.revision;
  store.detachAudio(silent);
  assert.equal(store.revision, revision);
});

test('setFades on selection', () => {
  const [store, idList] = storeWithV1([[0, 2], [2, 4], [6, 1]]);
  store.setSelection([idList[0], idList[1]]);
  store.setFades(1.5, null);
  assert.equal(store.clip(idList[0]).fadeIn, 1.5); assert.equal(store.clip(idList[1]).fadeIn, 1.5);
  assert.equal(store.clip(idList[2]).fadeIn, 0);
  store.setFades(null, 1.5);
  approx(store.clip(idList[0]).fadeIn + store.clip(idList[0]).fadeOut, 2);
  assert.equal(store.clip(idList[1]).fadeOut, 1.5);
  assert.equal(store.clip(idList[1]).fadeIn, 1.5);
  store.undo();
  assert.equal(store.clip(idList[1]).fadeOut, 0);
});

// MARK: Tracks

test('add and remove tracks', () => {
  const store = makeStore();
  const v = store.addTrack('video');
  assert.equal(M.trackIndex(store.project, v), 2);
  const a = store.addTrack('audio');
  assert.equal(M.trackIndex(store.project, a), store.project.tracks.length - 1);

  const clip = store.addClip(image.id, { trackID: v, time: 0 });
  assert.deepEqual(sel(store), [clip]);
  store.removeTrack(v);
  assert.equal(M.trackIndex(store.project, v), -1);
  assert.equal(store.clip(clip), null);
  assert.equal(store.selection.size, 0);

  store.removeTrack(videoTracks(store.project)[0].id);
  assert.equal(videoTracks(store.project).length, 1);
  store.removeTrack(videoTracks(store.project)[0].id);
  assert.equal(videoTracks(store.project).length, 1, 'never remove the last video track');

  const locked = audioTracks(store.project)[0].id;
  store.setTrack(locked, { locked: true });
  store.removeTrack(locked);
  assert.notEqual(M.trackIndex(store.project, locked), -1);
});

test('setTrack flags and undo names', () => {
  const store = makeStore();
  const id = store.project.tracks[0].id;
  store.setTrack(id, { muted: true });
  assert.equal(store.project.tracks[0].isMuted, true);
  assert.equal(store.undoActionName, 'Mute Track');
  store.setTrack(id, { hidden: true, locked: true });
  assert.equal(store.project.tracks[0].isHidden, true);
  assert.equal(store.project.tracks[0].isLocked, true);
  store.undo();
  assert.equal(store.project.tracks[0].isLocked, false);
  assert.equal(store.project.tracks[0].isMuted, true);
});

// MARK: Snapping

test('snapTargets and snap', () => {
  const [store, idList] = storeWithV1([[1, 2], [5, 1]]);
  store.playhead = 4;
  assert.deepEqual(store.snapTargets(), [0, 1, 3, 4, 5, 6]);
  assert.deepEqual(store.snapTargets(new Set([idList[1]])), [0, 1, 3, 4]);
  assert.equal(store.snap(3.08, new Set(), 0.1), 3);
  assert.equal(store.snap(3.5, new Set(), 0.1), 3.5);
  assert.equal(store.snap(5.95, new Set([idList[1]]), 0.1), 5.95);
  assert.equal(store.snap(4.04, new Set(), 0.1), 4, 'playhead');
  store.snappingEnabled = false;
  assert.equal(store.snap(3.08, new Set(), 0.1), 3.08);
});

// MARK: Clipboard & nudge

test('selectAll skips locked tracks', () => {
  const [store, idList] = storeWithV1([[0, 1], [1, 1]]);
  const other = store.addClip(image.id, { trackID: store.project.tracks[1].id, time: 0 });
  store.setTrack(store.project.tracks[1].id, { locked: true });
  store.selectAll();
  assert.deepEqual(sel(store), ids(...idList));
  assert.equal(store.selection.has(other), false);
});

test('copy/paste keeps relative timing and tracks', () => {
  const store = makeStore();
  const v = store.addClip(image.id, { trackID: store.project.tracks[0].id, time: 1 });
  const t = store.addTextClip({ time: 2, trackID: store.project.tracks[1].id });
  const a = store.addClip(audio.id, { time: 1.5 });
  assert.equal(store.canPaste, false);
  store.setSelection([v, t, a]);
  store.copySelection();
  assert.equal(store.canPaste, true);

  store.playhead = 20;
  store.pasteAtPlayhead();
  assert.equal(store.selection.size, 3);
  assert.ok([...store.selection].every(id => ![v, t, a].includes(id)), 'new ids');
  const byTrack = new Map([...store.selection].map(id => [trackOf(store, id), store.clip(id)]));
  approx(byTrack.get(0).start, 20);
  approx(byTrack.get(1).start, 21);
  approx(byTrack.get(2).start, 20.5);
  assert.equal(store.undoActionName, 'Paste');

  // Pasting again at the same spot keeps timing by moving to a free / new track.
  store.pasteAtPlayhead();
  assert.deepEqual(store.selectedClips.map(c => c.start).sort((x, y) => x - y), [20, 20.5, 21]);
  assertInvariants(store.project);
});

test('cut/paste and paste skips removed media', () => {
  const [store, idList] = storeWithV1([[0, 2], [2, 2]]);
  store.setSelection([idList[0]]);
  store.cutSelection();
  assert.equal(store.clip(idList[0]), null);
  assert.equal(store.clip(idList[1]).start, 2, 'cut is not a ripple');
  assert.equal(store.undoActionName, 'Cut');
  store.playhead = 0;
  store.pasteAtPlayhead();
  assert.equal(store.project.tracks[0].clips.length, 2);
  assert.equal(store.project.tracks[0].clips[0].start, 0);

  store.removeMedia(video.id);
  const revision = store.revision;
  store.pasteAtPlayhead();
  assert.equal(store.revision, revision);
});

test('paste into locked track falls back', () => {
  const [store, idList] = storeWithV1([[0, 2]]);
  store.setSelection([idList[0]]);
  store.copySelection();
  store.setTrack(store.project.tracks[0].id, { locked: true });
  store.playhead = 10;
  store.pasteAtPlayhead();
  assert.equal(store.project.tracks[0].clips.length, 1);
  assert.equal(store.project.tracks[1].clips.length, 1);
});

test('nudge clamped by zero and neighbours', () => {
  const [store, idList] = storeWithV1([[0.5, 1], [2, 1], [3, 1], [5, 1]]);
  const f = 1 / 30;
  store.setSelection([idList[1], idList[2]]);
  store.nudgeSelection(3);
  approx(store.clip(idList[1]).start, 2 + 3 * f);
  store.nudgeSelection(1000);
  approx(M.clipEnd(store.clip(idList[2])), 5, 'stopped by the next unselected clip');
  approx(store.clip(idList[1]).start, 3);
  store.nudgeSelection(-1000);
  approx(store.clip(idList[1]).start, 1.5, 'stopped by the previous clip');
  store.endCoalescing();

  store.setSelection([idList[0]]);
  store.nudgeSelection(-100);
  approx(store.clip(idList[0]).start, 0, 'clamped at 0');
  const revision = store.revision;
  store.nudgeSelection(-1);
  assert.equal(store.revision, revision);

  store.setTrack(store.project.tracks[0].id, { locked: true });
  store.nudgeSelection(5);
  approx(store.clip(idList[0]).start, 0);
  assertInvariants(store.project);
});

test('repeated nudges undo together', () => {
  const [store, idList] = storeWithV1([[1, 1]]);
  store.setSelection([idList[0]]);
  for (let i = 0; i < 5; i++) store.nudgeSelection(1);
  store.undo();
  approx(store.clip(idList[0]).start, 1);
});

// MARK: Undo / dirty

test('undo/redo restores exact state', () => {
  const store = makeStore();
  const s0 = store.project;
  const id = store.addClip(video.id, { time: 0 });
  const s1 = store.project;
  store.split(id, 3);
  const s2 = store.project;
  store.selectAll();
  store.deleteSelection(true);
  store.undo(); sameProject(store.project, s2);
  store.undo(); sameProject(store.project, s1);
  store.undo(); sameProject(store.project, s0);
  store.redo(); store.redo();
  sameProject(store.project, s2);
  store.addTextClip({ time: 0 });
  assert.equal(store.canRedo, false, 'new edit clears redo');
});

test('dirty tracking', () => {
  const store = makeStore();
  assert.equal(store.isDirty, true);
  store.newProject();
  assert.equal(store.isDirty, false);
  store.addMedia([image]);
  assert.equal(store.isDirty, true);
  store.undo();
  assert.equal(store.isDirty, false, 'back to the clean state');

  store.addMedia([image]);
  store.save(path.join(tempDir, 'Dirty.editrush'));
  assert.equal(store.isDirty, false);
  store.addTextClip({ time: 0 });
  assert.equal(store.isDirty, true);
  store.undo();
  assert.equal(store.isDirty, false);
  assert.equal(store.project.name, 'Dirty', 'undo never reverts the file name');
});

// MARK: Files

test('save/open round trip', () => {
  const store = makeStore();
  const id = store.addClip(video.id, { time: 1 });
  store.addTextClip({ time: 2 });
  store.updateClip(id, 'Look', c => { c.filter = 'noir'; c.color.contrast = 1.4; c.transform.offsetX = 0.2; });
  const file = path.join(tempDir, 'My Film.editrush');
  store.save(file);
  assert.equal(store.projectPath, file);
  assert.equal(store.project.name, 'My Film');
  assert.equal(store.isDirty, false);

  const json = fs.readFileSync(file, 'utf8');
  assert.ok(json.includes('\n  "'), 'pretty printed');
  const canvasAt = json.indexOf('"canvas"'), mediaAt = json.indexOf('"media"');
  assert.ok(canvasAt >= 0 && mediaAt >= 0 && canvasAt < mediaAt, 'sorted keys');

  const other = new EditorStore();
  other.statusMessage = null;
  other.open(file);
  sameProject(other.project, store.project);
  assert.equal(other.projectPath, file);
  assert.equal(other.isDirty, false);
  assert.equal(other.canUndo, false);
  assert.ok(typeof other.statusMessage === 'string' && other.statusMessage.startsWith('Missing media'),
    `test media files don't exist (status: ${other.statusMessage})`);
});

test('open reports no missing media when files exist', () => {
  const file = path.join(tempDir, 'real.png');
  fs.writeFileSync(file, Buffer.from([0]));
  const p = M.emptyProject();
  p.media = [{ id: M.uuid(), url: M.pathToFileURL(file), name: 'real.png', kind: 'image', duration: 0,
    pixelWidth: 0, pixelHeight: 0, frameRate: 0, hasAudio: false }];
  const projectFile = path.join(tempDir, 'Real.editrush');
  new EditorStore(p).save(projectFile);
  const store = new EditorStore();
  store.open(projectFile);
  assert.equal(store.statusMessage, null);
});

test('open rejects newer version and garbage', () => {
  const p = M.emptyProject();
  p.version = M.CURRENT_VERSION + 1;
  const future = path.join(tempDir, 'Future.editrush');
  fs.writeFileSync(future, JSON.stringify(p));
  const store = makeStore();
  const before = store.project;
  assert.throws(() => store.open(future), err => {
    assert.ok(err instanceof M.ProjectFileError, `expected ProjectFileError, got ${err}`);
    assert.ok(err.message.includes(`format ${M.CURRENT_VERSION + 1}`) && err.message.includes(`reads up to ${M.CURRENT_VERSION}`),
      err.message);
    return true;
  });
  assert.equal(store.project, before);

  const junk = path.join(tempDir, 'Junk.editrush');
  fs.writeFileSync(junk, '{"version": 1}');
  assert.throws(() => store.open(junk), err => {
    assert.ok(err instanceof M.ProjectFileError, `expected ProjectFileError, got ${err}`);
    assert.ok(err.message.startsWith("The file isn't a valid EditRush project ("), err.message);
    return true;
  });
  fs.writeFileSync(junk, 'not json');
  assert.throws(() => store.open(junk), M.ProjectFileError);
});

test('autosave and restore', () => {
  const store = makeStore();
  store.autosaveFile = path.join(tempDir, 'Nested', 'Autosave.editrush');
  store.addTextClip({ time: 0 });
  const saved = path.join(tempDir, 'Proj.editrush');
  store.save(saved);
  store.addTextClip({ time: 10 });
  store.autosave();
  assert.ok(fs.existsSync(store.autosaveFile));
  assert.ok(fs.existsSync(path.join(tempDir, 'Nested', 'Autosave.state.json')));

  const restored = new EditorStore();
  restored.autosaveFile = store.autosaveFile;
  assert.equal(restored.restoreAutosave(), true);
  sameProject(restored.project, store.project);
  assert.equal(restored.projectPath, saved);
  assert.equal(restored.isDirty, false);

  const missing = new EditorStore();
  missing.autosaveFile = path.join(tempDir, 'None', 'Autosave.editrush');
  assert.equal(missing.restoreAutosave(), false);
});

test('autosave skips unchanged and reflects latest edit', () => {
  const store = makeStore();
  store.autosaveFile = path.join(tempDir, 'Autosave.editrush');
  store.autosave();
  fs.unlinkSync(store.autosaveFile);
  store.autosave();   // nothing changed -> no write
  assert.equal(fs.existsSync(store.autosaveFile), false);
  store.addTextClip({ time: 3 });
  store.autosave();
  const restored = new EditorStore();
  restored.autosaveFile = store.autosaveFile;
  assert.equal(restored.restoreAutosave(), true);
  sameProject(restored.project, store.project);
  assert.equal(restored.projectPath, null);
});

// MARK: Group moves & duplicates

/// V1: 10 s video at 0 with its audio detached onto A1 (0-10); A1 also holds music at 14-22.
function storeWithDetachedPairAndMusic() {
  const [store, idList] = storeWithV1([[0, 10]]);
  store.detachAudio(idList[0]);
  const a1 = store.project.tracks[2];
  const detached = a1.clips[0].id;
  const music = store.addClip(audio.id, { trackID: a1.id, time: 14 });
  assert.equal(store.clip(music).start, 14);
  return { store, v: idList[0], a: detached, music };
}

test('moveClips keeps detached pair in sync', () => {
  const { store, v, a, music } = storeWithDetachedPairAndMusic();
  const original = store.project;
  const key = `drag-${M.uuid()}`;
  // Live drag in small steps towards +6: the pair stops together against the music (+4).
  let applied = 0;
  for (let target = 0.5; target <= 6; target += 0.5) {
    store.moveClips(new Set([v, a]), target - applied, 0, key);
    applied = store.clip(v).start;
    assert.equal(store.clip(a).start, store.clip(v).start, `target ${target}`);
  }
  approx(store.clip(v).start, 4);
  // Dragging further jumps the whole group past the music, still in sync.
  store.moveClips(new Set([v, a]), 20 - applied, 0, key);
  approx(store.clip(v).start, 22);
  approx(store.clip(a).start, 22);
  assert.equal(store.clip(music).start, 14, 'unselected clips never move');
  assert.equal(trackOf(store, a), 2);
  store.endCoalescing();
  assertInvariants(store.project);
  assert.equal(store.undoActionName, 'Move Clips');
  store.undo();
  sameProject(store.project, original, 'the whole drag is one undo step');
});

test('moveClips blocked by unselected neighbour and zero', () => {
  const [store, idList] = storeWithV1([[0, 5], [10, 5], [16, 4]]);
  const pair = new Set([idList[0], idList[1]]);
  store.moveClips(pair, 3);
  approx(store.clip(idList[0]).start, 1, 'clamped by the unselected clip at 16');
  approx(store.clip(idList[1]).start, 11);
  store.moveClips(pair, -5);
  approx(store.clip(idList[0]).start, 0, 'clamped at 0');
  approx(store.clip(idList[1]).start, 10);
  // A requested shift past the obstacle uses the nearest spot where the whole group fits
  // (here the group straddles the unselected clip: [11, 16) C [16, 20) [21, 26)).
  store.moveClips(pair, 12);
  approx(store.clip(idList[0]).start, 11);
  approx(store.clip(idList[1]).start, 21);
  approx(store.clip(idList[2]).start, 16);
  // Shifts are whole frames.
  store.moveClips(pair, -0.51 / 30);
  approx(store.clip(idList[0]).start, 11 - 1 / 30);
  approx(store.clip(idList[1]).start, 21 - 1 / 30);
  assertInvariants(store.project);
});

test('moveClips leaves locked tracks alone', () => {
  const [store, idList] = storeWithV1([[0, 2]]);
  const v2 = store.project.tracks[1].id;
  const other = store.addClip(video.id, { trackID: v2, time: 0 });
  store.setTrack(v2, { locked: true });
  store.moveClips(new Set([idList[0], other]), 3);
  approx(store.clip(idList[0]).start, 3);
  assert.equal(store.clip(other).start, 0, 'clips on locked tracks stay put');
  // Moving onto the locked V2 is refused; the time shift still applies.
  store.moveClips(new Set([idList[0]]), 1, 1);
  assert.equal(trackOf(store, idList[0]), 0);
  approx(store.clip(idList[0]).start, 4);
  const revision = store.revision;
  store.moveClips(new Set([other]), 5);
  assert.equal(store.revision, revision);
});

test('moveClips track offset', () => {
  const { store, v, a } = storeWithDetachedPairAndMusic();
  // Both kinds move one track up their own order: V1 -> V2, A1 -> A2.
  store.moveClips(new Set([v, a]), 0, 1);
  assert.equal(trackOf(store, v), 1);
  assert.equal(trackOf(store, a), 3);
  assert.equal(store.clip(v).start, 0);
  assert.equal(store.clip(a).start, 0);
  // No V3 / A3: the offset is refused as a whole, the time shift still applies.
  store.moveClips(new Set([v, a]), 2, 1);
  assert.equal(trackOf(store, v), 1);
  assert.equal(trackOf(store, a), 3);
  approx(store.clip(v).start, 2);
  approx(store.clip(a).start, 2);
  // Back down onto A1 and +3 s, where the music limits the shared shift to +2 (start 4).
  store.moveClips(new Set([v, a]), 3, -1);
  assert.equal(trackOf(store, v), 0);
  assert.equal(trackOf(store, a), 2);
  approx(store.clip(v).start, 4);
  approx(store.clip(a).start, 4);
  assertInvariants(store.project);
});

test('duplicate keeps group timing', () => {
  const { store, v, a, music } = storeWithDetachedPairAndMusic();
  store.setSelection([v, a]);
  store.duplicateSelection();
  const copies = store.selectedClips;
  assert.equal(copies.length, 2);
  assert.equal(store.selection.has(v) || store.selection.has(a) || store.selection.has(music), false);
  assert.deepEqual(copies.map(c => c.start), [22, 22], 'one shared offset, past the music on A1');
  assert.deepEqual(new Set(copies.map(c => trackOf(store, c.id))), new Set([0, 2]));
  assertInvariants(store.project);
  store.undo();
  assert.equal(store.project.tracks.flatMap(t => t.clips).length, 3);
});

test('duplicate skips locked tracks', () => {
  const [store, idList] = storeWithV1([[0, 2]]);
  store.setSelection([idList[0]]);
  store.setTrack(store.project.tracks[0].id, { locked: true });
  const revision = store.revision;
  store.duplicateSelection();
  assert.equal(store.revision, revision);
  assert.deepEqual(sel(store), [idList[0]]);
});

// MARK: Coalescing

test('coalesced gesture survives pause', async () => {
  const [store, idList] = storeWithV1([[0, 2]]);
  const v1 = store.project.tracks[0].id;
  const key = `timeline-move-${M.uuid()}`;
  store.moveClip(idList[0], v1, 2, key);
  await sleep(1600);   // mouse held still
  store.moveClip(idList[0], v1, 3, key);
  store.endCoalescing();
  store.undo();
  approx(store.clip(idList[0]).start, 0);
  assert.equal(store.canUndo, false);
});

test('coalescing ends on other key or plain mutate', () => {
  const [store, idList] = storeWithV1([[0, 2]]);
  const id = idList[0];
  store.updateClip(id, 'Opacity', c => { c.transform.opacity = 0.5; }, { coalesce: 'a' });
  store.updateClip(id, 'Opacity', c => { c.transform.opacity = 0.4; }, { coalesce: 'b' });
  store.updateClip(id, 'Opacity', c => { c.transform.opacity = 0.3; }, { coalesce: 'b' });
  store.updateClip(id, 'Scale', c => { c.transform.scale = 2; });
  store.updateClip(id, 'Opacity', c => { c.transform.opacity = 0.2; }, { coalesce: 'b' });
  store.undo();
  approx(store.clip(id).transform.opacity, 0.3);
  store.undo();
  approx(store.clip(id).transform.scale, 1);
  store.undo();
  approx(store.clip(id).transform.opacity, 0.5);
  store.undo();
  assert.equal(store.canUndo, false);
});

test('coalesceTimeout is opt-in', async () => {
  const [store, idList] = storeWithV1([[0, 2]]);
  const id = idList[0];
  const opts = { coalesce: 'color', coalesceTimeout: 0.05 };
  store.updateClip(id, 'Color', c => { c.transform.opacity = 0.5; }, opts);
  store.updateClip(id, 'Color', c => { c.transform.opacity = 0.4; }, opts);
  await sleep(100);
  store.updateClip(id, 'Color', c => { c.transform.opacity = 0.3; }, opts);
  store.undo();
  approx(store.clip(id).transform.opacity, 0.4);
  store.undo();
  assert.equal(store.canUndo, false);
});

test('addClips coalesce into one undo step', () => {
  const store = makeStore();
  const before = store.project;
  const key = `drop-${M.uuid()}`;
  let t = 0;
  for (const id of [video.id, image.id, silentVideo.id]) {
    const clip = store.addClip(id, { time: t, coalesce: key });
    t = M.clipEnd(store.clip(clip));
  }
  store.endCoalescing();
  assert.deepEqual(store.project.tracks[0].clips.map(c => c.start), [0, 10, 15]);
  store.undo();
  sameProject(store.project, before);
  // Without a key every add is its own step.
  store.addClip(video.id, { time: 0 });
  store.addClip(image.id, { time: 10 });
  store.undo();
  assert.equal(store.project.tracks[0].clips.length, 1);
});

test('detachAudio coalesces into one undo step', () => {
  const [store, idList] = storeWithV1([[0, 2], [4, 2], [8, 2]]);
  const before = store.project;
  const key = `detach-${M.uuid()}`;
  for (const id of idList) store.detachAudio(id, key);
  store.endCoalescing();
  assert.equal(store.project.tracks[2].clips.length, 3);
  assert.ok(idList.every(id => store.clip(id).audioMuted));
  store.undo();
  sameProject(store.project, before);
  assert.equal(store.canUndo, false);
});

test('undo limit', () => {
  assert.equal(UNDO_LIMIT, 1000);
  const [store, idList] = storeWithV1([[0, 2]]);
  for (let i = 0; i < UNDO_LIMIT + 5; i++) {
    store.updateClip(idList[0], 'Opacity', c => { c.transform.opacity = i % 2 === 0 ? 0.5 : 0.25; });
  }
  let undos = 0;
  while (store.canUndo) { store.undo(); undos++; }
  assert.equal(undos, UNDO_LIMIT);
});

// MARK: Hidden tracks

test('automatic placement skips hidden tracks', () => {
  const store = makeStore();
  const v1 = store.project.tracks[0].id, v2 = store.project.tracks[1].id, a1 = store.project.tracks[2].id;
  store.setTrack(v2, { hidden: true });
  const title = store.addTextClip({ time: 0 });
  assert.equal(M.trackContaining(store.project, title).id, v1, 'topmost visible video track');
  const second = store.addTextClip({ time: 0 });
  assert.equal(store.project.tracks.length, 5, 'V1 busy, V2 hidden: a new video track');
  assert.equal(trackOf(store, second), 2);
  assert.equal(store.project.tracks[2].isHidden, false);

  store.setTrack(a1, { hidden: true });
  const music = store.addClip(audio.id, { time: 0 });
  assert.equal(M.trackContaining(store.project, music).kind, 'audio');
  assert.notEqual(M.trackContaining(store.project, music).id, a1);

  // An explicit hidden target is respected.
  const explicit = store.addClip(video.id, { trackID: v2, time: 0 });
  assert.equal(M.trackContaining(store.project, explicit).id, v2);
  assertInvariants(store.project);
});

test('detachAudio skips hidden audio track', () => {
  const [store, idList] = storeWithV1([[0, 2]]);
  store.setTrack(store.project.tracks[2].id, { hidden: true });
  store.detachAudio(idList[0]);
  assert.equal(store.project.tracks[2].clips.length, 0);
  assert.equal(store.project.tracks[3].clips.length, 1);
});

// MARK: Invariants under a random edit sequence

/// Deterministic SplitMix64 so the randomized test is reproducible.
class SeededGenerator {
  constructor(seed) { this.state = BigInt.asUintN(64, BigInt(seed)); }
  next() {
    this.state = BigInt.asUintN(64, this.state + 0x9E3779B97F4A7C15n);
    let z = this.state;
    z = BigInt.asUintN(64, (z ^ (z >> 30n)) * 0xBF58476D1CE4E5B9n);
    z = BigInt.asUintN(64, (z ^ (z >> 27n)) * 0x94D049BB133111EBn);
    return z ^ (z >> 31n);
  }
  /// Uniform in [0, 1).
  unit() { return Number(this.next() >> 11n) / 2 ** 53; }
  /// Uniform in [lo, hi].
  double(lo, hi) { return lo + (hi - lo) * this.unit(); }
  /// Uniform integer in [lo, hi].
  int(lo, hi) { return lo + Math.floor(this.unit() * (hi - lo + 1)); }
  bool() { return (this.next() & 1n) === 1n; }
  element(arr) { return arr.length ? arr[this.int(0, arr.length - 1)] : undefined; }
}

function runRandomEdits(seed, steps) {
  const rng = new SeededGenerator(seed);
  const store = makeStore();
  const mediaIDs = [video.id, silentVideo.id, audio.id, image.id];
  const randomSelection = clips => clips.filter(() => rng.bool()).map(c => c.id);
  for (let step = 0; step < steps; step++) {
    const clips = store.project.tracks.flatMap(t => t.clips);
    const any = rng.element(clips);
    const canGrow = clips.length < 80;
    const fades = () => {
      store.setSelection(randomSelection(clips));
      store.setFades(rng.double(0, 5), rng.double(0, 5));
    };
    switch (rng.int(0, 19)) {
      case 18:
        store.moveClips(new Set(randomSelection(clips)), rng.double(-20, 20), rng.int(-2, 2));
        break;
      case 19: { const track = rng.element(store.project.tracks); if (track) store.setTrack(track.id, { hidden: rng.bool() }); break; }
      case 0: case 1: store.addClip(rng.element(mediaIDs), { time: rng.double(0, 30) }); break;
      case 2: store.addTextClip({ time: rng.double(0, 30) }); break;
      case 3: if (any) store.split(any.id, rng.double(any.start, M.clipEnd(any))); break;
      case 4: {
        const track = rng.element(store.project.tracks);
        if (any && track) store.moveClip(any.id, track.id, rng.double(0, 40));
        break;
      }
      case 5: if (any) store.trimClip(any.id, rng.bool() ? 'leading' : 'trailing', rng.double(0, 40)); break;
      case 6: store.setSelection(randomSelection(clips)); store.deleteSelection(rng.bool()); break;
      case 7: if (canGrow) { store.setSelection(randomSelection(clips)); store.duplicateSelection(); } else fades(); break;
      case 8: store.setSelection(randomSelection(clips)); store.nudgeSelection(rng.int(-40, 40)); break;
      case 9: if (canGrow) { store.copySelection(); store.playhead = rng.double(0, 30); store.pasteAtPlayhead(); } else fades(); break;
      case 10: store.setSelection(randomSelection(clips)); store.closeGaps(); break;
      case 11: if (rng.bool()) store.undo(); else store.redo(); break;
      case 12: store.playhead = rng.double(0, 30); store.setSelection(randomSelection(clips)); store.splitAtPlayhead(); break;
      case 13: store.setSelection(randomSelection(clips)); store.joinSelection(); break;
      case 14: if (any) store.detachAudio(any.id); break;
      case 15:
        if (any) {
          store.updateClip(any.id, 'Random', c => {
            c.duration = rng.double(-1, 20);
            c.start = rng.double(-5, 30);
            c.fadeIn = rng.double(-1, 10);
          });
        }
        break;
      case 16: { const track = rng.element(store.project.tracks); if (track) store.setTrack(track.id, { locked: rng.bool() }); break; }
      default: fades();
    }
    assertInvariants(store.project, `seed ${seed} step ${step}`);
  }
}

test('random edit sequence keeps invariants', () => {
  for (const seed of [0xED172025, 1, 2, 3, 42, 31337]) runRandomEdits(seed, 500);
});
