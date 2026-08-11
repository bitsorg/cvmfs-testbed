# cvmfs-elements

Shared building blocks for CVMFS web consoles and Docker deployments.

## Purpose

`cvmfs-elements` is a sub-repository providing CSS, JavaScript modules,
service-type definitions, and canonical Docker Compose base services that are
reused across CVMFS console applications and deployment environments:

| Consumer | Description |
|---|---|
| `cvmfs-testbed` | Local testbed — console, Docker Compose deployment, image builds |
| `cvmfs-console` | Production console — served by Nginx, MQTT-driven *(future)* |

## Structure

```
cvmfs-elements/
├── css/
│   └── console.css           # Shared stylesheet (tokens, layout, components)
├── js/
│   ├── utils.js              # DOM helpers ($, esc) and formatters (relTime, fmtSec, …)
│   ├── ui/
│   │   ├── collapse.js       # Collapsible sections with localStorage persistence
│   │   ├── dir-picker.js     # Server-side filesystem directory browser modal
│   │   ├── env-badge.js      # Environment identity badge in the header
│   │   └── refresh.js        # Auto-refresh countdown display
│   ├── services/
│   │   ├── definitions.js    # SERVICE_TYPES — canonical CVMFS service descriptors
│   │   └── containers.js     # CONTAINER_TYPES + populateContainerSelect helper
│   └── widgets/
│       ├── jobs.js           # Job table rendering (renderJobsTable, stateBadge, …)
│       └── service-health.js # Service health table row rendering
├── compose/
│   ├── core.yml              # gateway, stratum0, cvmfs-prepub base definitions
│   ├── receivers.yml         # stratum1 receiver base (no container_name)
│   ├── publishers.yml        # publisher, cvmfs-native-publisher, cvmfs-bootstrap
│   ├── client.yml            # cvmfs-client (SYS_ADMIN, /dev/fuse, apparmor)
│   ├── mqtt.yml              # mosquitto MQTT broker base
│   ├── monitoring.yml        # victoriametrics, vmagent, cadvisor, node-exporter
├── containers/
│   ├── gateway/              # Dockerfile + entrypoint for cvmfs-gateway
│   ├── stratum0/             # Dockerfile + Apache config for Stratum 0
│   ├── stratum1/             # Dockerfile for cvmfs-prepub in receiver mode
│   ├── cvmfs-prepub/         # Dockerfile for cvmfs-prepub (orchestrator/API)
│   ├── cvmfs-client/         # Dockerfile + entrypoint + verify scripts
│   ├── cvmfs-bootstrap/      # Dockerfile + bootstrap.sh (one-shot repo seeder)
│   ├── cvmfs-native-publisher/ # Dockerfile + entrypoint + native publish scripts
│   ├── publisher/            # Dockerfile + bits publish scripts
│   ├── monitoring/
│   │   └── scrape.yml        # Canonical vmagent scrape config (service-name based)
│   └── mosquitto/
│       └── mosquitto.conf    # Mosquitto broker config (dev/test: no auth, no TLS)
```

## Usage

All modules use native ES module syntax (`import`/`export`).  No build step
is required — serve the directory statically alongside your console HTML.

```html
<!-- In your console's <head> -->
<link rel="stylesheet" href="cvmfs-elements/css/console.css">

<!-- In your console's <script type="module"> -->
<script type="module">
import { $, esc, fmtSec } from './cvmfs-elements/js/utils.js';
import { SERVICE_TYPES }   from './cvmfs-elements/js/services/definitions.js';
import { renderJobsTable } from './cvmfs-elements/js/widgets/jobs.js';
// …
</script>
```

### Service type definitions

`SERVICE_TYPES` maps service role names to their generic properties.
Per-deployment consoles spread these into instance arrays:

```js
import { SERVICE_TYPES } from './cvmfs-elements/js/services/definitions.js';

const SVC_DEF = [
  { id: 'prepub',    ...SERVICE_TYPES.prepub },
  { id: 'gateway',   ...SERVICE_TYPES.gateway },
  { id: 'stratum0',  ...SERVICE_TYPES.stratum0 },
  { id: 's1a',       ...SERVICE_TYPES.stratum1, role: 'Stratum 1-A receiver' },
  { id: 's1b',       ...SERVICE_TYPES.stratum1, role: 'Stratum 1-B receiver' },
  { id: 'mosquitto', ...SERVICE_TYPES.mosquitto },
];
```

### Container type definitions

`CONTAINER_TYPES` describes each Docker container role in the CVMFS architecture.
Per-deployment consoles spread these into `CONTAINER_DEF` arrays, adding the
actual `container_name` from `docker-compose.yml`.

```js
import { CONTAINER_TYPES, populateContainerSelect }
  from './cvmfs-elements/js/services/containers.js';

const CONTAINER_DEF = [
  { id: 'prepub',    containerName: 'cvmfs-prepub',     ...CONTAINER_TYPES.prepub },
  { id: 'stratum0',  containerName: 'cvmfs-stratum0',   ...CONTAINER_TYPES.stratum0 },
  { id: 's1a',       containerName: 'cvmfs-stratum1-a', ...CONTAINER_TYPES.stratum1,
                     label: 'stratum1-a', role: 'Stratum 1-A receiver' },
  // … more instances …
];

// Populate a <select> with interactive containers (omits monitoring/bootstrap):
populateContainerSelect('cc-container', CONTAINER_DEF, { useMqtt: USE_MQTT, selected: 'cvmfs-client' });
```

The `populateContainerSelect` utility filters out `monitoringOnly` and
`testbedOnly` containers automatically, and conditionally includes `mqttOnly`
containers (like Mosquitto) when `useMqtt` is true.

### Window bridge pattern

ES modules are scoped — functions imported from `cvmfs-elements` are not
automatically available to inline `onclick=` HTML attributes.  Expose them
explicitly in your page script:

```js
import { openDirPicker, _dpNav, dpNavUp, dpSelectCurrent, closeDirPicker }
  from './cvmfs-elements/js/ui/dir-picker.js';

// Make imported functions reachable from onclick="..." in the HTML
Object.assign(window, { openDirPicker, _dpNav, dpNavUp, dpSelectCurrent, closeDirPicker });
```

## Docker Compose base library

The `compose/` directory contains canonical service definitions that are
referenced from per-deployment compose files via the Docker Compose `extends:`
directive.  This keeps intrinsic properties — image names, fixed commands,
kernel capabilities, host-path volumes for monitoring — in one place, while
deployment-specific configuration (build contexts, secret environment variables,
`${TESTBED_ROOT}` bind mounts, `depends_on` ordering) stays in the consuming
file.

```yaml
# In cvmfs-testbed/docker-compose.yml
services:
  gateway:
    extends:
      file: ./cvmfs-elements/compose/core.yml
      service: gateway
    build:
      context: ./gateway
    environment:
      CVMFS_GATEWAY_KEY_ID: ${CVMFS_GATEWAY_KEY_ID}
      # … secrets and repo-specific vars …
    volumes:
      - ${SOFTWARE_ROOT}/cvmfs_gateway:/usr/local/bin/cvmfs_gateway:ro
      # … ${TESTBED_ROOT} bind mounts …
    ports:
      - "4929:4929"
    depends_on:
      - stratum0
```

### What belongs in base files (`cvmfs-elements/compose/`)

| Field | Base file | Deployment file |
|---|---|---|
| `image:` | ✓ canonical image name | — |
| `container_name:` | ✓ (except multi-instance receivers) | stratum1-a, stratum1-b |
| `networks: [cvmfs-net]` | ✓ | — |
| `cap_add:`, `devices:`, `security_opt:` | ✓ intrinsic requirements | — |
| `privileged:` | ✓ (bootstrap, cadvisor) | — |
| `command:` (fixed) | ✓ | override in MQTT overlay |
| Host-path volumes (`/proc`, `/sys`, …) | ✓ (cadvisor, node-exporter) | — |
| `build: context:` | — | ✓ |
| `volumes:` with `${TESTBED_ROOT}` | — | ✓ |
| `environment:` secrets | — | ✓ |
| `ports:` | — | ✓ |
| `depends_on:` | — | ✓ |

### Stratum 1 multi-instance pattern

`receivers.yml` defines a single `stratum1` base without a `container_name`.
Deployments create as many named instances as needed, each adding its own
`container_name`, `NODE_ID`, and per-instance volumes:

```yaml
stratum1-a:
  extends:
    file: ./cvmfs-elements/compose/receivers.yml
    service: stratum1
  container_name: cvmfs-stratum1-a
  environment:
    NODE_ID: stratum1-a
  volumes:
    - ${TESTBED_ROOT}/data/s1a:/data/cas
    - ${TESTBED_ROOT}/config/stratum1-a/config.yaml:/etc/cvmfs-prepub/config.yaml:ro
```

### Scrape configuration

`containers/monitoring/scrape.yml` uses canonical Docker service names
(`cvmfs-prepub`, `stratum1-a`, `cadvisor`, …) and is invariant across
deployments.  vmagent mounts it from a path resolved relative to
`compose/monitoring.yml`, so no
per-deployment override is needed for the scrape config itself.  Deployments
only supply the vmagent data directory via a `volumes:` addition.

### Requirements

- Docker Compose v2 (`docker compose` plugin); the `extends:` directive with
  `file:` is not supported by the legacy `docker-compose` v1 binary.

## Design principles

- **No dependencies** — vanilla JS and CSS only; no framework, no build step.
- **CSS custom properties** — all colours and dimensions flow from `:root` tokens;
  consoles override them per-environment without touching component CSS.
- **Pure renderers** — widget functions accept data and return HTML strings or
  mutate a target element; they do not fetch data themselves.
- **Configurable via callbacks** — components like `dir-picker` receive
  `getServerToken` and `onSelect` callbacks so testbed and production consoles
  can plug in their own auth and routing without forking the module.
