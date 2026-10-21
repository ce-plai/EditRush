'use strict';
// The single source of truth for the open project and editor UI state.
// Port of EditorStore.swift, EditorStore+Clips.swift and EditorStore+Tracks.swift.
// All project edits go through `mutate`, so undo/redo, dirty tracking, autosave and
// engine notifications happen in one place.
//
// Events (via `on(name, fn)`):
//   'project'  - the project changed (edit, undo, redo, load). Arg: project.
//   'ui'       - editor UI state changed (selection, playhead, zoom, snapping, status).

const fs = require('fs');
const path = require('path');
const M = require('./model');
const R = require('./rules');

const UNDO_LIMIT = 1000;
// The macOS build's minimum is 5 px/s; 0.5 lets Zoom to Fit show recordings up to about 40 minutes.
const ZOOM_MIN = 0.5, ZOOM_MAX = 2000;

class EditorStore {
  constructor(project = M.emptyProject()) {
    this.project = project;
    this.projectPath = null;
    this.isDirty = false;
    this.revision = 0;

    this.selection = new Set();
    this.selectedMediaID = null;
    this.playhead = 0;
    this.pixelsPerSecond = 80;
    this.snappingEnabled = true;
    this.statusMessage = null;
    this.timelineViewportWidth = 1000;

    this.clipboard = [];
    this.undoStack = [];
    this.redoStack = [];
    this.lastCoalesceKey = null;
    this.lastCoalesceDate = 0;
    this.cleanProject = M.clone(project);
    this.autosaveFile = null;
    this.lastAutosaved = null;
    this.listeners = { project: [], ui: [] };
  }

  on(name, fn) { this.listeners[name].push(fn); return () => { this.listeners[name] = this.listeners[name].filter(f => f !== fn); }; }
  emit(name) { for (const fn of this.listeners[name]) fn(this.project); }

  // MARK: UI state setters (not part of undo)

  setSelection(ids) {
    const next = new Set(ids);
    if (next.size === this.selection.size && [...next].every(id => this.selection.has(id))) return;
    this.selection = next;
    this.emit('ui');
  }
  setPlayhead(t) { if (t !== this.playhead) { this.playhead = t; this.emit('ui'); } }
  setStatus(message) { this.statusMessage = message; this.emit('ui'); }
  setSelectedMedia(id) { if (id !== this.selectedMediaID) { this.selectedMediaID = id; this.emit('ui'); } }
  setPixelsPerSecond(v) {
    const next = Math.min(ZOOM_MAX, Math.max(ZOOM_MIN, v));
    if (next !== this.pixelsPerSecond) { this.pixelsPerSecond = next; this.emit('ui'); }
  }
  toggleSnapping() { this.snappingEnabled = !this.snappingEnabled; this.emit('ui'); }

  get undoActionName() { return this.undoStack.length ? this.undoStack[this.undoStack.length - 1].name : null; }
  get redoActionName() { return this.redoStack.length ? this.redoStack[this.redoStack.length - 1].name : null; }
  get canUndo() { return this.undoStack.length > 0; }
  get canRedo() { return this.redoStack.length > 0; }
  get frameDuration() { return M.frameDuration(this.project.canvas); }

  // MARK: Core mutation

  /// Applies `body(projectCopy)` as one undoable action.
  /// `coalesce`: when equal to the previous action's key, no new undo step is recorded (until
  /// `endCoalescing()`, undo/redo, or a mutation with a different key).
  /// `coalesceTimeout` (seconds): also starts a new step when this long passed since the previous edit.
  mutate(actionName, body, { coalesce = null, coalesceTimeout = null } = {}) {
    const next = M.clone(this.project);
    body(next);
    if (M.deepEqual(next, this.project)) return false;
    const now = Date.now();
    const coalescing = coalesce !== null && coalesce === this.lastCoalesceKey
      && (coalesceTimeout === null || (now - this.lastCoalesceDate) / 1000 < coalesceTimeout);
    if (!coalescing) {
      this.undoStack.push({ name: actionName, project: this.project });
      if (this.undoStack.length > UNDO_LIMIT) this.undoStack.splice(0, this.undoStack.length - UNDO_LIMIT);
    }
    this.redoStack = [];
    this.lastCoalesceKey = coalesce;
    this.lastCoalesceDate = now;
    this.apply(next);
    return true;
  }

  endCoalescing() { this.lastCoalesceKey = null; }

  undo() {
    const step = this.undoStack.pop();
    if (!step) return;
    this.redoStack.push({ name: step.name, project: this.project });
    this.lastCoalesceKey = null;
    this.apply(this.keepingName(step.project));
  }

  redo() {
    const step = this.redoStack.pop();
    if (!step) return;
    this.undoStack.push({ name: step.name, project: this.project });
    this.lastCoalesceKey = null;
    this.apply(this.keepingName(step.project));
  }

  /// The project name follows the file name, so history never reverts it.
  keepingName(p) { const c = M.clone(p); c.name = this.project.name; return c; }

  /// Replaces the whole project without recording undo (load / new). Clears undo history.
  replaceProject(p, filePath) {
    this.undoStack = []; this.redoStack = []; this.lastCoalesceKey = null;
    this.projectPath = filePath;
    this.selection = new Set();
    this.selectedMediaID = null;
    this.playhead = 0;
    this.cleanProject = M.clone(p);
    this.apply(p);
    this.isDirty = false;
    this.emit('ui');
  }

  apply(p) {
    this.project = p;
    this.isDirty = !M.deepEqual(p, this.cleanProject);
    this.revision += 1;
    if (this.selection.size) {
      const existing = new Set(p.tracks.flatMap(t => t.clips.map(c => c.id)));
      const kept = [...this.selection].filter(id => existing.has(id));
      if (kept.length !== this.selection.size) this.selection = new Set(kept);
    }
    this.emit('project');
  }

  // MARK: Queries

  clip(id) { return M.findClip(this.project, id); }
  media(id) { return M.findMedia(this.project, id); }
  get selectedClips() {
    return [...this.selection].map(id => this.clip(id)).filter(Boolean).sort((a, b) => a.start - b.start);
  }
  get primarySelection() { return this.selection.size === 1 ? this.clip([...this.selection][0]) : null; }

  // MARK: Media

  /// Adds imported media to the bin (dedupes by standardized URL - "." / ".." segments and
  /// percent-encoding normalized - case-insensitively as on Windows).
  addMedia(items) {
    const key = u => new URL(u).href.toLowerCase();
    this.mutate('Import Media', p => {
      const known = new Set(p.media.map(m => key(m.url)));
      for (const item of items) {
        const k = key(item.url);
        if (known.has(k)) continue;
        known.add(k);
        p.media.push(M.clone(item));
      }
    });
  }

  /// Removes media and every clip that uses it.
  removeMedia(id) {
    this.mutate('Remove Media', p => {
      p.media = p.media.filter(m => m.id !== id);
      for (const t of p.tracks) t.clips = t.clips.filter(c => c.mediaID !== id);
    });
    if (this.selectedMediaID === id) this.setSelectedMedia(null);
  }

  /// Points media `id` at a new file (relink). `probed` carries the new file's facts.
  relinkMedia(id, probed) {
    this.mutate('Relink Media', p => {
      const m = p.media.find(x => x.id === id);
      if (!m) return;
      Object.assign(m, { url: probed.url, duration: probed.duration, pixelWidth: probed.pixelWidth,
        pixelHeight: probed.pixelHeight, frameRate: probed.frameRate, hasAudio: probed.hasAudio });
    });
  }

  // MARK: Zoom

  zoom(factor) { this.setPixelsPerSecond(this.pixelsPerSecond * factor); }
  zoomToFit() {
    const d = Math.max(M.projectDuration(this.project), 5) * 1.05;
    this.setPixelsPerSecond(this.timelineViewportWidth / d);
  }

  // MARK: Canvas

  setCanvas(c) { this.mutate('Change Canvas', p => { p.canvas = M.clone(c); }); }

  // MARK: Project files

  /// Writes the project as pretty JSON and clears isDirty. The project takes its name from the file name.
  save(filePath) {
    const p = M.clone(this.project);
    p.name = path.basename(filePath, path.extname(filePath));
    writeAtomic(filePath, M.encodeProject(p));
    this.projectPath = filePath;
    if (!M.deepEqual(p, this.project)) { this.project = p; this.revision += 1; this.emit('project'); }
    this.cleanProject = M.clone(p);
    this.isDirty = false;
    this.emit('ui');
  }

  /// Loads a .editrush file (replaces the project, clears undo). Throws ProjectFileError.
  open(filePath) {
    const p = M.decodeProject(fs.readFileSync(filePath, 'utf8'));
    p.name = path.basename(filePath, path.extname(filePath));
    this.replaceProject(p, filePath);
    this.reportMissingMedia();
  }

  newProject() { this.replaceProject(M.emptyProject(), null); }

  /// Writes the project to `autosaveFile` plus a sidecar recording `projectPath`.
  /// Skipped when nothing changed since the last autosave.
  autosave() {
    if (!this.autosaveFile) throw new Error('EditorStore.autosave: autosaveFile is not set');
    if (this.lastAutosaved && this.lastAutosaved.revision === this.revision && this.lastAutosaved.path === this.projectPath) return;
    this.lastAutosaved = { revision: this.revision, path: this.projectPath };
    fs.mkdirSync(path.dirname(this.autosaveFile), { recursive: true });
    writeAtomic(autosaveStatePath(this.autosaveFile), JSON.stringify({ projectURL: this.projectPath ? M.pathToFileURL(this.projectPath) : null }));
    writeAtomic(this.autosaveFile, JSON.stringify(this.project));
  }

  /// Restores the autosave if present (on launch). Returns true if restored.
  restoreAutosave() {
    if (!this.autosaveFile || !fs.existsSync(this.autosaveFile)) return false;
    const p = M.decodeProject(fs.readFileSync(this.autosaveFile, 'utf8'));
    let projectPath = null;
    const statePath = autosaveStatePath(this.autosaveFile);
    if (fs.existsSync(statePath)) {
      const state = JSON.parse(fs.readFileSync(statePath, 'utf8'));
      if (state.projectURL) projectPath = M.fileURLToPath(state.projectURL);
    }
    this.replaceProject(p, projectPath);
    this.lastAutosaved = { revision: this.revision, path: this.projectPath };
    this.reportMissingMedia();
    return true;
  }

  reportMissingMedia() {
    const missing = this.project.media.filter(m => !mediaFileExists(m));
    if (!missing.length) return;
    const names = missing.slice(0, 3).map(m => path.basename(mediaPath(m))).join(', ');
    const more = missing.length > 3 ? ` and ${missing.length - 3} more` : '';
    this.setStatus(`Missing media: ${names}${more}`);
  }

  // MARK: - Clips

  /// Places a clip for `mediaID` on the timeline (see Swift docs). Selects it and returns its id.
  addClip(mediaID, { trackID = null, time = null, coalesce = null } = {}) {
    const m = this.media(mediaID);
    if (!m) return null;
    const canvas = this.project.canvas;
    const duration = m.kind === 'image' || m.duration <= 0 ? 5 : Math.max(M.frameDuration(canvas), R.floorFrame(m.duration, canvas));
    const clip = M.makeClip({ mediaID, start: M.quantize(canvas, Math.max(0, time ?? this.playhead)), duration });
    const kind = m.kind === 'audio' ? 'audio' : 'video';
    this.mutate('Add Clip', p => { R.place(clip, kind, trackID, false, p); }, { coalesce });
    this.setSelection([clip.id]);
    return clip.id;
  }

  /// Adds a 5 s text clip at `time` (null = playhead) on `trackID` (null = topmost free video track).
  addTextClip({ time = null, trackID = null, style = M.defaultTextStyle() } = {}) {
    const canvas = this.project.canvas;
    const clip = M.makeClip({ start: M.quantize(canvas, Math.max(0, time ?? this.playhead)), duration: 5, text: M.clone(style) });
    this.mutate('Add Text', p => {
      R.normalize(clip, p);
      R.place(clip, 'video', trackID, true, p);
    });
    this.setSelection([clip.id]);
    return clip.id;
  }

  /// Splits the selected clips under the playhead, or every clip on unlocked tracks under it.
  splitAtPlayhead() {
    const t = M.quantize(this.project.canvas, this.playhead);
    const frame = this.frameDuration;
    const selected = [], all = [];
    for (const track of this.project.tracks) {
      if (track.isLocked) continue;
      for (const c of track.clips) {
        if (!R.canSplit(c, t, frame)) continue;
        all.push(c.id);
        if (this.selection.has(c.id)) selected.push(c.id);
      }
    }
    const targets = selected.length ? selected : all;
    if (!targets.length) return;
    let rights = [];
    this.mutate('Split', p => { rights = targets.map(id => R.split(id, t, p)).filter(Boolean); });
    if (rights.length) this.setSelection(rights);
  }

  split(clipID, t) {
    let right = null;
    this.mutate('Split', p => { right = R.split(clipID, t, p); });
    if (right) this.setSelection([right]);
    return right;
  }

  get canJoinSelection() { return this.joinCandidates() !== null; }

  joinSelection() {
    const jc = this.joinCandidates();
    if (!jc) return;
    const { ti, clips } = jc;
    const first = clips[0], last = clips[clips.length - 1];
    this.mutate('Join Clips', p => {
      const merged = M.clone(first);
      merged.duration = M.quantize(p.canvas, M.clipEnd(last) - first.start);
      merged.fadeOut = last.fadeOut;
      R.clampFades(merged);
      const removed = new Set(clips.slice(1).map(c => c.id));
      p.tracks[ti].clips = p.tracks[ti].clips.filter(c => !removed.has(c.id));
      const ci = p.tracks[ti].clips.findIndex(c => c.id === first.id);
      if (ci >= 0) p.tracks[ti].clips[ci] = merged;
    });
    this.setSelection([first.id]);
  }

  joinCandidates() {
    if (this.selection.size < 2) return null;
    const locations = [...this.selection].map(id => M.locate(this.project, id)).filter(Boolean);
    if (locations.length !== this.selection.size) return null;
    const ti = locations[0].track;
    if (!locations.every(l => l.track === ti) || this.project.tracks[ti].isLocked) return null;
    const clips = locations.map(l => l.clip).sort((a, b) => a - b).map(i => this.project.tracks[ti].clips[i]);
    for (let i = 0; i + 1 < clips.length; i++) {
      if (!R.continues(clips[i], clips[i + 1], this.project, this.frameDuration)) return null;
    }
    return { ti, clips };
  }

  /// Removes the gap before each selected clip (or all gaps with no selection). Locked tracks untouched.
  closeGaps() {
    const targets = new Set(this.selection);
    this.mutate('Close Gaps', p => {
      for (const track of p.tracks) {
        if (track.isLocked) continue;
        const clips = track.clips;
        let previousEnd = 0;
        for (let i = 0; i < clips.length; i++) {
          const gap = clips[i].start - previousEnd;
          if (gap > R.EPS && (targets.size === 0 || targets.has(clips[i].id))) {
            for (let j = i; j < clips.length; j++) clips[j].start = Math.max(0, M.quantize(p.canvas, clips[j].start - gap));
          }
          previousEnd = M.clipEnd(clips[i]);
        }
      }
    });
  }

  /// Deletes selected clips. `ripple` shifts later clips on the same track left by the deleted length.
  deleteSelection(ripple) {
    const targets = new Set(this.selection);
    if (!targets.size) return;
    this.mutate(ripple ? 'Ripple Delete' : 'Delete', p => {
      for (const track of p.tracks) {
        if (track.isLocked) continue;
        const doomed = track.clips.filter(c => targets.has(c.id)).sort((a, b) => b.start - a.start);
        for (const d of doomed) {
          track.clips = track.clips.filter(c => c.id !== d.id);
          if (!ripple) continue;
          for (const c of track.clips) {
            if (c.start >= M.clipEnd(d) - R.EPS) c.start = Math.max(0, M.quantize(p.canvas, c.start - d.duration));
          }
        }
      }
    });
  }

  /// Duplicates the selected clips as a group, shifted by the smallest offset >= the selection's
  /// length at which every copy fits on its original's track. Selects the copies.
  duplicateSelection() {
    const group = this.clipsOnUnlockedTracks(this.selection);
    if (!group.length) return;
    const first = Math.min(...group.map(g => g.clip.start));
    const last = Math.max(...group.map(g => M.clipEnd(g.clip)));
    const copies = [];
    this.mutate('Duplicate', p => {
      const span = M.quantize(p.canvas, last - first);
      const shifts = R.validShifts(group, new Set(), p);
      const fit = shifts.find(s => s.hi >= span - R.EPS);
      if (!fit) return;
      const shift = Math.max(span, fit.lo);
      for (const { track: ti, clip: original } of group) {
        const copy = M.clone(original);
        copy.id = M.uuid();
        copy.start = M.quantize(p.canvas, original.start + shift);
        p.tracks[ti].clips.push(copy);
        copies.push(copy.id);
      }
      for (const ti of new Set(group.map(g => g.track))) R.sortClips(p, ti);
    });
    if (copies.length) this.setSelection(copies);
  }

  clipsOnUnlockedTracks(ids) {
    const group = [];
    this.project.tracks.forEach((track, ti) => {
      if (track.isLocked) return;
      for (const c of track.clips) if (ids.has(c.id)) group.push({ track: ti, clip: c });
    });
    return group;
  }

  /// Moves a clip to `trackID` at `start`; overlaps resolve to the nearest free start.
  /// Returns false if refused (locked / incompatible).
  moveClip(id, trackID, start, coalesce = null) {
    const l = M.locate(this.project, id), target = M.trackIndex(this.project, trackID);
    if (!l || target < 0) return false;
    const source = this.project.tracks[l.track], destination = this.project.tracks[target];
    if (source.isLocked || destination.isLocked || source.kind !== destination.kind) return false;
    this.mutate('Move Clip', p => {
      const [clip] = p.tracks[l.track].clips.splice(l.clip, 1);
      const desired = M.quantize(p.canvas, Math.max(0, start));
      clip.start = M.quantize(p.canvas, R.nearestFreeStart(p.tracks[target], clip.duration, desired, new Set([id])));
      p.tracks[target].clips.push(clip);
      R.sortClips(p, target);
    }, { coalesce });
    return true;
  }

  /// Moves clips `ids` together by `delta` seconds and `trackOffset` tracks (see Swift docs).
  moveClips(ids, delta, trackOffset = 0, coalesce = null) {
    const group = this.clipsOnUnlockedTracks(ids);
    if (!group.length) return;
    const p0 = this.project;
    const frame = M.frameDuration(p0.canvas);
    const wanted = Number.isFinite(delta) ? Math.round(delta / frame) * frame : 0;
    const moving = new Set(group.map(g => g.clip.id));
    const sources = group.map(g => g.track);

    const destinations = offset => {
      if (offset === 0) return sources;
      const order = { video: [], audio: [] };
      p0.tracks.forEach((t, i) => order[t.kind].push(i));
      const result = [];
      for (const ti of sources) {
        const tracks = order[p0.tracks[ti].kind];
        const ordinal = tracks.indexOf(ti);
        const dest = tracks[ordinal + offset];
        if (dest === undefined || p0.tracks[dest].isLocked) return null;
        result.push(dest);
      }
      return result;
    };

    let plan = null;
    for (const offset of trackOffset === 0 ? [0] : [trackOffset, 0]) {
      const tracks = destinations(offset);
      if (!tracks) continue;
      const placed = group.map((g, i) => ({ track: tracks[i], clip: g.clip }));
      const shift = R.nearest(wanted, R.validShifts(placed, moving, p0));
      if (shift !== null) { plan = { tracks, shift }; break; }
    }
    if (!plan) return;
    const sameTracks = plan.tracks.every((t, i) => t === sources[i]);
    if (!(Math.abs(plan.shift) > R.EPS || !sameTracks)) return;
    this.mutate(group.length === 1 ? 'Move Clip' : 'Move Clips', p => {
      for (const ti of new Set(sources)) p.tracks[ti].clips = p.tracks[ti].clips.filter(c => !moving.has(c.id));
      group.forEach((g, i) => {
        const c = M.clone(g.clip);
        c.start = Math.max(0, M.quantize(p.canvas, c.start + plan.shift));
        p.tracks[plan.tracks[i]].clips.push(c);
      });
      for (const ti of new Set([...sources, ...plan.tracks])) R.sortClips(p, ti);
    }, { coalesce });
  }

  /// Trims a clip edge ('leading' | 'trailing') to timeline time `t`, clamped by neighbours,
  /// media bounds and a 1-frame minimum.
  trimClip(id, edge, t, coalesce = null) {
    this.mutate('Trim Clip', p => {
      const l = M.locate(p, id);
      if (!l || p.tracks[l.track].isLocked) return;
      const canvas = p.canvas, frame = M.frameDuration(canvas);
      const clips = p.tracks[l.track].clips;
      const c = clips[l.clip];
      t = M.quantize(canvas, t);
      const total = R.sourceDuration(c, p);
      if (edge === 'leading') {
        let lower = l.clip > 0 ? M.clipEnd(clips[l.clip - 1]) : 0;
        if (R.playsSourceRange(c, p)) lower = Math.max(lower, R.ceilFrame(c.start - c.sourceIn, canvas));
        const upper = M.quantize(canvas, M.clipEnd(c) - frame);
        const newStart = Math.min(Math.max(t, lower), upper);
        const d = newStart - c.start;
        if (R.playsSourceRange(c, p)) c.sourceIn = Math.max(0, c.sourceIn + d);
        c.duration = M.quantize(canvas, M.clipEnd(c) - newStart);
        c.start = newStart;
      } else {
        let upper = l.clip + 1 < clips.length ? clips[l.clip + 1].start : Infinity;
        if (total !== null) upper = Math.min(upper, R.floorFrame(c.start + total - c.sourceIn, canvas));
        const newEnd = Math.max(Math.min(t, upper), c.start + frame);
        c.duration = M.quantize(canvas, newEnd - c.start);
      }
      R.clampFades(c);
    }, { coalesce });
  }

  /// Edits arbitrary clip properties via `body(clip)`; values are clamped, timing kept overlap-free.
  updateClip(id, actionName, body, { coalesce = null, coalesceTimeout = null } = {}) {
    this.mutate(actionName, p => {
      const l = M.locate(p, id);
      if (!l || p.tracks[l.track].isLocked) return;
      const track = p.tracks[l.track];
      const original = track.clips[l.clip];
      const c = M.clone(original);
      body(c);
      c.id = original.id;
      R.normalize(c, p);
      if ((c.start !== original.start || c.duration !== original.duration) && !R.isFree(track, c.start, c.duration, new Set([id]))) {
        c.start = M.quantize(p.canvas, R.nearestFreeStart(track, c.duration, c.start, new Set([id])));
      }
      track.clips[l.clip] = c;
      R.sortClips(p, l.track);
    }, { coalesce, coalesceTimeout });
  }

  /// Moves a video clip's embedded audio onto an audio track and mutes it on the video clip.
  detachAudio(clipID, coalesce = null) {
    this.mutate('Detach Audio', p => {
      const l = M.locate(p, clipID);
      if (!l || p.tracks[l.track].kind !== 'video' || p.tracks[l.track].isLocked) return;
      const video = p.tracks[l.track].clips[l.clip];
      const m = M.findMedia(p, video.mediaID);
      if (!m || m.kind !== 'video' || !m.hasAudio || video.audioMuted) return;
      const audio = M.makeClip({ mediaID: m.id, start: video.start, duration: video.duration, sourceIn: video.sourceIn });
      audio.volume = video.volume;
      audio.fadeIn = video.fadeIn;
      audio.fadeOut = video.fadeOut;
      if (video.label) audio.label = video.label;
      video.audioMuted = true;
      R.place(audio, 'audio', null, false, p);
    }, { coalesce });
  }

  /// True for a video clip whose embedded audio is still attached.
  canDetachAudio(clip) {
    if (clip.audioMuted) return false;
    const m = this.media(clip.mediaID);
    return !!m && m.kind === 'video' && m.hasAudio;
  }

  /// Applies fades (seconds) to the selected clips; null leaves that side unchanged.
  setFades(fadeIn, fadeOut) {
    const targets = new Set(this.selection);
    if (!targets.size || (fadeIn === null && fadeOut === null)) return;
    this.mutate('Set Fades', p => {
      for (const track of p.tracks) {
        if (track.isLocked) continue;
        for (const c of track.clips) {
          if (!targets.has(c.id)) continue;
          if (fadeIn !== null) c.fadeIn = fadeIn;
          if (fadeOut !== null) c.fadeOut = fadeOut;
          R.clampFades(c);
        }
      }
    });
  }

  // MARK: - Tracks

  addTrack(kind) {
    let id = null;
    this.mutate(kind === 'video' ? 'Add Video Track' : 'Add Audio Track', p => {
      const ti = R.insertTrack(kind, p);
      id = p.tracks[ti].id;
    });
    return id;
  }

  /// Removes a track and its clips. The last video track and locked tracks cannot be removed.
  removeTrack(id) {
    const ti = M.trackIndex(this.project, id);
    if (ti < 0) return;
    const track = this.project.tracks[ti];
    if (track.isLocked) { this.setStatus(`Unlock ${M.displayName(this.project, id)} to remove it.`); return; }
    if (track.kind === 'video' && this.project.tracks.filter(t => t.kind === 'video').length <= 1) {
      this.setStatus('A project needs at least one video track.');
      return;
    }
    this.mutate('Remove Track', p => { p.tracks.splice(ti, 1); });
  }

  setTrack(id, { muted, hidden, locked }) {
    let name;
    if (locked !== undefined) name = locked ? 'Lock Track' : 'Unlock Track';
    else if (hidden !== undefined) name = hidden ? 'Hide Track' : 'Show Track';
    else if (muted !== undefined) name = muted ? 'Mute Track' : 'Unmute Track';
    else return;
    this.mutate(name, p => {
      const t = p.tracks.find(x => x.id === id);
      if (!t) return;
      if (muted !== undefined) t.isMuted = muted;
      if (hidden !== undefined) t.isHidden = hidden;
      if (locked !== undefined) t.isLocked = locked;
    });
  }

  // MARK: - Snapping

  /// Clip edges (excluding `excluding` ids), the playhead, 0 and the end of the remaining clips. Sorted.
  snapTargets(excluding = new Set()) {
    const targets = new Set([0, this.playhead]);
    let end = 0;
    for (const track of this.project.tracks) {
      for (const c of track.clips) {
        if (excluding.has(c.id)) continue;
        targets.add(c.start);
        targets.add(M.clipEnd(c));
        end = Math.max(end, M.clipEnd(c));
      }
    }
    targets.add(end);
    return [...targets].sort((a, b) => a - b);
  }

  /// Snaps `t` to the nearest target within `threshold` seconds if snapping is enabled.
  snap(t, excluding, threshold) {
    if (!this.snappingEnabled) return t;
    let best = t, bestDistance = threshold;
    for (const target of this.snapTargets(excluding)) {
      const d = Math.abs(target - t);
      if (d <= bestDistance) { best = target; bestDistance = d; }
    }
    return best;
  }

  // MARK: - Selection & clipboard

  selectAll() {
    this.setSelection(this.project.tracks.filter(t => !t.isLocked).flatMap(t => t.clips.map(c => c.id)));
  }

  copySelection() {
    const items = this.clipboardItems(this.selection, false);
    if (items.length) this.clipboard = items;
  }

  cutSelection() {
    const items = this.clipboardItems(this.selection, true);
    if (!items.length) return;
    this.clipboard = items;
    const ids = new Set(items.map(i => i.clip.id));
    this.mutate('Cut', p => {
      for (const t of p.tracks) if (!t.isLocked) t.clips = t.clips.filter(c => !ids.has(c.id));
    });
  }

  get canPaste() { return this.clipboard.length > 0; }

  /// Pastes clipboard clips at the playhead, keeping relative timing and tracks.
  pasteAtPlayhead() {
    if (!this.clipboard.length) return;
    const base = Math.min(...this.clipboard.map(i => i.clip.start));
    const origin = M.quantize(this.project.canvas, this.playhead);
    const groups = new Map();
    for (const item of this.clipboard) {
      const key = `${item.trackKind}:${item.trackOrdinal}`;
      if (!groups.has(key)) groups.set(key, { kind: item.trackKind, ordinal: item.trackOrdinal, items: [] });
      groups.get(key).items.push(item);
    }
    const ordered = [...groups.values()].sort((a, b) =>
      (a.kind === 'video' ? 0 : 1) - (b.kind === 'video' ? 0 : 1) || a.ordinal - b.ordinal);
    const pasted = [];
    this.mutate('Paste', p => {
      for (const g of ordered) {
        const clips = g.items.filter(i => !i.clip.mediaID || M.findMedia(p, i.clip.mediaID)).map(i => {
          const c = M.clone(i.clip);
          c.id = M.uuid();
          c.start = M.quantize(p.canvas, origin + (c.start - base));
          return c;
        });
        if (!clips.length) continue;
        const kindTracks = p.tracks.map((t, i) => i).filter(i => p.tracks[i].kind === g.kind);
        const preferred = kindTracks[g.ordinal];
        const candidates = (preferred !== undefined ? [preferred] : []).concat(kindTracks.filter(i => i !== preferred))
          .filter(i => !p.tracks[i].isLocked);
        let ti = candidates.find(i => clips.every(c => R.isFree(p.tracks[i], c.start, c.duration)));
        if (ti === undefined) ti = R.insertTrack(g.kind, p);
        for (const c of clips) {
          c.start = M.quantize(p.canvas, R.nearestFreeStart(p.tracks[ti], c.duration, c.start));
          p.tracks[ti].clips.push(c);
          R.sortClips(p, ti);
          pasted.push(c.id);
        }
      }
    });
    if (pasted.length) this.setSelection(pasted);
  }

  /// Moves the selected clips by `frames`, clamped at 0 and by neighbours. Repeated nudges within
  /// 1.5 s coalesce into one undo step.
  nudgeSelection(frames) {
    if (frames === 0 || !this.selection.size) return;
    const frame = this.frameDuration;
    let allowed = frames;
    let moving = false;
    for (const track of this.project.tracks) {
      if (track.isLocked) continue;
      const clips = track.clips;
      clips.forEach((c, i) => {
        if (!this.selection.has(c.id)) return;
        moving = true;
        if (frames < 0) {
          const before = clips.slice(0, i).filter(o => !this.selection.has(o.id));
          const bound = before.length ? M.clipEnd(before[before.length - 1]) : 0;
          allowed = Math.max(allowed, -Math.floor((c.start - bound) / frame + 1e-6));
        } else {
          const next = clips.slice(i + 1).find(o => !this.selection.has(o.id));
          if (next) allowed = Math.min(allowed, Math.floor((next.start - M.clipEnd(c)) / frame + 1e-6));
        }
      });
    }
    if (!moving || allowed === 0) return;
    const delta = allowed * frame;
    const targets = new Set(this.selection);
    this.mutate('Nudge', p => {
      p.tracks.forEach((track, ti) => {
        if (track.isLocked) return;
        for (const c of track.clips) if (targets.has(c.id)) c.start = Math.max(0, M.quantize(p.canvas, c.start + delta));
        R.sortClips(p, ti);
      });
    }, { coalesce: 'nudge-selection', coalesceTimeout: 1.5 });
  }

  clipboardItems(ids, unlockedOnly) {
    const items = [];
    const ordinals = { video: 0, audio: 0 };
    for (const track of this.project.tracks) {
      const ordinal = ordinals[track.kind]++;
      if (unlockedOnly && track.isLocked) continue;
      for (const c of track.clips) if (ids.has(c.id)) items.push({ clip: M.clone(c), trackKind: track.kind, trackOrdinal: ordinal });
    }
    return items;
  }
}

function autosaveStatePath(file) { return file.replace(/\.[^.\\/]+$/, '') + '.state.json'; }

/// Writes `text` to a temporary file beside `file`, then renames it over `file`.
function writeAtomic(file, text) {
  const tmp = `${file}.${process.pid}.${Date.now()}.tmp`;
  fs.writeFileSync(tmp, text);
  fs.renameSync(tmp, file);
}

/// Local path of a media item. URLs written on macOS ("file:///Users/...") are not valid Windows
/// paths; they are returned as their decoded POSIX path, which never exists here (= missing media).
function mediaPath(m) {
  const u = new URL(m.url);
  if (/^\/[A-Za-z]:\//.test(u.pathname) || u.host) return M.fileURLToPath(m.url);
  return decodeURIComponent(u.pathname);
}
function mediaFileExists(m) { return fs.existsSync(mediaPath(m)); }

module.exports = { EditorStore, UNDO_LIMIT, ZOOM_MIN, ZOOM_MAX, mediaPath, mediaFileExists, writeAtomic };
