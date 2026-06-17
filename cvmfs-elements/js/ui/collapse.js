/**
 * collapse.js — Collapsible section helpers with localStorage persistence.
 *
 * Usage:
 *   import { toggleCollapse, restoreCollapseStates } from './collapse.js';
 *
 *   const COLLAPSE_MAP = {
 *     'metrics-body': 'metrics-chevron',
 *     'stages-body':  'stages-chevron',
 *   };
 *
 *   // Wire up a toggle button:
 *   //   <button onclick="toggleCollapse('metrics-body','metrics-chevron')">…</button>
 *
 *   // Restore states on page load:
 *   restoreCollapseStates(COLLAPSE_MAP);
 *
 * State is stored in localStorage under the key "collapse:<bodyId>" with
 * values "open" or "closed".  Missing keys leave the section in its default
 * (open) state.
 */

'use strict';

/**
 * Toggle a section between expanded and collapsed.
 *
 * @param {string} bodyId    - Element ID of the collapsible content.
 * @param {string} chevronId - Element ID of the chevron icon (rotated when collapsed).
 */
export function toggleCollapse(bodyId, chevronId) {
  const body = document.getElementById(bodyId);
  const chev = document.getElementById(chevronId);
  if (!body) return;
  const collapsed = body.style.display === 'none';
  body.style.display = collapsed ? '' : 'none';
  if (chev) chev.style.transform = collapsed ? '' : 'rotate(-90deg)';
  try {
    localStorage.setItem(`collapse:${bodyId}`, collapsed ? 'open' : 'closed');
  } catch (_) {}
}

/**
 * Restore previously saved collapse states from localStorage.
 *
 * @param {Object<string,string>} collapseMap
 *   Map of bodyId → chevronId for all tracked sections.
 */
export function restoreCollapseStates(collapseMap) {
  Object.entries(collapseMap).forEach(([bodyId, chevronId]) => {
    try {
      const stored = localStorage.getItem(`collapse:${bodyId}`);
      if (!stored) return; // leave at default (open)
      const body = document.getElementById(bodyId);
      const chev = document.getElementById(chevronId);
      if (!body) return;
      if (stored === 'closed') {
        body.style.display = 'none';
        if (chev) chev.style.transform = 'rotate(-90deg)';
      } else {
        body.style.display = '';
        if (chev) chev.style.transform = '';
      }
    } catch (_) {}
  });
}
