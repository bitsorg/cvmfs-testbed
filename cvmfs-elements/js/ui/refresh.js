/**
 * refresh.js — Auto-refresh countdown display helper.
 *
 * Manages a single countdown interval that ticks a header element down from
 * N seconds to 0, then clears itself.  The calling code is responsible for
 * scheduling the actual data refresh (e.g. via setTimeout).
 *
 * Usage:
 *   import { startRefreshCountdown, clearRefreshCountdown } from './refresh.js';
 *
 *   async function refreshAll() {
 *     clearRefreshCountdown();
 *     await fetchData();
 *     startRefreshCountdown(30);
 *     setTimeout(refreshAll, 30_000);
 *   }
 */

'use strict';

let _countdownInterval = null;

/**
 * Start (or restart) a visible countdown in a header element.
 *
 * @param {number} secs      - Total seconds to count down from.
 * @param {string} elementId - ID of the element to write into (default: 'hdr-refresh-in').
 */
export function startRefreshCountdown(secs, elementId = 'hdr-refresh-in') {
  clearInterval(_countdownInterval);
  let remaining = secs;
  const el = document.getElementById(elementId);
  const update = () => {
    if (el) el.textContent = remaining > 0 ? `${remaining}s` : '';
    remaining--;
  };
  update();
  _countdownInterval = setInterval(() => {
    update();
    if (remaining < 0) clearInterval(_countdownInterval);
  }, 1000);
}

/**
 * Cancel the running countdown without clearing the element text.
 * Call before starting a manual refresh so the display doesn't flicker.
 */
export function clearRefreshCountdown() {
  clearInterval(_countdownInterval);
}
