/**
 * service-health.js — Service health table row renderer.
 *
 * Produces HTML rows for the Services health table, handling both normal HTTP
 * services and MQTT-only services (Mosquitto).
 *
 * Usage:
 *   import { renderServiceRows } from './cvmfs-elements/js/widgets/service-health.js';
 *
 *   const rowHtml = renderServiceRows(results, {
 *     useMqtt:    USE_MQTT,
 *     serverMode: SERVER_MODE,
 *     svcUrl:     (id, path) => svcUrl(id, path),
 *     proxyPath:  id => `/api/proxy/${id}/`,
 *   });
 *   document.getElementById('svc-tbody').innerHTML = rowHtml;
 *
 * The probeService onclick calls `window.probeService(id, healthPath)`.
 * Expose that function on window from the page script.
 */

'use strict';

import { esc } from '../utils.js';

/**
 * Render table rows for an array of health-check results.
 *
 * @param {object[]} results
 *   Each entry is a service descriptor spread with health-check fields:
 *   { id, role, healthPath, mqttOnly?, ok, status, ms, err, inactive? }
 *
 * @param {object} opts
 * @param {boolean}         opts.useMqtt    - True when MQTT is active.
 * @param {boolean}         opts.serverMode - True when running in server mode.
 * @param {Function}        opts.svcUrl     - (id, path) => URL string for "↗" links.
 * @param {Function}        [opts.proxyPath] - (id) => proxy path string for the path column.
 *
 * @returns {string} HTML string suitable for setting as tbody innerHTML.
 */
export function renderServiceRows(results, {
  useMqtt    = false,
  serverMode = false,
  svcUrl     = () => '',
  proxyPath  = id => `/api/proxy/${id}/`,
} = {}) {
  return results.map(r => {
    if (r.mqttOnly) {
      // Mosquitto: no HTTP check — show active/inactive based on MQTT flag.
      const badge = useMqtt
        ? `<span class="badge ok">✓ active</span>`
        : `<span class="badge badge-unknown" style="background:#f0f0f0;color:#888">○ inactive</span>`;
      const note = useMqtt
        ? ''
        : `<span class="muted" style="font-size:11px;margin-left:6px">not configured</span>`;
      return `<tr style="${useMqtt ? '' : 'opacity:.55'}">
        <td><strong>${esc(r.id)}</strong></td>
        <td>${esc(r.role)}</td>
        <td class="mono" style="font-size:11px">${useMqtt ? proxyPath('mosquitto') : '–'}</td>
        <td>${badge}${note}</td>
        <td class="muted">–</td>
        <td></td>
      </tr>`;
    }

    const statusTxt = r.status ? `HTTP ${r.status}` : (r.err ? 'conn error' : '–');
    const probeBtn  = serverMode && !r.ok
      ? `<button class="btn btn-outline btn-sm" onclick="probeService('${esc(r.id)}','${esc(r.healthPath)}')">diagnose</button>`
      : `<a href="${esc(svcUrl(r.id, '/'))}" target="_blank">↗</a>`;

    return `<tr>
      <td><strong>${esc(r.id)}</strong></td>
      <td>${esc(r.role)}</td>
      <td class="mono" style="font-size:11px">${proxyPath(r.id)}</td>
      <td>
        <span class="badge ${r.ok ? 'ok' : 'err'}">${r.ok ? '✓ up' : '✗ down'}</span>
        ${!r.ok && statusTxt ? `<span class="muted" style="font-size:11px;margin-left:4px">${esc(statusTxt)}</span>` : ''}
      </td>
      <td>${r.ms}ms</td>
      <td>${probeBtn}</td>
    </tr>`;
  }).join('');
}
