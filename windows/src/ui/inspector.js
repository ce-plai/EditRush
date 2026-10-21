'use strict';
// Right-hand properties panel: project settings with no selection, shared actions for a
// multi-selection, and tabbed clip properties for a single clip.
// Port of the Sources/EditRush/UI/Inspector pages.

const { ipcRenderer } = require('electron');
const M = require('../core/model');
const color = require('../engine/color');
const { h, icon, clear, hexColor, fromHex } = require('./dom');
const fmt = require('./format');

const MAX_FADE = 5;
const COLOR_WELL_TIMEOUT = 1.5;
const TINTS = { video: '#3d6bcc', image: '#805ccc', audio: '#339e73', text: '#d98038' };
const KIND_ICONS = { video: 'film', image: 'photo', audio: 'wave', text: 'text' };
const TAB_INFO = {
  text: ['Text', 'text'], transform: ['Transform', 'transform'], fades: ['Fades', 'fades'],
  color: ['Color', 'color'], filters: ['Filters', 'filters'], audio: ['Audio', 'speaker'],
};
const FRAME_RATES = [23.976, 24, 25, 29.97, 30, 50, 59.94, 60];
const CURATED_FONTS = ['Segoe UI', 'Arial', 'Arial Black', 'Bahnschrift', 'Calibri', 'Cambria', 'Candara', 'Comic Sans MS',
  'Consolas', 'Constantia', 'Corbel', 'Courier New', 'Franklin Gothic Medium', 'Gabriola', 'Georgia', 'Impact', 'Ink Free',
  'Lucida Console', 'Palatino Linotype', 'Segoe Print', 'Segoe Script', 'Sitka Text', 'Tahoma', 'Times New Roman',
  'Trebuchet MS', 'Verdana', 'Montserrat', 'Helvetica Neue', 'Avenir Next', 'Futura'];

/// What a clip shows: any clip on an audio track (including detached audio) is audio.
function clipKind(clip, media, trackKind) {
  if (clip.text) return 'text';
  if (trackKind === 'audio') return 'audio';
  if (media && media.kind === 'audio') return 'audio';
  if (media && media.kind === 'image') return 'image';
  return 'video';
}

function tabsFor(kind, media) {
  switch (kind) {
    case 'text': return ['text', 'transform', 'fades'];
    case 'image': return ['transform', 'fades', 'color', 'filters'];
    case 'audio': return ['audio', 'fades'];
    default: return ['transform', 'fades', 'color', 'filters', ...(media && media.hasAudio ? ['audio'] : [])];
  }
}

const clampTo = (v, lo, hi) => Math.min(hi, Math.max(lo, v));

class Inspector {
  constructor(app) {
    this.app = app;
    this.store = app.store;
    this.headerTitle = h('span');
    this.headerIcon = h('span');
    this.body = h('div', { style: { display: 'flex', flexDirection: 'column', flex: 1, minHeight: 0 } });
    this.root = h('div.panel.inspector', h('div.panel-header', this.headerIcon, this.headerTitle), this.body);
    this.refreshers = [];
    this.structureKey = null;
    this.textRequest = null;
    this.lastSelectionRevision = 0;
    this.store.on('project', () => this.update());
    this.store.on('ui', () => this.update());
    app.cache.onChange(() => { if (this.presetsRedraw) this.presetsRedraw(); });
    this.update();
  }

  /// Opens the text of title `clipID` for typing (all text selected).
  requestTextEditing(clipID) {
    this.textRequest = clipID;
    localStorage.setItem('inspector.tab.title', 'text');
    this.structureKey = null;
    this.update();
  }

  update() {
    const s = this.store;
    const sel = [...s.selection].sort();
    const clip = s.primarySelection;
    // A title that was just added opens for typing.
    if (clip && clip.text && s.undoActionName === 'Add Text' && s.revision !== this.lastSelectionRevision && this.lastSelectionKey !== clip.id) {
      this.textRequest = clip.id;
      localStorage.setItem('inspector.tab.title', 'text');
    }
    if (this.lastSelectionKey !== sel.join(',')) { this.lastSelectionKey = sel.join(','); this.lastSelectionRevision = s.revision; }

    let key;
    if (!sel.length) key = 'project';
    else if (clip) {
      const media = s.media(clip.mediaID);
      const track = M.trackContaining(s.project, clip.id);
      const kind = clipKind(clip, media, track && track.kind);
      key = `clip:${clip.id}:${kind}:${this.currentTab(kind, media)}:${media ? media.hasAudio : ''}`;
    } else key = `multi:${sel.join(',')}`;

    if (key !== this.structureKey) {
      this.structureKey = key;
      this.rebuild(key);
    }
    for (const r of this.refreshers) r();
  }

  currentTab(kind, media) {
    const tabs = tabsFor(kind, media);
    const stored = localStorage.getItem(kind === 'text' ? 'inspector.tab.title' : 'inspector.tab') || (kind === 'text' ? 'text' : 'transform');
    return tabs.includes(stored) ? stored : tabs[0];
  }

  rebuild(key) {
    const active = document.activeElement;
    if (active && this.root.contains(active)) active.blur();
    this.refreshers = [];
    this.presetsRedraw = null;
    clear(this.body);
    const s = this.store;
    if (key === 'project') {
      this.setHeader('Project', 'film');
      this.body.append(h('div.insp-scroll', this.projectPage()));
    } else if (key.startsWith('clip:')) {
      this.setHeader('Clip', 'transform');
      this.body.append(...this.clipPage(s.primarySelection));
    } else {
      this.setHeader('Selection', 'duplicate');
      this.body.append(h('div.insp-scroll', this.multiPage()));
    }
  }

  setHeader(title, iconName) {
    this.headerTitle.textContent = title;
    this.headerIcon.replaceChildren(icon(iconName, 13));
  }

  // MARK: Controls

  /// Slider + number field. `get(clipOrNull)` returns the display value; `set(value)` edits.
  slider({ title, min, max, def, unit = '', decimals = 0, get, set, begin, end }) {
    const range = h('input', { type: 'range', min, max, step: decimals ? Math.pow(10, -decimals) : 1 });
    const num = h('input.num', { type: 'text', spellcheck: false });
    let dragging = false;
    range.addEventListener('pointerdown', () => { dragging = true; if (begin) begin(); });
    range.addEventListener('input', () => set(Number(range.value), true));
    range.addEventListener('change', () => { dragging = false; if (end) end(); });
    num.addEventListener('keydown', e => { if (e.key === 'Enter') num.blur(); if (e.key === 'Escape') { refresh(true); num.blur(); } });
    num.addEventListener('change', () => {
      const v = Number(num.value.replace(/[^\d.+-]/g, ''));
      if (Number.isFinite(v)) { set(clampTo(v, min, max), false); if (end) end(); }
      refresh(true);
    });
    const label = h('label', { title: 'Double-click to reset', ondblclick: () => { set(def, false); if (end) end(); } }, title);
    const refresh = (force = false) => {
      const v = get();
      if (v === null || v === undefined) return;
      if (!dragging) range.value = v;
      if (force || document.activeElement !== num) num.value = v.toFixed(decimals);
    };
    this.refreshers.push(refresh);
    refresh(true);
    return h('div.row', label, range, num, h('span.unit', unit));
  }

  toggleRow(title, get, set) {
    const box = h('input', { type: 'checkbox', onchange: () => set(box.checked) });
    this.refreshers.push(() => { box.checked = get(); });
    box.checked = get();
    return h('div.row', h('label', { style: { width: 'auto', flex: 1 } }, title), box);
  }

  iconToggle(name, title, isOn, action) {
    const b = h('button.icon-toggle', { title, onclick: action }, icon(name, 15));
    const refresh = () => b.classList.toggle('on', !!isOn());
    this.refreshers.push(refresh);
    refresh();
    return b;
  }

  colorRow(title, get, set, { alpha = false, enabledToggle = null } = {}) {
    const input = h('input', { type: 'color' });
    const alphaNum = alpha ? h('input.num', { type: 'text', title: 'Opacity %' }) : null;
    input.addEventListener('input', () => set(fromHex(input.value, get().a)));
    if (alphaNum) alphaNum.addEventListener('change', () => {
      const v = clampTo(Number(alphaNum.value) || 0, 0, 100) / 100;
      const c = get(); set({ ...c, a: v });
    });
    const refresh = () => {
      const c = get();
      if (document.activeElement !== input) input.value = hexColor(c);
      if (alphaNum && document.activeElement !== alphaNum) alphaNum.value = String(Math.round(c.a * 100));
    };
    this.refreshers.push(refresh);
    refresh();
    return h('div.row', enabledToggle, h('label', { style: { flex: 1, width: 'auto' } }, title), input, alphaNum, alpha ? h('span.unit', '%') : null);
  }

  section(title, ...content) {
    const head = typeof title === 'string' ? h('div.section-title', h('span', title)) : title;
    return h('div.section', head, ...content);
  }

  sectionTitle(title, accessoryLabel, accessory) {
    return h('div.section-title', h('span', title), h('button.link-btn', { onclick: accessory }, accessoryLabel));
  }

  // MARK: Clip editing helpers

  /// Returns a function edit(action, body, { field, timeout }) bound to `clipID`. With `field`,
  /// edits coalesce into one undo step until the gesture ends (`endEdit`).
  clipEditor(clipID) {
    let gesture = 0;
    const edit = (action, body, { field = null, timeout = null } = {}) => {
      this.store.updateClip(clipID, action, body, field ? { coalesce: `insp-${field}-${clipID}-${gesture}`, coalesceTimeout: timeout } : {});
    };
    edit.end = () => { gesture++; this.store.endCoalescing(); };
    edit.clip = () => this.store.clip(clipID);
    return edit;
  }

  // MARK: Single clip

  clipPage(clip) {
    const s = this.store;
    const media = s.media(clip.mediaID);
    const track = M.trackContaining(s.project, clip.id);
    const kind = clipKind(clip, media, track && track.kind);
    const tabs = tabsFor(kind, media);
    const tab = this.textRequest === clip.id ? 'text' : this.currentTab(kind, media);
    const edit = this.clipEditor(clip.id);
    const header = this.clipHeader(clip.id, kind, media, edit);
    const tabBar = h('div.tabs', ...tabs.map(t => h('div.tab' + (t === tab ? '.on' : ''), {
      title: TAB_INFO[t][0],
      onclick: () => { localStorage.setItem(kind === 'text' ? 'inspector.tab.title' : 'inspector.tab', t); this.textRequest = null; this.update(); },
    }, icon(TAB_INFO[t][1], 15), TAB_INFO[t][0])));
    const pages = { text: () => this.textPage(edit), transform: () => this.transformPage(edit, kind), fades: () => this.fadesPage(edit, kind, track),
      color: () => this.colorPage(edit), filters: () => this.filterPage(edit, media), audio: () => this.audioPage(edit, kind) };
    return [header, tabBar, h('div.insp-scroll', pages[tab]())];
  }

  clipHeader(clipID, kind, media, edit) {
    const s = this.store;
    const nameInput = h('input.insp-name', {
      spellcheck: false, title: 'Clip name shown on the timeline',
      onkeydown: e => { if (e.key === 'Enter' || e.key === 'Escape') e.target.blur(); },
      onchange: e => { const v = e.target.value.trim(); edit('Rename Clip', c => { if (v) c.label = v; else delete c.label; }); },
    });
    const facts = h('div.insp-facts');
    const times = h('div.insp-times');
    this.refreshers.push(() => {
      const c = s.clip(clipID);
      if (!c) return;
      const def = c.text ? ((c.text.text.split('\n')[0]) || 'Title') : (media ? media.name : 'Missing Media');
      nameInput.placeholder = def;
      if (document.activeElement !== nameInput) nameInput.value = c.label || '';
      const parts = [{ video: 'Video', image: 'Image', audio: 'Audio', text: 'Title' }[kind]];
      if (kind !== 'audio' && media && media.kind !== 'audio' && media.pixelWidth > 0) parts.push(`${media.pixelWidth}x${media.pixelHeight}`);
      if (kind === 'video' && media && media.frameRate > 0) parts.push(`${fmt.number(media.frameRate, Math.round(media.frameRate) === media.frameRate ? 0 : 2)} fps`);
      const tr = M.trackContaining(s.project, clipID);
      if (tr) parts.push(M.displayName(s.project, tr.id));
      facts.textContent = parts.join(', ');
      const fps = s.project.canvas.frameRate;
      const noSource = kind === 'text' || kind === 'image';
      times.replaceChildren(
        h('div', h('b', 'START'), h('span', fmt.timecode(c.start, fps))),
        h('div', h('b', 'DURATION'), h('span', fmt.timecode(c.duration, fps))),
        h('div', h('b', noSource ? 'SOURCE' : 'SOURCE IN'), h('span', noSource ? '-' : fmt.timecode(c.sourceIn, fps))));
    });
    return h('div.insp-header',
      h('div.insp-id', h('div.insp-swatch', { style: { background: TINTS[kind] } }, icon(KIND_ICONS[kind], 15)),
        h('div', { style: { flex: 1, minWidth: 0 } }, nameInput, facts)),
      times);
  }

  textPage(edit) {
    const style = () => (edit.clip() || {}).text;
    const canvasH = () => this.store.project.canvas.height;
    const area = h('textarea.text-edit', { spellcheck: false });
    area.addEventListener('input', () => edit('Edit Text', c => { c.text.text = area.value; }, { field: 'text' }));
    area.addEventListener('blur', () => edit.end());
    area.addEventListener('keydown', e => { if (e.key === 'Escape') area.blur(); });
    this.refreshers.push(() => { const st = style(); if (st && document.activeElement !== area) area.value = st.text; });
    if (this.textRequest === edit.clip().id) {
      this.textRequest = null;
      setTimeout(() => { area.focus(); area.select(); }, 0);
    }
    const fontBtn = h('button.btn', { style: { width: '100%', textAlign: 'left' }, onclick: () => this.fontPicker(style().fontFamily, fam => edit('Font', c => { c.text.fontFamily = fam; })) });
    this.refreshers.push(() => { const st = style(); if (st) { fontBtn.textContent = st.fontFamily; fontBtn.style.fontFamily = `"${st.fontFamily}", "Segoe UI"`; } });
    const align = a => this.iconToggle({ left: 'alignL', center: 'alignC', right: 'alignR' }[a], `Align ${a}`, () => style() && style().alignment === a,
      () => edit('Text Alignment', c => { c.text.alignment = a; }));
    return h('div',
      this.section('Text', area),
      this.section('Font', fontBtn,
        h('div.row', this.iconToggle('bold', 'Bold', () => style() && style().isBold, () => edit('Bold', c => { c.text.isBold = !c.text.isBold; })),
          this.iconToggle('italic', 'Italic', () => style() && style().isItalic, () => edit('Italic', c => { c.text.isItalic = !c.text.isItalic; })),
          h('div.tl-sep'), align('left'), align('center'), align('right')),
        this.slider({ title: 'Size', min: Math.round(0.01 * canvasH()), max: Math.round(0.5 * canvasH()), def: 0.1 * canvasH(), unit: 'px',
          get: () => style() && Math.round(style().fontSize * canvasH()),
          set: (v, live) => edit('Font Size', c => { c.text.fontSize = clampTo(v / Math.max(1, canvasH()), 0.01, 0.5); }, live ? { field: 'font-size' } : {}), end: edit.end })),
      this.section('Appearance',
        this.colorRow('Text color', () => style().color, rgba => edit('Text Color', c => { c.text.color = rgba; }, { field: 'text-color', timeout: COLOR_WELL_TIMEOUT })),
        this.colorRow('Background box', () => (style().backgroundColor.a > 0 ? style().backgroundColor : M.rgba(0, 0, 0, 0.6)),
          rgba => edit('Text Background', c => { c.text.backgroundColor = rgba; }, { field: 'text-background', timeout: COLOR_WELL_TIMEOUT }),
          { alpha: true, enabledToggle: (() => {
            const b = h('input', { type: 'checkbox', title: 'Show a box behind the text', onchange: () => edit(b.checked ? 'Show Text Background' : 'Hide Text Background',
              c => { c.text.backgroundColor = b.checked ? M.rgba(0, 0, 0, 0.6) : M.CLEAR(); }) });
            this.refreshers.push(() => { if (style()) b.checked = style().backgroundColor.a > 0; });
            return b;
          })() }),
        this.toggleRow('Drop shadow', () => !!(style() && style().shadow), on => edit(on ? 'Add Text Shadow' : 'Remove Text Shadow', c => { c.text.shadow = on; }))),
      this.section('Outline',
        this.slider({ title: 'Width', min: 0, max: 25, def: 0, unit: '%', get: () => style() && Math.round(style().outlineWidth * 100),
          set: (v, live) => edit('Outline Width', c => { c.text.outlineWidth = clampTo(v / 100, 0, 0.25); }, live ? { field: 'outline-width' } : {}), end: edit.end }),
        this.colorRow('Outline color', () => style().outlineColor, rgba => edit('Outline Color', c => { c.text.outlineColor = rgba; }, { field: 'outline-color', timeout: COLOR_WELL_TIMEOUT }))));
  }

  transformPage(edit, kind) {
    const xf = () => (edit.clip() || {}).transform;
    const live = (field, isLive) => (isLive ? { field } : {});
    const fitButtons = kind === 'text' ? null : h('div.row',
      h('label', 'Fit'),
      this.iconToggle('zoomFit', 'Fit inside the canvas (letterbox)', () => xf() && xf().fitMode === 'fit', () => edit('Fit', c => { c.transform.fitMode = 'fit'; })),
      this.iconToggle('transform', 'Fill the canvas (crop)', () => xf() && xf().fitMode === 'fill', () => edit('Fill', c => { c.transform.fitMode = 'fill'; })));
    return h('div',
      this.section(this.sectionTitle('Size', 'Reset', () => edit('Reset Transform', c => { c.transform = M.defaultTransform(); })),
        this.slider({ title: 'Scale', min: 2, max: 400, def: 100, unit: '%', get: () => xf() && Math.round(xf().scale * 100),
          set: (v, l) => edit('Scale', c => { c.transform.scale = v / 100; }, live('scale', l)), end: edit.end }),
        fitButtons),
      this.section(this.sectionTitle('Position', 'Center', () => edit('Center', c => { c.transform.offsetX = 0; c.transform.offsetY = 0; })),
        this.slider({ title: 'X', min: -100, max: 100, def: 0, unit: '%', get: () => xf() && Math.round(xf().offsetX * 100),
          set: (v, l) => edit('Move', c => { c.transform.offsetX = v / 100; }, live('x', l)), end: edit.end }),
        this.slider({ title: 'Y', min: -100, max: 100, def: 0, unit: '%', get: () => xf() && Math.round(xf().offsetY * 100),
          set: (v, l) => edit('Move', c => { c.transform.offsetY = v / 100; }, live('y', l)), end: edit.end })),
      this.section('Rotation & Opacity',
        this.slider({ title: 'Rotation', min: -180, max: 180, def: 0, unit: 'deg', get: () => xf() && Math.round(xf().rotation),
          set: (v, l) => edit('Rotate', c => { c.transform.rotation = v; }, live('rotation', l)), end: edit.end }),
        this.slider({ title: 'Opacity', min: 0, max: 100, def: 100, unit: '%', get: () => xf() && Math.round(xf().opacity * 100),
          set: (v, l) => edit('Opacity', c => { c.transform.opacity = v / 100; }, live('opacity', l)), end: edit.end }),
        h('div.row',
          this.iconToggle('flipH', 'Flip Horizontal', () => xf() && xf().flipHorizontal, () => edit('Flip Horizontal', c => { c.transform.flipHorizontal = !c.transform.flipHorizontal; })),
          this.iconToggle('flipV', 'Flip Vertical', () => xf() && xf().flipVertical, () => edit('Flip Vertical', c => { c.transform.flipVertical = !c.transform.flipVertical; })),
          this.iconToggle('rotL', 'Rotate 90 degrees left', () => false, () => edit('Rotate', c => { c.transform.rotation = normalized(c.transform.rotation - 90); })),
          this.iconToggle('rotR', 'Rotate 90 degrees right', () => false, () => edit('Rotate', c => { c.transform.rotation = normalized(c.transform.rotation + 90); })))));
  }

  fadesPage(edit, kind, track) {
    const isAudio = kind === 'audio';
    const clip = () => edit.clip();
    const limit = other => () => { const c = clip(); return c ? Math.max(0, Math.min(MAX_FADE, c.duration - c[other])) : 0; };
    const fadeControls = (field, other, action) => {
      const lim = limit(other);
      const presets = h('div.row', ...[0, 0.5, 1].map(v => {
        const b = h('button.btn', { style: { flex: 1 }, onclick: () => edit(action, c => { c[field] = clampTo(v, 0, Math.max(0, Math.min(MAX_FADE, c.duration - c[other]))); }) },
          v === 0 ? 'None' : `${v} s`);
        this.refreshers.push(() => { const c = clip(); if (!c) return; b.disabled = v > lim() + 1e-4; b.classList.toggle('primary', Math.abs(c[field] - v) < 0.005); });
        return b;
      }));
      const sl = this.slider({ title: 'Duration', min: 0, max: MAX_FADE, def: 0, unit: 's', decimals: 2, get: () => clip() && clip()[field],
        set: (v, l) => edit(action, c => { c[field] = clampTo(v, 0, Math.max(0, Math.min(MAX_FADE, c.duration - c[other]))); }, l ? { field } : {}), end: edit.end });
      return [sl, presets];
    };
    const bottom = (() => {
      if (!track || track.kind !== 'video') return true;
      const first = this.store.project.tracks.find(t => t.kind === 'video' && !t.isHidden);
      return first && first.id === track.id;
    })();
    const caption = isAudio ? "Fades ramp the clip's volume up from silence and back down at the end."
      : bottom ? 'On the bottom track, fades go from and to black. On upper tracks they dissolve to the layers below.'
        : 'This clip is on an upper track, so its fades dissolve to the layers below instead of black.';
    return h('div',
      this.section(isAudio ? 'Fade In' : 'Fade In (from black)', ...fadeControls('fadeIn', 'fadeOut', 'Fade In')),
      this.section(isAudio ? 'Fade Out' : 'Fade Out (to black)', ...fadeControls('fadeOut', 'fadeIn', 'Fade Out')),
      h('div.hint', caption));
  }

  colorPage(edit) {
    const c = () => (edit.clip() || {}).color;
    const sl = (title, min, max, def, unit, decimals, get, set, field) => this.slider({ title, min, max, def, unit, decimals,
      get: () => c() && get(c()), set: (v, l) => edit(title, cl => set(cl.color, v), l ? { field } : {}), end: edit.end });
    return h('div',
      this.section(this.sectionTitle('Light', 'Reset', () => edit('Reset Color', cl => { cl.color = M.defaultColor(); })),
        sl('Exposure', -2, 2, 0, 'EV', 2, x => x.exposure, (x, v) => { x.exposure = clampTo(v, -2, 2); }, 'exposure'),
        sl('Brightness', -100, 100, 0, '', 0, x => Math.round(x.brightness * 200), (x, v) => { x.brightness = clampTo(v / 200, -0.5, 0.5); }, 'brightness'),
        sl('Contrast', 25, 200, 100, '%', 0, x => Math.round(x.contrast * 100), (x, v) => { x.contrast = clampTo(v / 100, 0.25, 2); }, 'contrast')),
      this.section('Color',
        sl('Saturation', 0, 200, 100, '%', 0, x => Math.round(x.saturation * 100), (x, v) => { x.saturation = clampTo(v / 100, 0, 2); }, 'saturation'),
        sl('Temperature', -100, 100, 0, '', 0, x => Math.round(x.temperature * 100), (x, v) => { x.temperature = clampTo(v / 100, -1, 1); }, 'temperature')),
      this.section('Effects',
        sl('Vignette', 0, 100, 0, '%', 0, x => Math.round(x.vignette * 100), (x, v) => { x.vignette = clampTo(v / 100, 0, 1); }, 'vignette')));
  }

  filterPage(edit, media) {
    const clip = () => edit.clip();
    const grid = h('div.presets');
    const canvases = [];
    for (const preset of M.FilterPresets) {
      const cv = h('canvas', { width: 160, height: 100 });
      canvases.push({ preset, cv });
      const cell = h('div.preset', { onclick: () => edit('Filter', c => { c.filter = preset; if (preset !== 'none' && c.filterIntensity <= 0) c.filterIntensity = 1; }) }, cv, M.FilterNames[preset]);
      this.refreshers.push(() => { const c = clip(); if (c) cell.classList.toggle('on', c.filter === preset); });
      grid.appendChild(cell);
    }
    this.presetsRedraw = () => {
      const c = clip();
      const src = media ? this.app.cache.get('poster', media) : null;
      for (const { preset, cv } of canvases) {
        const ctx = cv.getContext('2d');
        ctx.filter = 'none';
        ctx.fillStyle = '#111';
        ctx.fillRect(0, 0, cv.width, cv.height);
        if (!src || !c) continue;
        const fake = { ...c, filter: preset, filterIntensity: 1 };
        const p = color.plan(fake);
        const iw = src.naturalWidth || src.width, ih = src.naturalHeight || src.height;
        const k = Math.max(cv.width / iw, cv.height / ih);
        const dw = iw * k, dh = ih * k, dx = (cv.width - dw) / 2, dy = (cv.height - dh) / 2;
        ctx.filter = color.baseFilter(p);
        ctx.drawImage(src, dx, dy, dw, dh);
        if (p.spatial) { ctx.filter = color.spatialFilter(p, dw, dh); ctx.drawImage(src, dx, dy, dw, dh); }
        ctx.filter = 'none';
        color.drawVignette(ctx, cv.width, cv.height, p.vignette);
      }
    };
    this.presetsRedraw();
    const intensityTitle = h('span');
    this.refreshers.push(() => { const c = clip(); if (c) intensityTitle.textContent = c.filter === 'none' ? 'No filter' : M.FilterNames[c.filter]; });
    return h('div',
      this.section('Intensity', h('div.hint', { style: { padding: '0 0 4px' } }, intensityTitle),
        this.slider({ title: 'Amount', min: 0, max: 100, def: 100, unit: '%', get: () => clip() && Math.round(clip().filterIntensity * 100),
          set: (v, l) => edit('Filter Intensity', c => { c.filterIntensity = v / 100; }, l ? { field: 'filter-intensity' } : {}), end: edit.end })),
      this.section('Presets', grid));
  }

  audioPage(edit, kind) {
    const clip = () => edit.clip();
    const isVideo = kind === 'video';
    const parts = [this.section('Volume',
      this.slider({ title: 'Level', min: 0, max: 200, def: 100, unit: '%', get: () => clip() && Math.round(clip().volume * 100),
        set: (v, l) => edit('Volume', c => { c.volume = v / 100; }, l ? { field: 'volume' } : {}), end: edit.end }),
      this.toggleRow(isVideo ? 'Mute clip audio' : 'Mute', () => !!(clip() && clip().audioMuted), on => edit(on ? 'Mute Clip' : 'Unmute Clip', c => { c.audioMuted = on; })))];
    if (isVideo) {
      const b = h('button.btn', { style: { width: '100%' }, onclick: () => this.app.detachAudio([clip()]) }, 'Detach Audio');
      this.refreshers.push(() => { const c = clip(); if (c) b.disabled = !this.store.canDetachAudio(c); });
      parts.push(this.section('Separate Audio', b, h('div.hint', { style: { padding: '8px 0 0' } }, 'Moves the sound onto an audio track so you can trim or move it on its own.')));
    }
    return h('div', ...parts);
  }

  // MARK: Multi-selection

  multiPage() {
    const s = this.store;
    const clips = () => s.selectedClips;
    const count = h('div', { style: { fontWeight: 600 } });
    const breakdown = h('div.insp-facts');
    this.refreshers.push(() => {
      const cs = clips();
      count.textContent = `${cs.length} clips selected`;
      const kinds = {};
      for (const c of cs) {
        const tr = M.trackContaining(s.project, c.id);
        const k = clipKind(c, s.media(c.mediaID), tr && tr.kind);
        kinds[k] = (kinds[k] || 0) + 1;
      }
      const names = { video: 'video', image: 'image', audio: 'audio', text: 'title' };
      const span = cs.length ? Math.max(...cs.map(M.clipEnd)) - Math.min(...cs.map(c => c.start)) : 0;
      breakdown.textContent = Object.entries(kinds).map(([k, n]) => `${n} ${names[k]}${n === 1 ? '' : 's'}`).join(', ') + `, spans ${fmt.shortDuration(span)}`;
    });
    let gesture = 0;
    const fadeSlider = (field, title) => this.slider({ title: 'Duration', min: 0, max: MAX_FADE, def: 0, unit: 's', decimals: 2,
      get: () => { const cs = clips(); return cs.length ? cs[0][field] : 0; },
      set: (v, l) => {
        const key = l ? `multi-${field}-${gesture}` : null;
        s.mutate('Set Fades', p => {
          for (const t of p.tracks) {
            if (t.isLocked) continue;
            for (const c of t.clips) {
              if (!s.selection.has(c.id)) continue;
              const other = field === 'fadeIn' ? c.fadeOut : c.fadeIn;
              c[field] = clampTo(v, 0, Math.max(0, Math.min(MAX_FADE, c.duration - other)));
            }
          }
        }, { coalesce: key });
      },
      end: () => { gesture++; s.endCoalescing(); } });
    const joinBtn = h('button.btn', { onclick: () => s.joinSelection() }, 'Join');
    this.refreshers.push(() => { joinBtn.disabled = !s.canJoinSelection; });
    return h('div',
      h('div.insp-header', h('div.insp-id', h('div.insp-swatch', { style: { background: 'var(--accent)' } }, icon('duplicate', 15)), h('div', count, breakdown))),
      this.section('Fade In (from black)', fadeSlider('fadeIn')),
      this.section('Fade Out (to black)', fadeSlider('fadeOut')),
      this.section('Actions',
        h('div.row', h('button.btn', { style: { flex: 1 }, onclick: () => s.duplicateSelection() }, 'Duplicate'), joinBtn),
        h('div.row', h('button.btn', { style: { flex: 1 }, onclick: () => s.deleteSelection(false) }, 'Delete'),
          h('button.btn', { style: { flex: 1 }, onclick: () => s.deleteSelection(true) }, 'Ripple Delete'))));
  }

  // MARK: Project

  projectPage() {
    const s = this.store;
    const canvas = () => s.project.canvas;
    const setCanvas = change => { const c = M.clone(canvas()); change(c); s.setCanvas(c); };
    const nameInput = h('input.text-input', {
      spellcheck: false,
      onkeydown: e => { if (e.key === 'Enter') e.target.blur(); if (e.key === 'Escape') { e.target.value = s.project.name; e.target.blur(); } },
      onchange: e => { this.app.documents.renameProject(e.target.value); e.target.value = s.project.name; },
    });
    const fileInfo = h('div.insp-facts', { style: { marginTop: '6px', whiteSpace: 'normal' } });
    const preset = h('select.select', { onchange: e => {
      const p = M.CanvasPresets[Number(e.target.value)];
      if (p) setCanvas(c => { c.width = p.width; c.height = p.height; });
    } }, ...M.CanvasPresets.map((p, i) => h('option', { value: String(i) }, p.name)), h('option', { value: 'custom' }, 'Custom'));
    const dim = (label, field) => {
      const inp = h('input.num', { type: 'text', style: { width: '64px' }, title: label,
        onkeydown: e => { if (e.key === 'Enter') e.target.blur(); },
        onchange: e => { const v = Math.round(Number(e.target.value)); if (v >= 16 && v <= 8192) setCanvas(c => { c[field] = v; }); this.update(); } });
      this.refreshers.push(() => { if (document.activeElement !== inp) inp.value = String(canvas()[field]); });
      return inp;
    };
    const swap = h('button.btn', { title: 'Swap width and height', onclick: () => setCanvas(c => { [c.width, c.height] = [c.height, c.width]; }) }, 'Swap');
    const fpsInput = h('input.num', { type: 'text', style: { width: '64px' },
      onkeydown: e => { if (e.key === 'Enter') e.target.blur(); },
      onchange: e => { const v = Number(e.target.value); if (v >= 1 && v <= 120) setCanvas(c => { c.frameRate = v; }); this.update(); } });
    const fpsMenu = h('select.select', { style: { width: '90px' }, onchange: e => { if (e.target.value) setCanvas(c => { c.frameRate = Number(e.target.value); }); e.target.value = ''; } },
      h('option', { value: '' }, 'Presets'), ...FRAME_RATES.map(f => h('option', { value: String(f) }, `${f} fps`)));
    const summary = h('div');
    this.refreshers.push(() => {
      if (document.activeElement !== nameInput) nameInput.value = s.project.name;
      fileInfo.textContent = s.projectPath ? s.projectPath : 'Not saved to a file yet (Ctrl+Shift+S to save). Your work is kept in the autosave.';
      const c = canvas();
      const i = M.CanvasPresets.findIndex(p => p.width === c.width && p.height === c.height);
      preset.value = i >= 0 ? String(i) : 'custom';
      swap.disabled = c.width === c.height;
      if (document.activeElement !== fpsInput) fpsInput.value = fmt.number(c.frameRate, Math.round(c.frameRate) === c.frameRate ? 0 : 3);
      const p = s.project;
      summary.replaceChildren(
        h('div.info-row', h('span', 'Duration'), h('span', fmt.timecode(M.projectDuration(p), c.frameRate))),
        h('div.info-row', h('span', 'Clips'), h('span', String(p.tracks.reduce((n, t) => n + t.clips.length, 0)))),
        h('div.info-row', h('span', 'Tracks'), h('span', `${p.tracks.filter(t => t.kind === 'video').length} video, ${p.tracks.filter(t => t.kind === 'audio').length} audio`)),
        h('div.info-row', h('span', 'Media'), h('span', String(p.media.length))));
    });
    return h('div',
      this.section('Project', nameInput, fileInfo),
      this.section('Canvas', preset,
        h('div.row', h('span', 'W'), dim('Width', 'width'), h('span', 'x'), h('span', 'H'), dim('Height', 'height'), h('div', { style: { flex: 1 } }), swap),
        h('div.row', h('label', 'Frame rate'), fpsInput, fpsMenu),
        this.colorRow('Background', () => canvas().backgroundColor, rgba => setCanvas(c => { c.backgroundColor = { ...rgba, a: 1 }; }))),
      this.section('Summary', summary),
      h('div.hint', 'Select a clip in the timeline to edit its text, transform, fades, color and audio.'));
  }

  // MARK: Font picker

  async fontPicker(current, select) {
    if (!this.fonts) {
      try { this.fonts = await ipcRenderer.invoke('font-families'); } catch (e) {
        this.store.setStatus(`Couldn't list fonts: ${e.message}`);
        return;
      }
    }
    const installed = new Set(this.fonts);
    const popular = CURATED_FONTS.filter(f => installed.has(f));
    const search = h('input.text-input', { placeholder: 'Search fonts', spellcheck: false });
    const list = h('div.font-list');
    const close = () => back.remove();
    const render = () => {
      const q = search.value.trim().toLowerCase();
      const match = f => !q || f.toLowerCase().includes(q);
      const row = f => h('div.fi' + (f === current ? '.on' : ''), { style: { fontFamily: `"${f}"` }, onclick: () => { select(f); close(); } }, f);
      const pop = popular.filter(match), all = this.fonts.filter(match);
      list.replaceChildren(...(pop.length ? [h('div.fh', 'POPULAR'), ...pop.map(row)] : []), h('div.fh', 'ALL FONTS'), ...all.map(row),
        ...(pop.length || all.length ? [] : [h('div.hint', 'No matching fonts')]));
    };
    search.addEventListener('input', render);
    const back = h('div.modal-back', { onmousedown: e => { if (e.target === back) close(); } },
      h('div.modal', { style: { width: '320px' }, onkeydown: e => { if (e.key === 'Escape') close(); } },
        h('h2', 'Font'), search, list, h('div.actions', h('button.btn', { onclick: close }, 'Cancel'))));
    document.body.appendChild(back);
    render();
    search.focus();
    const on = list.querySelector('.fi.on');
    if (on) on.scrollIntoView({ block: 'center' });
  }
}

function normalized(r) {
  let v = r % 360;
  if (v > 180) v -= 360;
  if (v <= -180) v += 360;
  return v;
}

module.exports = { Inspector, clipKind };
