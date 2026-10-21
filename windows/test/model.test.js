'use strict';
// Port of Tests/EditRushCoreTests/ModelTests.swift.

const test = require('node:test');
const assert = require('node:assert/strict');
const M = require('../src/core/model');

function approx(actual, expected, msg, eps = 1e-9) {
  assert.ok(Math.abs(actual - expected) <= eps, `${msg || 'value'}: expected ${expected}, got ${actual}`);
}

test('fadeFactor', () => {
  const c = M.makeClip({ start: 10, duration: 4 });
  c.fadeIn = 1; c.fadeOut = 2;
  approx(M.fadeFactor(c, 10), 0);
  approx(M.fadeFactor(c, 10.5), 0.5);
  approx(M.fadeFactor(c, 11.5), 1);
  approx(M.fadeFactor(c, 13), 0.5);
  approx(M.fadeFactor(c, 14), 0);
});

test('geometry fit and offset', () => {
  const canvas = { width: 1920, height: 1080 };
  const t = M.defaultTransform();
  const r = M.clipRect({ width: 1080, height: 1920 }, canvas, t, false);
  approx(r.height, 1080, 'height', 0.01);
  approx(r.x + r.width / 2, 960, 'midX', 0.01);
  t.scale = 0.5; t.offsetX = 0.25; t.offsetY = -0.25;
  const r2 = M.clipRect({ width: 1920, height: 1080 }, canvas, t, false);
  approx(r2.width, 960, 'width', 0.01);
  approx(r2.x + r2.width / 2, 1440, 'midX', 0.01);
  approx(r2.y + r2.height / 2, 270, 'midY', 0.01);
});

test('project JSON round trip', () => {
  const p = M.emptyProject();
  p.tracks[0].clips.push(M.makeClip({ start: 1, duration: 2, text: M.defaultTextStyle('Hi') }));
  const decoded = M.decodeProject(M.encodeProject(p));
  assert.deepEqual(decoded, p);
  assert.ok(M.deepEqual(decoded, p));
});
