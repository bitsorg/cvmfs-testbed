/**
 * containers.js — Canonical CVMFS container type definitions.
 *
 * CONTAINER_TYPES describes each distinct container role in the CVMFS
 * architecture.  Per-deployment console scripts spread these into concrete
 * CONTAINER_DEF arrays, adding the actual Docker container_name and any
 * per-instance overrides (e.g. unique labels for multiple Stratum 1s):
 *
 *   import { CONTAINER_TYPES } from './cvmfs-elements/js/services/containers.js';
 *
 *   const CONTAINER_DEF = [
 *     { id:'prepub',    containerName:'cvmfs-prepub',          ...CONTAINER_TYPES.prepub },
 *     { id:'gateway',   containerName:'cvmfs-gateway',         ...CONTAINER_TYPES.gateway },
 *     { id:'stratum0',  containerName:'cvmfs-stratum0',        ...CONTAINER_TYPES.stratum0 },
 *     { id:'s1a',       containerName:'cvmfs-stratum1-a',      ...CONTAINER_TYPES.stratum1, label:'stratum1-a', role:'Stratum 1-A receiver' },
 *     { id:'s1b',       containerName:'cvmfs-stratum1-b',      ...CONTAINER_TYPES.stratum1, label:'stratum1-b', role:'Stratum 1-B receiver' },
 *     { id:'publisher',       containerName:'cvmfs-publisher',        ...CONTAINER_TYPES.publisher },
 *     { id:'nativePublisher', containerName:'cvmfs-native-publisher', ...CONTAINER_TYPES.nativePublisher },
 *     { id:'client',    containerName:'cvmfs-client',          ...CONTAINER_TYPES.client },
 *     { id:'mosquitto', containerName:'cvmfs-mosquitto',       ...CONTAINER_TYPES.mosquitto },
 *     { id:'bootstrap', containerName:'cvmfs-bootstrap',       ...CONTAINER_TYPES.bootstrap },
 *     { id:'victoriametrics', containerName:'cvmfs-victoriametrics', ...CONTAINER_TYPES.victoriametrics },
 *     { id:'vmagent',         containerName:'cvmfs-vmagent',         ...CONTAINER_TYPES.vmagent },
 *     { id:'cadvisor',        containerName:'cvmfs-cadvisor',        ...CONTAINER_TYPES.cadvisor },
 *     { id:'nodeExporter',    containerName:'cvmfs-node-exporter',   ...CONTAINER_TYPES.nodeExporter },
 *   ];
 *
 * Field reference:
 *
 *   label          Short name shown in UI dropdowns and topology labels.
 *   role           Human-readable role description.
 *   color          Hex colour used for topology diagram nodes.
 *   description    One-sentence description of what the container does.
 *   mqttOnly       (optional) Container only present when MQTT is active.
 *   testbedOnly    (optional) One-shot / privileged container used in testbed only.
 *   monitoringOnly (optional) Part of the monitoring stack, not a CVMFS service.
 *
 * Note: containerName is NOT set here — it belongs in the per-deployment
 * CONTAINER_DEF because container_names vary per environment (prefix, suffix,
 * multi-instance numbering, etc.).
 */

'use strict';

export const CONTAINER_TYPES = {

  // ── Core publish pipeline ─────────────────────────────────────────────────

  /** cvmfs-prepub REST API and job orchestrator */
  prepub: {
    label: 'cvmfs-prepub',
    role: 'Orchestrator/API',
    color: '#0550ae',
    description: 'REST API front-end; orchestrates bits jobs through the publish pipeline.',
  },

  /** cvmfs_gateway + cvmfs_receiver — repository lease manager */
  gateway: {
    label: 'cvmfs-gateway',
    role: 'Lease manager',
    color: '#6f42c1',
    description: 'Manages repository leases; spawns cvmfs_receiver to commit object batches.',
  },

  /** Apache httpd serving the Stratum 0 repository CAS over HTTP */
  stratum0: {
    label: 'stratum0',
    role: 'Content server',
    color: '#854d0e',
    description: 'Serves the authoritative Stratum 0 repository objects over HTTP.',
  },

  /**
   * cvmfs-prepub in receiver mode (Stratum 1).
   * Deployments with multiple receivers create separate instances and override
   * `label` and `role` (e.g. "stratum1-a", "Stratum 1-A receiver").
   */
  stratum1: {
    label: 'stratum1',
    role: 'Stratum 1 receiver',
    color: '#1a7f37',
    description: 'Pulls new objects from Stratum 0 and exposes them as a Stratum 1 mirror.',
  },

  // ── Publishers ────────────────────────────────────────────────────────────

  /** REST API client submitting bits jobs to cvmfs-prepub */
  publisher: {
    label: 'publisher',
    role: 'Bits publisher',
    color: '#0075ca',
    description: 'Submits bits publish jobs to cvmfs-prepub via the REST API.',
  },

  /** cvmfs_server ingest path via gateway API */
  nativePublisher: {
    label: 'cvmfs-native-publisher',
    role: 'Native publisher',
    color: '#0075ca',
    description: 'Exercises the cvmfs_server ingest path (cvmfs_swissknife → gateway → receiver).',
  },

  // ── Client ────────────────────────────────────────────────────────────────

  /** FUSE-mounted CVMFS client for post-publish verification */
  client: {
    label: 'cvmfs-client',
    role: 'CVMFS client',
    color: '#586069',
    description: 'Mounts the repository via FUSE; used by verify-publish.sh to check visibility.',
  },

  // ── MQTT ─────────────────────────────────────────────────────────────────

  /** Eclipse Mosquitto MQTT broker for control-plane signalling */
  mosquitto: {
    label: 'cvmfs-mosquitto',
    role: 'MQTT broker',
    color: '#e36209',
    mqttOnly: true,
    description: 'MQTT broker used for announce/ready exchange and PublishedMessage notifications.',
  },

  // ── Testbed-only ──────────────────────────────────────────────────────────

  /**
   * One-shot privileged bootstrap container.
   * Seeds the repository nested-catalog structure before the first publish.
   */
  bootstrap: {
    label: 'cvmfs-bootstrap',
    role: 'Bootstrap',
    color: '#586069',
    testbedOnly: true,
    description: 'One-shot privileged container that seeds the repository nested-catalog structure.',
  },

  // ── Monitoring stack ──────────────────────────────────────────────────────

  /** VictoriaMetrics time-series database */
  victoriametrics: {
    label: 'cvmfs-victoriametrics',
    role: 'Metrics storage',
    color: '#586069',
    monitoringOnly: true,
    description: 'Stores Prometheus-format metrics scraped by vmagent.',
  },

  /** vmagent — scrapes Prometheus endpoints, remote-writes to VictoriaMetrics */
  vmagent: {
    label: 'cvmfs-vmagent',
    role: 'Metrics scraper',
    color: '#586069',
    monitoringOnly: true,
    description: 'Scrapes service /metrics endpoints and forwards data to VictoriaMetrics.',
  },

  /** cAdvisor — per-container CPU / memory / network / disk metrics */
  cadvisor: {
    label: 'cvmfs-cadvisor',
    role: 'Container metrics',
    color: '#586069',
    monitoringOnly: true,
    description: 'Collects per-container resource utilisation metrics.',
  },

  /** Prometheus node exporter — host-level metrics */
  nodeExporter: {
    label: 'cvmfs-node-exporter',
    role: 'Host metrics',
    color: '#586069',
    monitoringOnly: true,
    description: 'Exposes host CPU, memory, and filesystem metrics in Prometheus format.',
  },

};

// ── Utility ───────────────────────────────────────────────────────────────────

/**
 * Populate a <select> element with options for interactive containers.
 *
 * "Interactive" means: not monitoringOnly, not testbedOnly, and either always
 * present or currently active (mqttOnly containers are omitted when useMqtt
 * is false).
 *
 * @param {string}   selectId     - Element ID of the target <select>.
 * @param {object[]} containerDef - Per-deployment CONTAINER_DEF array.
 * @param {object}   opts
 * @param {boolean}  [opts.useMqtt=false]  - Include mqttOnly containers.
 * @param {string}   [opts.selected]       - containerName to pre-select.
 */
export function populateContainerSelect(selectId, containerDef, { useMqtt = false, selected = '' } = {}) {
  const el = document.getElementById(selectId);
  if (!el) return;
  const visible = containerDef.filter(c =>
    !c.monitoringOnly &&
    !c.testbedOnly &&
    (!c.mqttOnly || useMqtt),
  );
  el.innerHTML = visible.map(c => {
    const sel = c.containerName === selected ? ' selected' : '';
    return `<option value="${c.containerName}"${sel}>${c.label}</option>`;
  }).join('');
}
