'use strict';
// Locating and running ffmpeg / ffprobe. They must be on PATH (or next to the app in ffmpeg\).

const { spawn, execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const resolved = {};

/// Absolute path of `name` ('ffmpeg' or 'ffprobe'). Throws with instructions when it is not installed.
function tool(name) {
  if (resolved[name]) return resolved[name];
  const local = path.join(__dirname, '..', '..', 'ffmpeg', `${name}.exe`);
  if (fs.existsSync(local)) return (resolved[name] = local);
  let found = null;
  try {
    found = execFileSync('where.exe', [name], { encoding: 'utf8', windowsHide: true }).split(/\r?\n/).find(Boolean);
  } catch (e) {
    throw new Error(`${name}.exe was not found. Install ffmpeg (https://www.gyan.dev/ffmpeg/builds/) and add its bin folder to PATH, ` +
      `or copy ${name}.exe into ${path.dirname(local)}. (where.exe: ${e.message.trim()})`);
  }
  return (resolved[name] = found.trim());
}

/// Runs a tool to completion. Resolves { stdout: Buffer, stderr: string }; rejects with stderr on failure.
function run(name, args, { maxBuffer = 2 ** 30 } = {}) {
  return new Promise((resolve, reject) => {
    const proc = spawn(tool(name), args, { windowsHide: true });
    const out = [];
    let size = 0;
    let err = '';
    proc.stdout.on('data', d => {
      size += d.length;
      if (size > maxBuffer) { proc.kill(); reject(new Error(`${name} output exceeded ${maxBuffer} bytes`)); return; }
      out.push(d);
    });
    proc.stderr.on('data', d => { err += d.toString(); if (err.length > 200000) err = err.slice(-100000); });
    proc.on('error', reject);
    proc.on('close', code => {
      if (code === 0) resolve({ stdout: Buffer.concat(out), stderr: err });
      else reject(new Error(`${name} ${args.join(' ')} exited with code ${code}: ${err.trim().split(/\r?\n/).slice(-4).join(' | ')}`));
    });
  });
}

module.exports = { tool, run, spawn: (name, args) => spawn(tool(name), args, { windowsHide: true }) };
