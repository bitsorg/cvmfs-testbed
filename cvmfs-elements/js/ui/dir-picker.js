/**
 * dir-picker.js — Server-side filesystem directory picker modal.
 *
 * Renders a modal that lets the user browse directories returned by the
 * testbed-server.py /api/list-dir endpoint and select one.
 *
 * HTML required in the page (add before </body>):
 *
 *   <div id="dir-picker-modal">
 *     <div id="dir-picker-box">
 *       <div id="dir-picker-header">
 *         <button class="btn btn-outline btn-sm" id="dp-up-btn" onclick="dpNavUp()">↑ Up</button>
 *         <span id="dir-picker-path" class="mono">/</span>
 *         <button class="btn btn-outline btn-sm" onclick="closeDirPicker()">✕</button>
 *       </div>
 *       <div id="dir-picker-list"><div class="loading"><span class="spinner"></span></div></div>
 *       <div id="dir-picker-footer">
 *         <span id="dir-picker-current" class="mono">—</span>
 *         <button class="btn btn-primary btn-sm" onclick="dpSelectCurrent()">Select</button>
 *         <button class="btn btn-outline btn-sm" onclick="closeDirPicker()">Cancel</button>
 *       </div>
 *     </div>
 *   </div>
 *
 * CSS: defined in cvmfs-elements/css/console.css (#dir-picker-modal etc.)
 *
 * The onclick attributes above call global functions — expose them via the
 * window bridge in your page script:
 *
 *   import { initDirPicker, openDirPicker, dpNavUp,
 *             dpSelectCurrent, closeDirPicker } from './cvmfs-elements/js/ui/dir-picker.js';
 *
 *   initDirPicker({
 *     getServerToken: () => SERVER_TOKEN,
 *     onSelect: path => { document.getElementById('ul-dir-input').value = path; },
 *   });
 *   Object.assign(window, { openDirPicker, dpNavUp, dpSelectCurrent, closeDirPicker });
 *
 * The listDirEndpoint option (default '/api/list-dir') can be overridden for
 * production environments that proxy the endpoint elsewhere.
 */

'use strict';

import { esc } from '../utils.js';

// Module-level state
let _current     = '/';
let _getToken    = () => '';
let _onSelect    = null;
let _listDirUrl  = '/api/list-dir';
let _serverMode  = () => true; // callback so value is read at call time

const FOLDER_ICON = `<svg viewBox="0 0 24 24"><path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/></svg>`;

/**
 * Initialise the directory picker.  Call once during page boot.
 *
 * @param {object} opts
 * @param {()=>string}   opts.getServerToken  - Returns the current server auth token.
 * @param {(string)=>void} opts.onSelect      - Called with the selected path.
 * @param {()=>boolean}  [opts.isServerMode]  - Returns true when server mode is active.
 * @param {string}       [opts.listDirEndpoint] - Override for the list-dir API URL.
 */
export function initDirPicker({ getServerToken, onSelect, isServerMode, listDirEndpoint } = {}) {
  _getToken   = getServerToken   || (() => '');
  _onSelect   = onSelect         || null;
  _serverMode = isServerMode     || (() => true);
  _listDirUrl = listDirEndpoint  || '/api/list-dir';

  // Close picker when clicking the backdrop
  document.addEventListener('click', e => {
    const modal = document.getElementById('dir-picker-modal');
    if (modal && e.target === modal) closeDirPicker();
  }, true);
}

/**
 * Open the picker, starting from `startPath` (or the configured initial path).
 *
 * @param {string} [startPath] - Directory path to open at (defaults to '/').
 */
export function openDirPicker(startPath) {
  if (!_serverMode()) {
    alert('Directory browser requires server mode.');
    return;
  }
  const modal = document.getElementById('dir-picker-modal');
  if (!modal) return;
  modal.style.display = 'flex';
  _dpNav(startPath || '/');
}

/**
 * Navigate the picker to `path`, fetching its subdirectory listing.
 * Exposed so inline onclick attributes in dynamically generated item HTML
 * can call window._dpNav(path) after the window bridge is set up.
 */
export async function _dpNav(path) {
  _current = path;
  const listEl = document.getElementById('dir-picker-list');
  const pathEl = document.getElementById('dir-picker-path');
  const curEl  = document.getElementById('dir-picker-current');
  const upBtn  = document.getElementById('dp-up-btn');

  if (pathEl) pathEl.textContent = path;
  if (curEl)  curEl.textContent  = path;
  if (listEl) listEl.innerHTML   = '<div class="loading"><span class="spinner"></span></div>';

  let data;
  try {
    const r = await fetch(
      `${_listDirUrl}?path=${encodeURIComponent(path)}`,
      { headers: { 'X-Testbed-Token': _getToken() }, signal: AbortSignal.timeout(8000) },
    );
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    data = await r.json();
  } catch (e) {
    if (listEl) listEl.innerHTML = `<div class="empty muted">Error: ${esc(e.message)}</div>`;
    return;
  }

  if (upBtn) upBtn.disabled = !data.parent;

  let html = '';
  if (!data.exists) {
    html = `<div class="empty muted">Directory not found.</div>`;
  } else if (!data.dirs || !data.dirs.length) {
    html = `<div class="empty muted">No subdirectories.</div>`;
  } else {
    html = data.dirs.map(d =>
      `<div class="dp-item" data-dp-path="${esc(d.path)}">${FOLDER_ICON}<span title="${esc(d.path)}">${esc(d.name)}</span></div>`,
    ).join('');
  }
  if (listEl) {
    listEl.innerHTML = html;
    // Event delegation: one listener on the list container instead of inline onclick
    listEl.onclick = e => {
      const item = e.target.closest('[data-dp-path]');
      if (item) _dpNav(item.dataset.dpPath);
    };
  }
}

/** Navigate up to the parent directory of the current path. */
export function dpNavUp() {
  if (_current === '/') return;
  const parent = _current.replace(/\/[^/]+\/?$/, '') || '/';
  _dpNav(parent);
}

/** Confirm the currently browsed path as the selection and close the picker. */
export function dpSelectCurrent() {
  if (_onSelect) _onSelect(_current);
  closeDirPicker();
}

/** Close the picker without making a selection. */
export function closeDirPicker() {
  const modal = document.getElementById('dir-picker-modal');
  if (modal) modal.style.display = 'none';
}
