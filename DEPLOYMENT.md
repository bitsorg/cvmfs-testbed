# Production Deployment Guide

This document describes how the services exercised by the testbed map onto a
production deployment: which components must be colocated, which can be
distributed, and how GitLab CI runners, monitoring, and the MQTT broker fit
into the picture.

The testbed intentionally collapses everything onto one host for convenience.
Production pulls the same components apart based on their actual dependencies.

---

## Service Inventory

| Service | Testbed container | Production role |
|---------|------------------|-----------------|
| `cvmfs-prepub` (publisher) | `cvmfs-prepub` | Accepts tar jobs, runs pipeline, uploads objects, commits |
| `cvmfs-gateway` | `gateway` | Lease manager, commit authority, wraps `cvmfs_receiver` |
| `cvmfs_receiver` | subprocess of gateway | C++ commit processor, spawned by gateway over pipes |
| Stratum 0 HTTP | `stratum0` (apache) | Serves the repository data and `.cvmfspublished` |
| CAS / object storage | shared volume | Stores all compressed, deduplicated objects |
| Stratum 1 receivers | `stratum1-a`, `stratum1-b` | Pull objects from CAS, serve repository to CVMFS clients |
| MQTT broker | `mosquitto` (optional) | Control-plane bus for announce/ready signalling |
| CI runners / bits builders | `act_runner` (host) | Build software, POST tar to cvmfs-prepub |
| Monitoring | `vmagent`, `victoriametrics` | Scrape metrics, store time series |
| Canary CVMFS client | `cvmfs-client` (testbed only) | Verify end-to-end file visibility after publish |

---

## Colocation Requirements

### Hard constraints (must share a machine or filesystem)

**`cvmfs-gateway` and `cvmfs_receiver`** must be colocated.
`cvmfs_receiver` is a subprocess of the gateway: the gateway spawns it and
communicates over stdin/stdout pipes (file descriptors 3 and 4). There is no
network protocol between them — they live on the same machine by design.

**`cvmfs-gateway` and Stratum 0 storage** must share a filesystem.
The gateway writes `.cvmfspublished`, tag records, and manifest updates
directly to the repository data directory. The Stratum 0 HTTP server (Apache
or nginx) serves that same directory. Both must see the same filesystem — same
machine, or a shared volume mounted on both.

### Soft constraint (bandwidth, not colocation)

**`cvmfs-prepub` and the CAS** need fast, low-latency access to the same
object store. If the CAS is a local filesystem, prepub and the gateway must
share it (colocation). If the CAS is S3 (or compatible object storage), this
constraint dissolves: prepub writes to S3, the gateway/Stratum 0 reads from
S3, and nothing needs to be colocated beyond having IAM credentials.

**S3 as the CAS is therefore the prerequisite for a fully distributed,
horizontally scalable deployment.**

### No colocation required

Everything else — `cvmfs-prepub` instances, Stratum 1 replicas, CI runners,
the MQTT broker, and monitoring — communicates over the network and can be
placed anywhere with appropriate network reach.

---

## Component Topology

### HTTP control-plane mode (no MQTT)

```
CI Runner / bits builder
        │
        │  POST /api/v1/jobs  (tar upload)
        │  GET  /api/v1/jobs/{id}/events  (SSE, job result)
        ▼
┌──────────────────────────────────────────────────────┐
│  cvmfs-prepub  (one or more instances)               │
│                                                      │
│  • dedup pipeline                                    │
│  • writes objects ──────────────────────────────────►│
│  • announces to Stratum 1 (HTTP)                     │  CAS / S3 bucket
│  • commits via gateway API                           │◄────────────────
└──────────────────────┬───────────────────────────────┘         │
                       │ HTTP lease / submit / commit             │ read
                       ▼                                          │
┌──────────────────────────────────────────────────────┐         │
│  cvmfs-gateway  +  cvmfs_receiver  (same machine)    │         │
│                                                      │         │
│  • lease manager (port 4929)                         │         │
│  • cvmfs_receiver downloads from Stratum 0 HTTP ─────┼─────────┘
│  • writes .cvmfspublished                            │
└──────────────────────┬───────────────────────────────┘
                       │ shared filesystem
                       ▼
              Stratum 0 HTTP server
              (serves CAS + manifests)
                       │
          ┌────────────┴────────────┐
          ▼                         ▼
    Stratum 1-A               Stratum 1-B
    (receives objects          (receives objects
     via HTTP PUT;              via HTTP PUT;
     serves CVMFS clients)      serves CVMFS clients)
          │                         │
          └────────────┬────────────┘
                       ▼
               CVMFS clients
```

### MQTT control-plane mode

MQTT moves the announce/ready exchange off direct HTTP and onto a message bus.
The data plane (object PUTs from prepub to Stratum 1) remains direct HTTP.

```
CI Runner / bits builder
        │  POST /api/v1/jobs
        ▼
  cvmfs-prepub
        │
        ├── write objects ──────────────────────► CAS / S3
        │
        ├── MQTT publish: cvmfs/prepub/announce ─► MQTT broker
        │                                               │
        │◄── MQTT subscribe: cvmfs/prepub/ready ────────┤
        │                                          subscribe │
        │   (Stratum 1 receivers subscribed)               │
        │                                         stratum1-a ◄─┘
        ├── HTTP PUT objects ─────────────────────► stratum1-b
        │
        ├── HTTP commit ──────────────────────────► cvmfs-gateway
        │
        └── MQTT publish: cvmfs/prepub/committed ─► MQTT broker
                                                        │
                                              subscribe │
                                           monitoring ◄─┘
                                           canary client
```

---

## GitLab Runners and bits Builders

CI runners are pure clients of `cvmfs-prepub`. Their only interaction with the
publishing stack is:

1. Build the software artifact (no CVMFS dependency)
2. `POST /api/v1/jobs` with the tar payload to `cvmfs-prepub`
3. Watch the SSE event stream for the job result

Runners need no access to the CAS, gateway, Stratum 0, Stratum 1, or any
CVMFS credentials. All secrets (gateway HMAC key, S3 credentials) live only on
the prepub service.

The only operational constraint is **bandwidth**: a runner must be able to
transfer the tar payload to prepub quickly. Runners and prepub instances should
therefore be in the same datacenter or cloud region, but there is no colocation
requirement beyond that.

Multiple prepub instances can serve runner pools in different regions, all
writing to the same S3 CAS and committing to the same gateway.

---

## Monitoring

Monitoring components are read-only network observers. They need no colocation
with any publishing component.

### What to monitor

| Component | Signal |
|-----------|--------|
| `cvmfs-prepub` | Job queue depth, state transition rates, pipeline throughput, error counts — via Prometheus scrape endpoint |
| `cvmfs-gateway` | Lease acquisition rate, commit duration, worker pool errors — structured JSON logs with `req_dt` / `action_dt` fields |
| Stratum 0 / Stratum 1 HTTP | Request rate, response latency, cache hit ratio — standard web server metrics |
| CAS / S3 | Storage growth, PUT/GET rate, object count — cloud provider metrics or node exporter |
| CVMFS client (canary) | End-to-end publish latency, catalog revision visibility |

### Placement

A Prometheus scraper, log shipper (Filebeat, Fluentd), and Alertmanager need
only network access to the services they observe. A managed metrics platform
(Grafana Cloud, Datadog, etc.) works with no on-premise components beyond a
lightweight scrape agent.

### Canary client

The testbed's `cvmfs-client` container acts as a canary by running
`verify-publish.sh` after each smoke test. In production this role belongs to a
dedicated host (or sidecar on a Stratum 1 node) that:

1. Mounts the repository via the standard CVMFS FUSE client
2. Subscribes to the post-commit MQTT topic (or polls the prepub SSE stream)
3. On each new revision: forces a remount, checks file visibility, records
   latency from job submission to client-visible change
4. Publishes the probe result back to a monitoring topic or pushes it as a
   metric

Without a canary you have a silent failure mode: commits succeed at the gateway
but clients do not see the update (Stratum 1 replication lag, signature
mismatch, misconfigured public key on clients).

The canary requires a host with `cvmfs2` installed and network access to at
least one Stratum 1 replica. It does not need access to the CAS, gateway, or
any write credentials.

---

## MQTT Broker

The broker is a lightweight, stateless relay. It does not store CAS objects or
repository data — only small control-plane messages (announce, ready, committed)
that are a few hundred bytes each.

**Placement:** anywhere with network reach from prepub, all Stratum 1 nodes,
the canary, and monitoring. A managed MQTT service (AWS IoT Core, HiveMQ Cloud,
Mosquitto on a small VM) is appropriate. No colocation with any other component
is required.

**Why MQTT adds value beyond HTTP announces:**

- **Decoupling**: prepub and Stratum 1 nodes do not need to know each other's
  addresses — only the broker's. New replicas subscribe at startup without
  reconfiguring prepub.
- **Backpressure**: if a Stratum 1 node is slow to acknowledge, prepub can
  delay the commit rather than proceeding with partial distribution — without
  any direct coupling between the components.
- **Fan-out**: the post-commit message reaches monitoring, the canary, and any
  other subscriber simultaneously, without prepub managing a list of
  destinations.
- **Auditability**: the broker's message log is a complete record of every
  publish event, independent of the prepub or gateway logs.

---

## Production Checklist

Items the testbed omits for simplicity that production requires:

- [ ] Gateway API endpoint uses HTTPS (testbed warns: "SECURITY: gateway URL is not HTTPS")
- [ ] Gateway API port (4929) firewalled to publisher host IPs only; no public access
- [ ] Stratum 1 control port (9100) firewalled to publisher host IPs only
- [ ] S3 bucket versioning and lifecycle policies configured for CAS objects
- [ ] CVMFS signing keys stored in a secrets manager; not on the gateway filesystem
- [ ] `dev: true` disabled in all service configs (enables TLS, strict HMAC verification)
- [ ] Canary client in place with alerting on publish latency and visibility failures
- [ ] Log retention policy for gateway receiver debug logs (`/var/log/cvmfs_receiver/`)
- [ ] Prepub job spool directory on durable storage (survives prepub container restart)
- [ ] Gateway and Stratum 0 on separate machines from prepub (blast radius isolation)
- [ ] MQTT broker with TLS and authentication (testbed uses anonymous plaintext)
