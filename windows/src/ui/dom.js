'use strict';
// Small DOM helpers and the SVG icon set used by the UI.

/// h('div.class#id', { attrs / on* handlers / style }, ...children)
function h(spec, props, ...children) {
  if (props instanceof Node || typeof props === 'string' || Array.isArray(props)) { children.unshift(props); props = null; }
  const m = spec.match(/^([a-z0-9-]+)?((?:[.#][\w-]+)*)$/i);
  const el = document.createElement(m[1] || 'div');
  for (const part of (m[2] || '').match(/[.#][\w-]+/g) || []) {
    if (part[0] === '.') el.classList.add(part.slice(1)); else el.id = part.slice(1);
  }
  if (props) {
    for (const [k, v] of Object.entries(props)) {
      if (v === undefined || v === null || v === false) continue;
      if (k.startsWith('on')) el.addEventListener(k.slice(2).toLowerCase(), v);
      else if (k === 'style' && typeof v === 'object') Object.assign(el.style, v);
      else if (k === 'class') el.className = v;
      else if (k in el && k !== 'list' && typeof v !== 'string') el[k] = v;
      else el.setAttribute(k, v === true ? '' : v);
    }
  }
  append(el, children);
  return el;
}

function append(el, children) {
  for (const c of children.flat(Infinity)) {
    if (c === null || c === undefined || c === false) continue;
    el.appendChild(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return el;
}

function clear(el) { while (el.firstChild) el.removeChild(el.firstChild); return el; }

// 24x24 stroke icons.
const ICONS = {
  undo: 'M9 14 4 9l5-5M4 9h10a6 6 0 0 1 0 12h-3',
  redo: 'm15 14 5-5-5-5M20 9H10a6 6 0 0 0 0 12h3',
  import: 'M12 3v12m0 0-4-4m4 4 4-4M4 17v3h16v-3',
  export: 'M12 15V3m0 0L8 7m4-4 4 4M4 17v3h16v-3',
  title: 'M5 6V4h14v2M12 4v16M9 20h6',
  film: 'M4 4h16v16H4zM8 4v16M16 4v16M4 8h4M4 12h4M4 16h4M16 8h4M16 12h4M16 16h4',
  photo: 'M4 5h16v14H4zM4 16l5-5 4 4 3-3 4 4M15 9.5a1 1 0 1 0 0-.01',
  wave: 'M3 12h2M7 8v8M11 5v14M15 9v6M19 11v2M21 12h0',
  play: 'M7 4.5v15l12-7.5z',
  pause: 'M7 5h3.5v14H7zM13.5 5H17v14h-3.5z',
  start: 'M6 5v14M19 5 9 12l10 7z',
  end: 'M18 5v14M5 5l10 7-10 7z',
  prev: 'M15 6l-6 6 6 6',
  next: 'M9 6l6 6-6 6',
  scissors: 'M6 9a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM6 21a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM20 4 8.1 15.9M14.5 14.5 20 20M8.1 8.1 12 12',
  trash: 'M4 7h16M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3',
  duplicate: 'M8 8h12v12H8zM4 16V4h12',
  join: 'M4 12h6m4 0h6M10 8l4 4-4 4M14 8l-4 4 4 4',
  gaps: 'M3 12h6l-3-3m3 3-3 3M21 12h-6l3-3m-3 3 3 3M12 5v14',
  detach: 'M3 12h2M7 9v6M11 6v12M15 12h6',
  fadeIn: 'M3 19 21 5v14z',
  fadeOut: 'M3 5l18 14H3z',
  magnet: 'M6 4v8a6 6 0 0 0 12 0V4M6 4h3v8a3 3 0 0 0 6 0V4h3',
  zoomIn: 'M10.5 17a6.5 6.5 0 1 0 0-13 6.5 6.5 0 0 0 0 13zM20 20l-4.5-4.5M8 10.5h5M10.5 8v5',
  zoomOut: 'M10.5 17a6.5 6.5 0 1 0 0-13 6.5 6.5 0 0 0 0 13zM20 20l-4.5-4.5M8 10.5h5',
  zoomFit: 'M3 12h18M3 12l3-3m-3 3 3 3M21 12l-3-3m3 3-3 3M3 5v14M21 5v14',
  eye: 'M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12zM12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6z',
  eyeOff: 'M3 3l18 18M10.6 5.1A10 10 0 0 1 12 5c6 0 10 7 10 7a17 17 0 0 1-3.2 3.9M6.6 6.6C3.8 8.4 2 12 2 12s4 7 10 7a9.7 9.7 0 0 0 5.4-1.6M9.9 9.9a3 3 0 0 0 4.2 4.2',
  speaker: 'M4 9h4l5-4v14l-5-4H4zM16 9a4 4 0 0 1 0 6M19 6a8 8 0 0 1 0 12',
  mute: 'M4 9h4l5-4v14l-5-4H4zM16 9l5 6M21 9l-5 6',
  lock: 'M6 11h12v9H6zM8 11V7a4 4 0 0 1 8 0v4',
  unlock: 'M6 11h12v9H6zM8 11V7a4 4 0 0 1 7.5-2',
  plus: 'M12 5v14M5 12h14',
  transform: 'M4 9V4h5M20 15v5h-5M4 4l7 7M20 20l-7-7',
  fades: 'M12 3a9 9 0 1 0 0 18zM12 3a9 9 0 0 1 0 18',
  color: 'M12 21a9 9 0 1 1 0-18 9 9 0 0 1 0 18zM12 3v18M3 12h18',
  filters: 'M9 15a6 6 0 1 0 0-12 6 6 0 0 0 0 12zM15 15a6 6 0 1 0 0-12 6 6 0 0 0 0 12zM12 21a6 6 0 1 0 0-12 6 6 0 0 0 0 12z',
  text: 'M5 6V4h14v2M12 4v16M9 20h6',
  flipH: 'M12 3v18M9 7 3 17h6zM15 7l6 10h-6z',
  flipV: 'M3 12h18M7 9 17 3v6zM7 15l10 6v-6z',
  rotL: 'M4 4v5h5M4.6 13a8 8 0 1 0 1.9-7.4L4 9',
  rotR: 'M20 4v5h-5M19.4 13a8 8 0 1 1-1.9-7.4L20 9',
  bold: 'M7 4h6a4 4 0 0 1 0 8H7zM7 12h7a4 4 0 0 1 0 8H7z',
  italic: 'M10 4h8M6 20h8M14 4l-4 16',
  alignL: 'M4 6h16M4 10h10M4 14h16M4 18h10',
  alignC: 'M4 6h16M7 10h10M4 14h16M7 18h10',
  alignR: 'M4 6h16M10 10h10M4 14h16M10 18h10',
  reset: 'M4 4v5h5M4.6 13a8 8 0 1 0 1.9-7.4L4 9',
  warn: 'M12 3 2 20h20zM12 10v4M12 17v.01',
  check: 'M4 12l5 5L20 6',
  close: 'M6 6l12 12M18 6 6 18',
  folder: 'M3 6h6l2 2h10v11H3z',
  chevronDown: 'M6 9l6 6 6-6',
  landscape: 'M3 7h18v10H3z',
  portrait: 'M7 3h10v18H7z',
};

function icon(name, size = 16) {
  const d = ICONS[name];
  if (!d) throw new Error(`unknown icon ${name}`);
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('width', size);
  svg.setAttribute('height', size);
  svg.setAttribute('fill', 'none');
  svg.setAttribute('stroke', 'currentColor');
  svg.setAttribute('stroke-width', '1.8');
  svg.setAttribute('stroke-linecap', 'round');
  svg.setAttribute('stroke-linejoin', 'round');
  svg.classList.add('icon');
  const p = document.createElementNS('http://www.w3.org/2000/svg', 'path');
  p.setAttribute('d', d);
  if (name === 'play' || name === 'pause' || name === 'fadeIn' || name === 'fadeOut' || name === 'start' || name === 'end') {
    p.setAttribute('fill', 'currentColor');
    p.setAttribute('fill-opacity', name.startsWith('fade') ? '0.35' : '1');
  }
  svg.appendChild(p);
  return svg;
}

/// Context menu at (x, y). items: [{ label, action, enabled = true, shortcut } | '-'].
function contextMenu(x, y, items) {
  closeContextMenu();
  const menu = h('div.context-menu');
  for (const it of items) {
    if (it === '-') { menu.appendChild(h('div.menu-sep')); continue; }
    const enabled = it.enabled !== false;
    menu.appendChild(h('div.menu-item' + (enabled ? '' : '.disabled'), {
      onmousedown: e => e.stopPropagation(),
      onclick: () => { if (!enabled) return; closeContextMenu(); it.action(); },
    }, h('span', it.label), it.shortcut ? h('span.menu-shortcut', it.shortcut) : null));
  }
  document.body.appendChild(menu);
  const r = menu.getBoundingClientRect();
  menu.style.left = Math.min(x, window.innerWidth - r.width - 4) + 'px';
  menu.style.top = Math.min(y, window.innerHeight - r.height - 4) + 'px';
  setTimeout(() => window.addEventListener('mousedown', closeContextMenu, { once: true }), 0);
}
function closeContextMenu() { document.querySelectorAll('.context-menu').forEach(m => m.remove()); }

const cssColor = c => `rgba(${Math.round(c.r * 255)},${Math.round(c.g * 255)},${Math.round(c.b * 255)},${c.a})`;
const hexColor = c => '#' + [c.r, c.g, c.b].map(v => Math.round(Math.max(0, Math.min(1, v)) * 255).toString(16).padStart(2, '0')).join('');
function fromHex(hex, a = 1) {
  const n = parseInt(hex.slice(1), 16);
  return { r: ((n >> 16) & 255) / 255, g: ((n >> 8) & 255) / 255, b: (n & 255) / 255, a };
}

/// True when keyboard focus is in a text field.
function isTyping() {
  const a = document.activeElement;
  if (!a) return false;
  if (a.tagName === 'TEXTAREA' || a.isContentEditable) return true;
  return a.tagName === 'INPUT' && !['range', 'checkbox', 'color', 'button', 'radio'].includes(a.type);
}

module.exports = { h, append, clear, icon, contextMenu, closeContextMenu, cssColor, hexColor, fromHex, isTyping };
