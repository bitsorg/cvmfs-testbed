/**
 * definitions.js — Canonical CVMFS service type definitions.
 *
 * SERVICE_TYPES defines the generic properties of each service role.
 * Per-deployment console scripts spread these into concrete SVC_DEF instances
 * and add deployment-specific fields (e.g. unique ids for multiple Stratum 1s):
 *
 *   import { SERVICE_TYPES } from './cvmfs-elements/js/services/definitions.js';
 *
 *   const SVC_DEF = [
 *     { id: 'prepub',    ...SERVICE_TYPES.prepub },
 *     { id: 'gateway',   ...SERVICE_TYPES.gateway },
 *     { id: 'stratum0',  ...SERVICE_TYPES.stratum0 },
 *     { id: 's1a',       ...SERVICE_TYPES.stratum1, role: 'Stratum 1-A receiver' },
 *     { id: 's1b',       ...SERVICE_TYPES.stratum1, role: 'Stratum 1-B receiver' },
 *     { id: 'mosquitto', ...SERVICE_TYPES.mosquitto },
 *   ];
 *
 * Field reference:
 *
 *   role         Human-readable role label shown in the Services table.
 *   healthPath   HTTP path probed to determine service liveness.
 *   defaultPort  Well-known port for the service (informational; not used for routing).
 *   mqttOnly     When true the service has no HTTP health endpoint — liveness is
 *                derived from the USE_MQTT flag instead.
 */

'use strict';

export const SERVICE_TYPES = {

  /** cvmfs-prepub — job orchestrator and REST API */
  prepub: {
    role: 'Orchestrator/API',
    healthPath: '/api/v1/health',
    defaultPort: 8080,
  },

  /** cvmfs_gateway — repository lease manager */
  gateway: {
    role: 'Lease manager',
    healthPath: '/api/v1/repos',
    defaultPort: 4929,
  },

  /** Apache httpd serving the Stratum 0 repository over HTTP */
  stratum0: {
    role: 'Content server',
    healthPath: '/',
    defaultPort: 8090,
  },

  /**
   * cvmfs-prepub in receiver mode (Stratum 1).
   * Deployments with more than one receiver create separate instances
   * and override `role` to distinguish them (e.g. "Stratum 1-A receiver").
   */
  stratum1: {
    role: 'Stratum 1 receiver',
    healthPath: '/metrics',
    defaultPort: 9100,
  },

  /**
   * Eclipse Mosquitto MQTT broker.
   * mqttOnly=true: no HTTP health endpoint; liveness derived from USE_MQTT flag.
   */
  mosquitto: {
    role: 'MQTT broker',
    healthPath: '/',
    defaultPort: 1883,
    mqttOnly: true,
  },

};
