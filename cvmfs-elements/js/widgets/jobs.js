/**
 * jobs.js — Job table rendering helpers for CVMFS publish job lists.
 *
 * All functions are pure renderers that produce HTML strings or DOM mutations;
 * they do not fetch data themselves.
 *
 * Usage:
 *   import { renderJobsTable, stateBadge, miniPipeline, STAGES }
 *     from './cvmfs-elements/js/widgets/jobs.js';
 *
 *   renderJobsTable('jobs-tbody', _jobs, true, { cfg, svcUrl });
 */

'use strict';

import { esc, relTime, shortHash, fmtSec } from '../utils.js';

/**
 * Ordered pipeline stage names for bits-method jobs (5-stage view).
 *
 * staging and leased are collapsed into the adjacent stages they bridge:
 *   staging  → absorbed into incoming (file arrives on disk)
 *   leased   → absorbed into committing (gateway lease held)
 */
export const STAGES = [
  'incoming', 'uploading', 'distributing', 'committing', 'published',
];

// Map the two collapsed states to their canonical display stage.
const _STAGE_ALIAS = { staging: 'incoming', leased: 'committing' };

function _resolveStage(s) {
  return _STAGE_ALIAS[s] || s;
}

/**
 * Render a badge for a job state string.
 *
 * @param {string} s - Lowercase job state (e.g. 'published', 'failed').
 * @returns {string} HTML badge element.
 */
export function stateBadge(s) {
  const m = {
    published:    'ok',
    failed:       'err',
    aborted:      'err',
    incoming:     'warn',
    staging:      'warn',
    uploading:    'info',
    distributing: 'info',
    leased:       'info',
    committing:   'warn',
  };
  return `<span class="badge ${m[s] || 'badge-unknown'}">${s}</span>`;
}

/**
 * Render a mini pipeline strip for a job (5-stage view).
 * Highlights up to the failing stage for failed/aborted jobs.
 *
 * @param {string} state         - Current job state (e.g. 'published', 'failed').
 * @param {string} failedAtState - The stage at which the job failed (if any).
 * @returns {string} HTML pipeline div.
 */
export function miniPipeline(state, failedAtState) {
  const terminal    = state === 'failed' || state === 'aborted';
  const activeState = _resolveStage(terminal ? (failedAtState || state) : state);
  const ai = STAGES.indexOf(activeState);
  return `<div class="pipeline">${STAGES.map((s, i) => {
    let c = '';
    if (terminal && i === ai)                          c = 'failed';
    else if (state === 'published' || (!terminal && i < ai)) c = 'done';
    else if (!terminal && i === ai)                    c = 'active';
    else if (terminal && ai >= 0 && i < ai)            c = 'done';
    return `<div class="pipe-step ${c}" style="font-size:10px;padding:3px">${s.slice(0, 4)}</div>`;
  }).join('')}</div>`;
}

/**
 * Populate a <tbody> element with rows for a list of jobs.
 *
 * @param {string}   tbodyId - Element ID of the target <tbody>.
 * @param {object[]} jobs    - Array of job objects.
 * @param {boolean}  full    - When true, include the mini-pipeline column.
 * @param {object}   opts
 * @param {object}   opts.cfg     - Config object with `repo` fallback.
 * @param {Function} opts.svcUrl  - svcUrl(service, path) for building job API link.
 */
export function renderJobsTable(tbodyId, jobs, full, { cfg = {}, svcUrl = null } = {}) {
  const tb = document.getElementById(tbodyId);
  if (!tb) return;
  if (!jobs.length) {
    tb.innerHTML = `<tr><td colspan="8" class="empty muted">No jobs.</td></tr>`;
    return;
  }

  const dur = j => {
    const end = j.published_at || j.updated_at, start = j.created_at;
    if (!end || !start) return '–';
    const v = (new Date(end) - new Date(start)) / 1000;
    return v > 0 && v < 86400 ? fmtSec(v) : '–';
  };

  // stageTip: hover tooltip with per-phase breakdown for bits jobs.
  const stageTip = j => {
    const ts = (s, e) => {
      if (!j[s] || !j[e]) return null;
      return (new Date(j[e]) - new Date(j[s])) / 1000;
    };
    const pipe   = ts('pipeline_started_at', 'pipeline_ended_at');
    const commit = ts('leased_at', 'published_at');
    const dist   = ts('distributing_started_at', 'distributing_ended_at');
    const parts  = [];
    if (pipe   != null) parts.push(`pipe:${pipe.toFixed(1)}s`);
    if (commit != null) parts.push(`commit:${commit.toFixed(1)}s`);
    if (dist   != null) {
      const s1info = j.distribution_confirmed != null
        ? ` (${j.distribution_confirmed}/${j.distribution_total} S1)`
        : ' (S1 async)';
      parts.push(`dist:${dist.toFixed(1)}s${s1info}`);
    }
    return parts.length ? parts.join(' | ') : '';
  };

  tb.innerHTML = jobs.map(j => {
    const state  = (j.state || 'unknown').toLowerCase();
    const badge  = stateBadge(state);
    const method = j.method || 'bits';
    const methodBadge = `<span class="badge" style="background:${method === 'ingest' ? '#6f42c1' : '#0075ca'};color:#fff;font-size:10px">${method}</span>`;
    const pipeline  = full ? `<td>${miniPipeline(state, j.failed_at_state)}</td>` : '';
    const tip       = stageTip(j);
    const durCell   = tip
      ? `<td title="${esc(tip)}" style="cursor:default">${dur(j)} <span style="font-size:10px;color:var(--c-muted)">ⓘ</span></td>`
      : `<td>${dur(j)}</td>`;
    const jobId   = j.id || j.job_id || '';
    const logHref = (svcUrl && jobId)
      ? esc(svcUrl('prepub', `/api/v1/jobs/${encodeURIComponent(jobId)}/log`))
      : '';
    const logCell = logHref
      ? `<td><a href="${logHref}" target="_blank" style="font-size:11px">log</a></td>`
      : `<td class="muted">–</td>`;
    return `<tr>
      <td class="mono">${esc((jobId || '–').slice(0, 8))}</td>
      <td>${esc(j.repo || cfg.repo || '')}</td>
      <td>${badge} ${methodBadge}</td>
      ${pipeline}
      ${durCell}
      <td class="mono" title="${esc(j.root_hash || '')}">${shortHash(j.root_hash || j.new_root_hash)}</td>
      <td>${relTime(j.created_at)}</td>
      ${logCell}
    </tr>`;
  }).join('');
}
