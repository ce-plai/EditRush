'use strict';
// Project file flows: New / Open / Save / Save As, continuous saving, launch restore, renaming
// and importing. Port of ShellDocumentController.swift and ImportActions (Shared.swift).

const fs = require('fs');
const path = require('path');
const { ipcRenderer } = require('electron');
const M = require('../core/model');
const importer = require('../media/importer');

const AUTOSAVE_DELAY = 1500;
const PROJECT_FILTER = { name: 'EditRush Project', extensions: [M.FILE_EXTENSION] };

/// Windows file names cannot contain \ / : * ? " < > |
function fileSafeName(name) {
  const cleaned = name.replace(/[\\/:*?"<>|]/g, '-').trim();
  return cleaned || 'Untitled';
}

class Documents {
  constructor(app) {
    this.app = app;
    this.store = app.store;
    this.flushedRevision = -1;
    this.timer = null;
  }

  // MARK: Launch / quit

  async startSession() {
    const dir = await ipcRenderer.invoke('user-data');
    this.store.autosaveFile = path.join(dir, `Autosave.${M.FILE_EXTENSION}`);
    try {
      this.store.restoreAutosave();
    } catch (e) {
      console.error('EditRush: restoring the autosave failed', e);
      this.store.setStatus(`Couldn't restore the last session: ${e.message}`);
    }
    this.flushedRevision = this.store.revision;
    this.store.on('project', () => {
      clearTimeout(this.timer);
      this.timer = setTimeout(() => this.flush(), AUTOSAVE_DELAY);
    });
  }

  /// Writes pending changes now (autosave + the project file when it has one).
  flush() {
    clearTimeout(this.timer);
    const s = this.store;
    if (s.revision === this.flushedRevision) return;
    if (this.fileNameIsStale() && this.renameProjectFile(s.project.name)) return;
    this.flushedRevision = s.revision;
    try { s.autosave(); } catch (e) { console.error('EditRush autosave failed', e); s.setStatus(`Autosave failed: ${e.message}`); }
    if (!s.projectPath || !s.isDirty) return;
    try { s.save(s.projectPath); } catch (e) {
      s.setStatus(`Couldn't save "${path.basename(s.projectPath)}": ${e.message}`);
    }
  }

  // MARK: Commands

  async newProject() {
    if (!(await this.confirmDiscardingChanges())) return;
    this.app.playback.pause();
    this.store.newProject();
    this.flush();
  }

  async openWithDialog() {
    if (!(await this.confirmDiscardingChanges())) return;
    const r = await ipcRenderer.invoke('dialog-open', { title: 'Choose an EditRush project', filters: [PROJECT_FILTER], properties: ['openFile'] });
    if (r.canceled || !r.filePaths.length) return;
    this.load(r.filePaths[0]);
  }

  /// Saves to the project's file, or asks for one. Returns false if cancelled or failed.
  async save() {
    if (!this.store.projectPath) return this.saveAs();
    if (this.fileNameIsStale()) return this.renameProjectFile(this.store.project.name);
    return this.write(this.store.projectPath);
  }

  async saveAs() {
    const s = this.store;
    const defaultPath = path.join(s.projectPath ? path.dirname(s.projectPath) : require('os').homedir(),
      `${fileSafeName(s.project.name)}.${M.FILE_EXTENSION}`);
    const r = await ipcRenderer.invoke('dialog-save', { title: 'Save Project', defaultPath, filters: [PROJECT_FILTER] });
    if (r.canceled || !r.filePath) return false;
    let file = r.filePath;
    if (path.extname(file).toLowerCase() !== `.${M.FILE_EXTENSION}`) file += `.${M.FILE_EXTENSION}`;
    return this.write(file);
  }

  /// Renames the project; a project with a file renames that file in the same folder.
  renameProject(newName) {
    const name = newName.trim();
    if (!name) return false;
    if (!this.store.projectPath) {
      if (name !== this.store.project.name) this.store.mutate('Rename Project', p => { p.name = name; });
      return true;
    }
    return this.renameProjectFile(name);
  }

  /// Opens project files and/or imports media files handed to the app (command line, drops).
  async openFiles(files) {
    const projects = files.filter(f => path.extname(f).toLowerCase() === `.${M.FILE_EXTENSION}`);
    const media = files.filter(f => path.extname(f).toLowerCase() !== `.${M.FILE_EXTENSION}`);
    if (projects.length && (await this.confirmDiscardingChanges())) this.load(projects[0]);
    if (media.length) {
      const items = await this.importPaths(media);
      if (items.length) this.store.setSelectedMedia(items[0].id);
    }
  }

  async importWithDialog() {
    const r = await ipcRenderer.invoke('dialog-open', {
      title: 'Choose video, audio or image files',
      filters: [{ name: 'Media', extensions: [...importer.supportedExtensions] }],
      properties: ['openFile', 'multiSelections'],
    });
    if (r.canceled || !r.filePaths.length) return [];
    const items = await this.importPaths(r.filePaths);
    if (items.length) this.store.setSelectedMedia(items[0].id);
    return items;
  }

  /// Probes `paths` (folders expand one level), adds new media to the bin, reports failures, and
  /// returns the project's media items for those paths in input order. `coalesce` makes the import
  /// part of the following edits' undo step.
  async importPaths(paths, coalesce = null) {
    const s = this.store;
    const files = importer.expandFolders(paths);
    const key = f => M.pathToFileURL(f).toLowerCase();
    const known = new Set(s.project.media.map(m => m.url.toLowerCase()));
    const fresh = files.filter(f => !known.has(key(f)));
    if (fresh.length) s.setStatus(`Importing ${fresh.length === 1 ? path.basename(fresh[0]) : `${fresh.length} files`}...`);
    const probed = await importer.importFiles(fresh);
    const failures = probed.failures;
    const items = [];
    // Image sizes as displayed: the decoded image applies the EXIF orientation, ffprobe does not.
    for (const it of probed.items) {
      if (it.kind === 'image') {
        const img = await this.app.cache.ready('still', it);
        if (!img) { failures.push({ path: M.fileURLToPath(it.url), reason: "the image couldn't be read" }); continue; }
        it.pixelWidth = img.naturalWidth;
        it.pixelHeight = img.naturalHeight;
      }
      items.push(it);
    }
    if (items.length) {
      s.mutate('Import Media', p => {
        const present = new Set(p.media.map(m => m.url.toLowerCase()));
        for (const it of items) if (!present.has(it.url.toLowerCase())) { present.add(it.url.toLowerCase()); p.media.push(it); }
      }, { coalesce });
    }
    if (failures.length) {
      s.setStatus("Couldn't import " + failures.map(f => `${path.basename(f.path)} (${f.reason})`).join(', '));
    } else if (!fresh.length && files.length) {
      s.setStatus(files.length === 1 ? `${path.basename(files[0], path.extname(files[0]))} is already in the project` : 'Already in the project');
    } else if (items.length) {
      s.setStatus(null);
    }
    const byURL = new Map(s.project.media.map(m => [m.url.toLowerCase(), m]));
    return files.map(f => byURL.get(key(f))).filter(Boolean);
  }

  // MARK: Helpers

  load(file) {
    this.app.playback.pause();
    try {
      this.store.open(file);
      this.flushedRevision = this.store.revision;
      this.store.autosave();
    } catch (e) {
      console.error('EditRush open failed', e);
      this.store.setStatus(`Couldn't open "${path.basename(file)}": ${e.message}`);
    }
  }

  write(file, announce = true) {
    try {
      this.store.save(file);
      this.flushedRevision = this.store.revision;
      this.store.autosave();
      if (announce) this.store.setStatus(`Saved "${path.basename(file)}"`);
      return true;
    } catch (e) {
      console.error('EditRush save failed', e);
      this.store.setStatus(`Couldn't save "${path.basename(file)}": ${e.message}`);
      return false;
    }
  }

  fileNameIsStale() {
    const p = this.store.projectPath;
    return !!p && fileSafeName(this.store.project.name) !== path.basename(p, path.extname(p));
  }

  renameProjectFile(name) {
    const file = this.store.projectPath;
    if (!file) return false;
    const target = path.join(path.dirname(file), `${fileSafeName(name)}.${M.FILE_EXTENSION}`);
    const sourceExists = fs.existsSync(file);
    const sameFile = target.toLowerCase() === file.toLowerCase();
    if (!sameFile && fs.existsSync(target)) {
      this.store.setStatus(`Couldn't rename: "${path.basename(target)}" already exists in that folder.`);
      this.restoreName(file);
      return false;
    }
    const moves = sourceExists && target !== file;
    try {
      if (moves) fs.renameSync(file, target);
    } catch (e) {
      this.store.setStatus(`Couldn't rename "${path.basename(file)}": ${e.message}`);
      this.restoreName(file);
      return false;
    }
    if (this.write(target, false)) return true;
    if (moves) fs.renameSync(target, file);
    return false;
  }

  restoreName(file) {
    if (this.store.project.name === path.basename(file, path.extname(file))) return;
    this.write(file, false);
  }

  hasUnsavedWork() {
    const p = this.store.project;
    const hasContent = p.media.length > 0 || p.tracks.some(t => t.clips.length > 0);
    return hasContent && (!this.store.projectPath || this.store.isDirty);
  }

  /// Asks Save / Don't Save / Cancel when needed. Resolves true if the caller may proceed.
  async confirmDiscardingChanges() {
    if (this.store.projectPath) this.flush();
    if (!this.hasUnsavedWork()) return true;
    const r = await ipcRenderer.invoke('dialog-message', {
      type: 'question',
      message: `Do you want to save the changes to "${this.store.project.name}"?`,
      detail: "Your changes will be lost if you don't save them.",
      buttons: [this.store.projectPath ? 'Save' : 'Save...', 'Cancel', "Don't Save"],
      defaultId: 0, cancelId: 1, noLink: true,
    });
    if (r.response === 0) return this.save();
    return r.response === 2;
  }
}

module.exports = { Documents, fileSafeName };
