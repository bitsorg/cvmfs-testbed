/**
 * env-badge.js — Environment identity badge in the console header.
 *
 * The badge is colour-coded by keyword found in the name:
 *   "prod" → red    "test" → green    "dev" → orange    anything else → purple
 *
 * HTML required in the page:
 *   <div id="env-badge"></div>
 *
 * CSS required: #env-badge and its class variants (prod/test/dev/custom)
 * are defined in cvmfs-elements/css/console.css.
 *
 * Usage:
 *   import { applyEnvBadge } from './env-badge.js';
 *   applyEnvBadge(cfg.consoleName);   // hides badge when name is empty
 */

'use strict';

/**
 * Show or hide the environment badge in the console header.
 *
 * @param {string} name     - Display name from user config (e.g. "PROD", "test-01").
 *                            An empty/null name hides the badge.
 * @param {string} badgeId  - Element ID of the badge element (default: 'env-badge').
 */
export function applyEnvBadge(name, badgeId = 'env-badge') {
  const badge = document.getElementById(badgeId);
  if (!badge) return;
  const trimmed = (name || '').trim();
  if (trimmed) {
    badge.textContent = trimmed;
    const lc = trimmed.toLowerCase();
    badge.className = /prod/.test(lc) ? 'prod'
                    : /test/.test(lc) ? 'test'
                    : /dev/.test(lc)  ? 'dev'
                    : 'custom';
    badge.style.display = '';
  } else {
    badge.style.display = 'none';
  }
}
