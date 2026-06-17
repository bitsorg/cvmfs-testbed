/**
 * utils.js — Shared DOM and formatting utilities for CVMFS web consoles.
 *
 * All exports are pure functions or simple wrappers with no side-effects.
 * Import selectively:
 *   import { $, esc, relTime, fmtSec } from '../cvmfs-elements/js/utils.js';
 */

'use strict';

// ── DOM ───────────────────────────────────────────────────────────────────────

/** Shorthand for document.getElementById. */
export const $ = id => document.getElementById(id);

/**
 * HTML-escape a value so it is safe to interpolate into innerHTML strings.
 * Escapes &, <, and >.
 */
export const esc = s => String(s || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

// ── Time formatting ───────────────────────────────────────────────────────────

/**
 * Human-readable relative time: "3s ago", "12m ago", "2h ago", or a date
 * string for anything older than a day.
 * @param {string|Date|number} ts - ISO string, Date object, or epoch ms.
 */
export function relTime(ts) {
  if (!ts) return '–';
  const d = typeof ts === 'string' ? new Date(ts) : ts;
  if (isNaN(d)) return String(ts);
  const s = (Date.now() - d) / 1000;
  if (s < 60)    return `${~~s}s ago`;
  if (s < 3600)  return `${~~(s / 60)}m ago`;
  if (s < 86400) return `${~~(s / 3600)}h ago`;
  return d.toLocaleDateString();
}

/**
 * Format a duration in seconds as a short string: "240ms", "1.3s".
 * Returns "–" for null/undefined.
 */
export function fmtSec(v) {
  if (!v && v !== 0) return '–';
  if (v < 1) return `${(v * 1000).toFixed(0)}ms`;
  return `${v.toFixed(1)}s`;
}

// ── String formatting ─────────────────────────────────────────────────────────

/**
 * Truncate a content hash to 16 chars with an ellipsis, or return "–".
 */
export function shortHash(h) {
  return h ? (h.length > 16 ? h.slice(0, 16) + '…' : h) : '–';
}

// ── Statistics ────────────────────────────────────────────────────────────────

/**
 * p-th percentile of a numeric array (0–100).
 * Returns 0 for empty arrays.
 */
export function percentile(arr, p) {
  if (!arr.length) return 0;
  const s = [...arr].sort((a, b) => a - b);
  const i = Math.ceil(p / 100 * s.length) - 1;
  return s[Math.max(0, i)];
}
