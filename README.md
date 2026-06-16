# cvmfs-prepub Testbed

## Overview

This testbed spins up a complete cvmfs-prepub stack using Docker Compose, exercising the full Option B path with two Stratum 1 receivers. It uses `dev: true` mode to avoid TLS and key management overhead, making it ideal for testing and development.

All persistent state lives under `TESTBED_ROOT` on the host (a single external disk), and all binaries under test are injected from `SOFTWARE_ROOT` without being baked into images. This allows you to swap binary versions without rebuilding containers.

The system simulates the complete CVMFS publishing workflow:
1. Publisher submits a tar job to the cvmfs-prepub REST API
2. cvmfs-prepub processes the tar, writes objects to the CAS (shared directory)
3. cvmfs-prepub pre-warms two Stratum 1 receivers via HTTP announce and object PUT
4. cvmfs-prepub commits the catalog update to cvmfs_gateway
5. cvmfs_gateway updates `.cvmfspublished` in the repository root
6. Apache (Stratum 0) serves the repository over HTTP
7. The CVMFS client container mounts the repository via FUSE and confirms file visibility

Two control-plane modes are available. The default mode uses direct HTTP announces between cvmfs-prepub and the Stratum 1 receivers. Activating `docker-compose.mqtt.yml` instead routes all control-plane signalling through a Mosquitto MQTT broker, exercising the Option B MQTT path described in REFERENCE.md §20.11.

Monitoring is built in with VictoriaMetrics and vmagent; real-time host metrics and run history are shown directly in the testbed web console.

## Architecture Diagrams

### Full stack with bits-console and Gitea (docker-compose.bits.yml overlay)

```
╔══════════════════════════════ Physical Host ═════════════════════════════════╗
║                                                                              ║
║  Browser                                                                     ║
║    │  http://testbed.localhost:3000/bits-project/testbed/                   ║
║    │  (bits-console SPA, served by Gitea Pages gh-pages branch)             ║
║    │                                                                         ║
║    │  POST /api/v1/repos/testbed/bits-project/actions/workflows/            ║
║    │       bits-publish.yaml/dispatches                                      ║
║    ▼                                                                         ║
║  ┌──────────────────────────────────────────────────────────────────────┐   ║
║  │ Docker Compose                                                        │   ║
║  │                                                                       │   ║
║  │  gitea:3000 ────────── dispatches workflow ──────────────────────►  │   ║
║  │      │                                           act_runner (host)   │   ║
║  │  (Pages at testbed.localhost:3000)                      │            │   ║
║  │                                               ┌─────────┴──────────┐│   ║
║  │  seeder ──init──► gitea (org/repo/pages)      │  job steps         ││   ║
║  │                                               │  • checkout        ││   ║
║  │  cvmfs-prepub:8080 ◄── bits publish ──────────┤  • bits build      ││   ║
║  │      │                                        │  • bits publish    ││   ║
║  │      ├──► stratum1-a:9100/9101                └────────────────────┘│   ║
║  │      ├──► stratum1-b:9100/9101                                       │   ║
║  │      └──► gateway:4929                                               │   ║
║  │              │                                                       │   ║
║  │         stratum0:80                                                  │   ║
║  │              │                                                       │   ║
║  │         cvmfs-client (FUSE)                                          │   ║
║  │                                                                       │   ║
║  │  victoriametrics + vmagent + cAdvisor                               │   ║
║  └──────────────────────────────────────────────────────────────────────┘   ║
╚══════════════════════════════════════════════════════════════════════════════╝
```

### Job submission chain (10 steps)

```
Step  Who           Action
────  ────────────  ──────────────────────────────────────────────────────────
 1    Browser       User fills in Package/Version/Platform form in bits-console
                    SPA (served via Gitea Pages at testbed.localhost:3000)
 2    bits-console  POST /api/v1/repos/{org}/{repo}/actions/workflows/
                         bits-publish.yaml/dispatches
                    with inputs: COMMUNITY, PACKAGE, VERSION, PLATFORM …
 3    Gitea         Enqueues a workflow_dispatch run; assigns run_id
 4    act_runner    Polls Gitea for pending jobs; picks up the run
                    (runner is registered with labels [self-hosted, bits])
 5    act_runner    Executes bits-publish.yaml steps on the physical host:
                    a) actions/checkout@v3 — checks out the repo into a workspace
                    b) Validate community config (reads ui-config.yaml)
                    c) Authorize submitter (checks admins list)
                    d) Set up bits environment (sources config/bits-setup.sh)
                    e) bits build — builds the package into $JOB_SCRATCH
                    f) bits publish — POSTs tar to cvmfs-prepub:8080
 6    cvmfs-prepub  Accepts tar, deduplicates objects, writes WAL entry
 7    cvmfs-prepub  Announces job to stratum1-a and stratum1-b (HTTP or MQTT)
                    Receivers pull objects from CAS; reply with "ready"
 8    cvmfs-prepub  Acquires lease from gateway:4929 (HMAC auth)
                    Updates catalog, commits → .cvmfspublished written
 9    act_runner    bits publish returns 0; step g) updates cvmfs-status.json
                    in the repo (git push to main)
10    Browser       bits-console polls workflow run status via Gitea API;
                    shows "published" badge; user can verify via cvmfs-client
```

### HTTP mode (default, no overlay)

```
publisher ──POST /api/v1/jobs──► cvmfs-prepub:8080
                                        │
                          ┌─────────────┼─────────────┐
                          │             │             │
                  announce:9100   announce:9100    PUT /api/v1/leases
                          │             │             │
                    stratum1-a    stratum1-b       gateway:4929
                    PUT:9101      PUT:9101              │
                                                  writes .cvmfspublished
                                                        │
                                                  stratum0 (apache:80)
                                                  serves CAS + manifests
                                                        │
                                                  cvmfs-client (FUSE)
                                                  verifies file visibility

vmagent ──scrapes──► cvmfs-prepub, gateway, stratum1-a, stratum1-b
vmagent ──push──► victoriametrics:8428
testbed-console ──reads──► /api/host-metrics, /api/runs
```

### MQTT mode (docker-compose.mqtt.yml overlay)

```
publisher ──POST /api/v1/jobs──► cvmfs-prepub:8080
                                        │
                              publish announce
                                        │
                                  mosquitto:1883
                              ┌─────────┤
                   subscribe  │         │  subscribe
                              │         │
                        stratum1-a   stratum1-b
                        PUT:9101     PUT:9101 ◄── data plane (direct HTTP)
                                                       │
                                                 gateway:4929
                                                       │
                                             writes .cvmfspublished
```

### Pull mode (docker-compose.pull.yml overlay — ADR-0001)

Pull mode reverses the data plane: instead of the publisher pushing objects to
each Stratum 1, the receivers fetch what they are missing from Stratum 0 when a
prepare announce arrives over MQTT (so it implies the MQTT overlay). The control
plane is unchanged; only who initiates the object transfer flips.

```
publisher ──POST /api/v1/jobs──► cvmfs-prepub:8080  (serves manifest + objects)
                                        │
                              prepare announce
                                        │
                                  mosquitto:1883
                              ┌─────────┤
                   subscribe  │         │  subscribe
                              │         │
                        stratum1-a   stratum1-b
                              │         │
                              └──GET /s1/{txn}/manifest, then GET objects──┐
                                                                          │
                                                                    cvmfs-prepub
                                                            (Stratum 0 serves data)
```

Run it with `make start-pull` / `make PULL=1 <target>`, or `./testbed.sh start
--pull`. End-to-end check: `make test-pull` (verifies each receiver pulled the
new objects itself); monitor with `make pull-status`. CI for the profile lives
in `.gitlab-ci.yml` (`validate:pull-profile` renders the overlay on every change;
`live-e2e:pull` runs the full test on a privileged runner, manually).

## Directory Layout

The testbed uses a **fixed directory convention** so that no path variables need to be set in `.env`. Clone or symlink the source trees directly inside the `cvmfs-testbed/` checkout, then run `install.sh` once to populate `software/`.

```
cvmfs-testbed/               ← this repository
├── Makefile                 # Top-level build and lifecycle automation
├── testbed.sh               # Management script (called by Makefile)
├── install.sh               # Populates software/ from cvmfs/build/
├── init.sh                  # One-time host setup (called by testbed.sh init)
├── docker-compose.yml       # Core services (HTTP mode)
├── docker-compose.mqtt.yml  # Overlay: MQTT control plane
├── docker-compose.bits.yml  # Overlay: Gitea + seeder for bits-console
├── .env.example             # Environment template (secrets only)
├── README.md                # This file
│
├── cvmfs/                   # ← CVMFS source tree (git clone or symlink HERE)
│   ├── cvmfs/
│   │   ├── make_cvmfs_server.sh
│   │   └── server/          # Patched server shell scripts
│   └── build/               # cmake build output (run cmake + make here)
│       ├── cvmfs_publish
│       ├── cvmfs_swissknife
│       └── libcvmfs_server.so.*
│
├── cvmfs-bits/              # ← cvmfs-bits source tree (git clone or symlink HERE)
│   │                        #   Builds cvmfs-prepub and cvmfs_gateway binaries
│   └── Makefile             #   `make build` produces the binaries
│
├── bits-console/            # ← bits-console source (git clone or symlink HERE)
│   │                        #   Required only for the --bits overlay
│   └── build-communities.sh
│
├── software/                # ← Populated by install.sh (never edit manually)
│   ├── cvmfs_server         # Rebuilt from patched cvmfs/cvmfs/server/
│   ├── cvmfs_publish
│   ├── cvmfs_swissknife
│   ├── libcvmfs_server.so.*
│   ├── cvmfs-prepub         # Built by cvmfs-bits/Makefile, installed by install.sh
│   ├── cvmfs_gateway        # Built by cvmfs-bits/Makefile, installed by install.sh
│   ├── cvmfs2               # ← copy your built binary here manually
│   └── cvmfs_talk           # ← copy your built binary here manually
│
├── tools/
│   └── dump-catalogs.sh     # Decompress and SQL-dump all catalogs (host-side)
│
├── gateway/
│   └── Dockerfile
├── stratum0/
│   ├── Dockerfile
│   └── httpd.conf
├── cvmfs-prepub/
│   └── Dockerfile
├── stratum1/
│   └── Dockerfile
├── publisher/
│   ├── Dockerfile
│   └── scripts/
│       ├── smoke-test.sh        # Comprehensive smoke test (bits path)
│       ├── stress-test.sh       # Stress test (bits path)
│       └── make-test-payload.sh # Shared comprehensive test payload builder
├── cvmfs-native-publisher/
│   ├── Dockerfile
│   ├── entrypoint.sh
│   └── scripts/
│       ├── native-smoke.sh      # Comprehensive smoke test (cvmfs_server ingest)
│       ├── native-stress.sh     # Stress test (ingest path)
│       └── make-test-payload.sh # Shared comprehensive test payload builder
├── cvmfs-client/
│   ├── Dockerfile
│   ├── entrypoint.sh
│   └── scripts/
│       └── verify-publish.sh
├── mosquitto/
│   └── mosquitto.conf
├── seeder/
│   ├── Dockerfile
│   └── seed.py
├── act_runner/
│   ├── config.yaml
│   └── act_runner.service
└── monitoring/
    └── scrape.yml

${TESTBED_ROOT}/             ← All persistent runtime state (default: $HOME/cvmfs-testbed)
├── repos/                   # CVMFS repository data (created by cvmfs_server mkfs,
│   └── ${REPO_NAME}/        #   symlinked from /srv/cvmfs — NOT the source tree)
│       ├── .cvmfspublished
│       ├── .cvmfswhitelist
│       └── data/
├── data/
│   ├── spool/               # cvmfs-prepub WAL journal and job state
│   ├── s1a/                 # Stratum 1 receiver A CAS
│   ├── s1b/                 # Stratum 1 receiver B CAS
│   ├── cvmfs-client/        # CVMFS client disk cache
│   ├── mosquitto/           # Mosquitto persistence (MQTT mode)
│   ├── mosquitto-log/       # Mosquitto logs (MQTT mode)
│   ├── gitea/               # Gitea database + repos (bits overlay)
│   └── monitoring/
│       ├── vm/              # VictoriaMetrics data
│       └── vmagent/         # vmagent data
└── config/                  # Generated configs (init.sh writes these)
    ├── gateway/
    │   ├── gw.json
    │   ├── user.json
    │   └── repo.json
    ├── keys/                # CVMFS signing keys
    ├── cvmfs-prepub/
    │   └── config.yaml
    ├── stratum1-a/
    │   └── config.yaml
    └── stratum1-b/
        └── config.yaml
```

## Prerequisites

### Core testbed

- **Docker** ≥ 24 with Compose v2 plugin — check: `docker compose version`
- **openssl** (secret generation) — usually pre-installed
- **FUSE kernel module** loaded — check: `lsmod | grep fuse`; if absent: `sudo modprobe fuse`
- **CVMFS source tree** cloned (or symlinked) at `cvmfs-testbed/cvmfs/`
  - `git clone https://github.com/cvmfs/cvmfs cvmfs`
  - `cmake -S cvmfs -B cvmfs/build && make -C cvmfs/build -j$(nproc)`
  - `./install.sh`   ← copies binaries to `software/` and rebuilds `cvmfs_server`
- **Compiled binaries** for cvmfs-prepub, cvmfs_gateway, cvmfs2, cvmfs_talk copied to `software/`

### bits-console overlay (optional)

- **bits-console** source tree cloned (or symlinked) at `cvmfs-testbed/bits-console/`
  - `git clone https://github.com/your-org/bits-console bits-console`
  - No `.env` change needed — the path is fixed by convention.
- **act_runner** binary on the host — download from https://gitea.com/gitea/act_runner/releases
- **bits** build toolchain installed on the host
- The operator's Unix user must be in the **docker** group (runner spawns Docker containers)
- Modern browser for the SPA (Chrome, Firefox, Edge). Safari requires adding `127.0.0.1 testbed.localhost` to `/etc/hosts`.

## testbed.sh — Management Script

`testbed.sh` is the recommended entry point for all testbed operations. It wraps `init.sh` and `docker compose` to give a single, consistent interface.

```
./testbed.sh <command> [options] [args]
```

| Command              | Description                                                          |
|----------------------|----------------------------------------------------------------------|
| `init`               | Create directories, generate secrets, write configs, run mkfs        |
| `start`              | Build images (if needed) and start all services                      |
| `stop`               | Stop containers (preserves state)                                    |
| `restart`            | Stop then start                                                      |
| `status`             | Show container status and spot-check service health                  |
| `info`               | Print all service endpoints, ports, and credentials                  |
| `logs [svc]`         | Tail logs (all services or one named service)                        |
| `test`               | Run comprehensive smoke test (default method: `bits`)                |
| `stresstest <n>`     | Stress test with *n* jobs (default method: `bits`)                   |
| `catdump [label]`    | Decompress and SQL-dump all catalogs from the current snapshot       |
| `catdiff [a] [b]`    | Diff two catalog dump sets (default: `ingest` vs `bits`)             |
| `verify <id> [path]` | Verify end-to-end file visibility for a job UUID                     |
| `clean`              | Stop containers **and** remove all persistent host state             |
| `reset`              | `clean` + `init` + `start`                                          |

**Flags:**

| Flag                  | Effect                                                                    |
|-----------------------|---------------------------------------------------------------------------|
| `--bits`              | Include the bits-console overlay (requires `bits-console/` to exist)      |
| `--mqtt`              | Include the MQTT control-plane overlay                                     |
| `--method bits\|ingest` | Publishing path for `test`/`stresstest`: `bits` (REST API, default) or `ingest` (`cvmfs_server ingest`) |
| `-y`, `--yes`         | Skip interactive confirmation prompts (used by `make clean`)              |
| `--software-root PATH`| Override the `software/` directory                                        |
| `--testbed-root PATH` | Override the testbed data root (default: `$HOME/cvmfs-testbed`)           |

**Examples:**

```bash
# Core stack only
./testbed.sh init
./testbed.sh start
./testbed.sh test                        # bits smoke test
./testbed.sh test --method ingest        # native cvmfs_server ingest smoke test
./testbed.sh stresstest 20               # 20 jobs via bits REST API
./testbed.sh stresstest 20 --method ingest
./testbed.sh logs cvmfs-prepub

# Catalog structure comparison between publishing paths
./testbed.sh test --method ingest && ./testbed.sh catdump ingest
./testbed.sh test --method bits   && ./testbed.sh catdump bits
./testbed.sh catdiff ingest bits         # writes ingest_vs_bits.diff

# Core stack + MQTT control plane
./testbed.sh start --mqtt

# Full stack with bits-console (bits-console/ must already be present)
./testbed.sh init  --bits
./testbed.sh start --bits

# Tear down everything and start fresh
./testbed.sh reset --bits
```

---

## Makefile — Quick Reference

The `Makefile` is the recommended entry point for day-to-day development. It encodes the full dependency chain — pull source, build, install binaries, redeploy — so a single command keeps everything in sync.

### Targets

| Target               | What it does                                                                      |
|----------------------|-----------------------------------------------------------------------------------|
| `make`               | Pull + build `cvmfs-bits`, install binaries, stop → clean → init → start testbed |
| `make build`         | `git pull` + `make build` inside `cvmfs-bits/` only                              |
| `make install`       | `build`, then copy binaries to `software/`                                        |
| `make redeploy`      | `install` + stop → clean → init → start (skip the source pull)                   |
| `make clean`         | Stop containers and wipe all testbed state (no confirmation prompt)               |
| `make test`          | Smoke test — bits REST API path                                                   |
| `make test-ingest`   | Smoke test — `cvmfs_server ingest` path                                           |
| `make test-bits`     | Smoke test — bits REST API path (explicit alias)                                  |
| `make stresstest`    | Stress test, `N` jobs via bits (default `N=10`)                                   |
| `make stresstest-ingest` | Stress test, `N` jobs via ingest                                              |
| `make catdump-ingest`| Dump catalogs from the current snapshot, labelled `ingest`                        |
| `make catdump-bits`  | Dump catalogs from the current snapshot, labelled `bits`                          |
| `make catdiff`       | Diff `ingest` vs `bits` catalog dumps                                             |
| `make scenario SCENARIO=…` | Start + smoke-test a named distribution scenario (`push`/`mqtt`/`pull`/`ingest`) |
| `make scenario-pull` | Convenience alias for `make scenario SCENARIO=pull` (also `-push`/`-mqtt`/`-ingest`) |
| `make test-pull`     | End-to-end pull-distribution test (ADR-0001)                                      |
| `make pull-status`   | Dump pull-relevant publisher/receiver log lines                                   |
| `make help`          | Print the target summary with current variable values                             |

### Distribution scenarios

A **scenario** bundles the `--method` / `--mqtt` / `--pull` flags into one word so
you can switch distribution models in a single command, via `./testbed.sh`, the
`Makefile`, or the console's Monitoring tab (Scenario dropdown → Apply):

| Scenario | Model | Flags |
|----------|-------|-------|
| `push`   | legacy push, no control plane | bits, no overlays |
| `mqtt`   | push data + MQTT control plane | bits, `--mqtt` |
| `pull`   | ADR-0001 pull distribution | bits, `--mqtt --pull` |
| `ingest` | native `cvmfs_server` ingest | ingest, no overlays |

```
./testbed.sh start --scenario pull && ./testbed.sh pulltest --scenario pull
make scenario-pull
```

The Monitoring tab adds a **Pull Distribution** panel (receiver pull object rate
by result, warm-transaction rate) sourced from VictoriaMetrics, and the
publisher-side `cvmfs_prepub_dist_*` counters (warm-quorum, commit, admission)
appear in the Prometheus Metrics table; receiver-side `cvmfs_receiver_pull_*`
metrics are scraped from each Stratum 1.

### Variables

| Variable   | Default                      | Description                                      |
|------------|------------------------------|--------------------------------------------------|
| `BITS_DIR` | `$(CURDIR)/cvmfs-bits`       | Path to the `cvmfs-bits` source tree             |
| `N`        | `10`                         | Number of jobs for `stresstest` targets          |

### Common workflows

```bash
# First run — full setup from source
make

# Day-to-day iteration after changing cvmfs-bits source
make

# Rebuild and redeploy without pulling (e.g. local uncommitted changes)
make redeploy

# Run both smoke tests and compare catalog structure
make test-ingest catdump-ingest test-bits catdump-bits catdiff

# Stress test with a custom job count
make stresstest N=50
make stresstest-ingest N=50

# Use a cvmfs-bits clone that lives outside the testbed directory
make BITS_DIR=/home/user/src/cvmfs-bits

# Wipe everything and start over (no confirmation prompt)
make clean && make
```

### How `make` maps to `testbed.sh`

```
make build       →  cd cvmfs-bits && git pull && make build
make install     →  make build  +  ./install.sh
make redeploy    →  make install
                    ./testbed.sh stop
                    ./testbed.sh clean --yes
                    ./testbed.sh init
                    ./testbed.sh start
make clean       →  ./testbed.sh stop
                    ./testbed.sh clean --yes
make test        →  ./testbed.sh test --method bits
make test-ingest →  ./testbed.sh test --method ingest
make stresstest  →  ./testbed.sh stresstest $(N) --method bits
make catdiff     →  ./testbed.sh catdiff ingest bits
```

---

## Quick Start

The recommended entry point is `make`. It handles the full build-install-deploy sequence automatically. Use `testbed.sh` directly when you need finer control over individual steps.

### With `make` (recommended)

1. **Clone the repository and enter it**
   ```bash
   git clone https://github.com/your-org/cvmfs-testbed
   cd cvmfs-testbed
   ```

2. **Clone CVMFS and cvmfs-bits source trees**
   ```bash
   git clone https://github.com/cvmfs/cvmfs cvmfs
   cmake -S cvmfs -B cvmfs/build && make -C cvmfs/build -j$(nproc)

   git clone https://github.com/your-org/cvmfs-bits cvmfs-bits
   ```

3. **Copy binaries that are not built by cvmfs-bits**
   ```bash
   cp /path/to/cvmfs2     software/
   cp /path/to/cvmfs_talk software/
   chmod +x software/*
   ```

4. **Full setup** (builds cvmfs-bits, installs binaries, inits and starts the testbed)
   ```bash
   sudo make
   ```

5. **Run smoke tests**
   ```bash
   make test              # bits REST API path
   make test-ingest       # cvmfs_server ingest path
   ```

### With `testbed.sh` (step by step)

1. **Clone the repository and enter it**
   ```bash
   git clone https://github.com/your-org/cvmfs-testbed
   cd cvmfs-testbed
   chmod +x testbed.sh install.sh
   ```

2. **Clone and build CVMFS** (inside cvmfs-testbed)
   ```bash
   git clone https://github.com/cvmfs/cvmfs cvmfs
   cmake -S cvmfs -B cvmfs/build
   make -C cvmfs/build -j$(nproc)
   ```

3. **Populate software/ from the CVMFS build tree**
   ```bash
   ./install.sh
   ```
   This copies `cvmfs_publish`, `cvmfs_swissknife`, `libcvmfs_server.so.*`, and rebuilds the patched `cvmfs_server` script — all into `software/`.

4. **Copy the remaining service binaries**
   ```bash
   cp /path/to/cvmfs-prepub  software/
   cp /path/to/cvmfs_gateway software/
   cp /path/to/cvmfs2        software/
   cp /path/to/cvmfs_talk    software/
   chmod +x software/*
   ```

5. **Initialise** (requires sudo for `cvmfs_server mkfs`)
   ```bash
   sudo ./testbed.sh init
   ```
   Creates directory structure, generates secrets, writes service configs, and initialises the CVMFS repository.

6. **Start containers**
   ```bash
   # HTTP mode (default)
   ./testbed.sh start

   # MQTT control-plane mode
   ./testbed.sh start --mqtt
   ```

7. **Run smoke test**
   ```bash
   ./testbed.sh test
   ```

8. **Verify file visibility through the CVMFS client**
   ```bash
   ./testbed.sh verify <uuid_from_smoke_test> usr/share/test/hello.txt
   ```


## Running Tests

Both publishing paths use the same comprehensive test payload (built by `make-test-payload.sh`), which covers directory hierarchies, hard and symbolic links, a 20 MiB file to trigger chunking, unusual file names (spaces, unicode, special characters), permission modes, and empty directories.

### Smoke Tests

```bash
# bits REST API path (default)
make test
# or: ./testbed.sh test --method bits

# cvmfs_server ingest path
make test-ingest
# or: ./testbed.sh test --method ingest
```

### Stress Tests

```bash
# 10 jobs via bits REST API (default N=10)
make stresstest

# 50 jobs via ingest path
make stresstest-ingest N=50
# or: ./testbed.sh stresstest 50 --method ingest
```

### Catalog Structure Comparison

Run both paths and diff the resulting SQLite catalog dumps to inspect schema and content differences:

```bash
make test-ingest catdump-ingest test-bits catdump-bits catdiff
```

This writes SQL dumps to `$TESTBED_ROOT/data/catalog-dumps/ingest/` and `bits/`, then produces `ingest_vs_bits.diff`. Individual `testbed.sh` equivalents:

```bash
./testbed.sh test --method ingest
./testbed.sh catdump ingest          # dumps to data/catalog-dumps/ingest/
./testbed.sh test --method bits
./testbed.sh catdump bits            # dumps to data/catalog-dumps/bits/
./testbed.sh catdiff ingest bits     # writes ingest_vs_bits.diff
```

### Manual Job Submission
```bash
# Source the .env to get the API token
source .env

# Create a test tar
mkdir -p /tmp/test-pkg/usr/share/test
echo "hello cvmfs" > /tmp/test-pkg/usr/share/test/hello.txt
tar -czf /tmp/test.tar.gz -C /tmp/test-pkg .

# Submit the job
curl -X POST \
  -H "Authorization: Bearer ${PREPUB_API_TOKEN}" \
  -F "repo=test.cvmfs.io" \
  -F "path=test/manual" \
  -F "tar=@/tmp/test.tar.gz" \
  -F "tag_name=manual-$(date +%s)" \
  http://localhost:8080/api/v1/jobs | jq .
```

### Monitor Logs
```bash
# Watch cvmfs-prepub logs
docker compose logs -f cvmfs-prepub

# Watch gateway logs
docker compose logs -f gateway

# Watch all logs
docker compose logs -f
```

### Query API Directly
```bash
source .env

# Get job status
curl -s -H "Authorization: Bearer ${PREPUB_API_TOKEN}" \
  http://localhost:8080/api/v1/jobs/{job-id} | jq .

# Get metrics
curl -s -H "Authorization: Bearer ${PREPUB_API_TOKEN}" \
  http://localhost:8080/api/v1/metrics
```

## Verifying End-to-End Publish Latency

`verify-publish.sh` provides a live view of how long each pipeline stage takes and confirms that published files are visible through the CVMFS FUSE client.

```bash
# Exec into the already-running cvmfs-client container
docker compose exec cvmfs-client \
  verify-publish.sh <job_id> [relative/path/inside/repo]
```

**What it does:**

1. Fetches job metadata from `GET /api/v1/jobs/{id}` to establish t₀ (job creation time).
2. Subscribes to `GET /api/v1/jobs/{id}/events` (SSE) and records the wall-clock time each state transition arrives.
3. After "published", calls `cvmfs_talk -i ${REPO_NAME} remount sync` to force the client to pick up the new catalog.
4. If an `expected_file_path` was given, polls `/cvmfs/${REPO_NAME}/${path}` every 200 ms (retrying remount every 5 s) until the file appears or 60 s elapse.
5. Prints a timing table:

```
Stage                      | Elapsed (ms) | Delta (ms)
---------------------------+--------------+-----------
queued                     |            0 |          0
processing                 |          312 |        312
distributing               |          874 |        562
leased                     |          941 |         67
committing                 |         1005 |         64
published                  |         1278 |        273
client remount             |         1531 |        253
file visible               |         2089 |        558
```

**Exit codes:** 0 = published and file visible; 1 = job failed/aborted; 2 = timeout; 3 = published but file not visible within 60 s.

### CVMFS Client Container Notes

The `cvmfs-client` container requires `SYS_ADMIN` capability, `/dev/fuse` device access, and `apparmor:unconfined` security option — all set in `docker-compose.yml`. The `cvmfs2` and `cvmfs_talk` binaries are injected from `SOFTWARE_ROOT` so they can be swapped without rebuilding the image.

The client is configured with `CVMFS_HTTP_PROXY=DIRECT` pointing at Stratum 0, which is correct for the single-site testbed. In a multi-tier deployment you would instead point it at a Stratum 1 or Squid proxy.

---

## MQTT Control-Plane Mode

By default the testbed uses direct HTTP announces between cvmfs-prepub and the Stratum 1 receivers (Option B HTTP). To test the MQTT variant instead, activate the overlay compose file:

```bash
docker compose -f docker-compose.yml -f docker-compose.mqtt.yml up -d
```

This adds a `mosquitto` container (eclipse-mosquitto:2) and passes `--broker-url tcp://mosquitto:1883` to cvmfs-prepub and both Stratum 1 receivers. The data plane (CAS object PUTs on TCP 9101) is unchanged; only the announce/ready exchange moves onto MQTT.

**Switch back to HTTP mode:**
```bash
docker compose down
docker compose up -d   # no overlay file
```

**Mosquitto logs:**
```bash
docker compose logs -f mosquitto
# or inspect the log file directly:
cat ${TESTBED_ROOT}/data/mosquitto-log/mosquitto.log
```

**Verify MQTT topics with mosquitto_sub:**
```bash
docker compose exec mosquitto \
  mosquitto_sub -h localhost -t 'cvmfs/prepub/#' -v
```

For a full description of the MQTT topic schema, flow diagrams, and security controls see REFERENCE.md §20.11.

---

## Full Stack with bits-console and Gitea

The `docker-compose.bits.yml` overlay adds two services to the core stack:

- **gitea** — a lightweight Gitea git server (gitea/gitea:1.21, ~300 MB RAM). Serves the bits-console SPA via Gitea Pages at `http://testbed.localhost:3000/bits-project/testbed/` and provides the REST API and Actions CI at `http://localhost:3000/api/v1/`.
- **seeder** — a one-shot Python container that runs after Gitea becomes healthy. It creates the `testbed` organisation and `bits-project` repository, pushes bits-console source and the testbed community config to the `main` branch, builds the Pages static tree, pushes it to the `gh-pages` branch, sets CI variables and secrets, and prints the act_runner registration token.

### Quick start (bits overlay)

1. **Clone (or symlink) bits-console inside cvmfs-testbed**
   ```bash
   git clone https://github.com/your-org/bits-console bits-console
   # or: ln -s /path/to/your/bits-console bits-console
   ```
   No `.env` change needed — the path is fixed by convention.

2. **Start all services** (core + Gitea + seeder)
   ```bash
   docker compose \
     -f docker-compose.yml \
     -f docker-compose.bits.yml \
     up -d
   ```

3. **Watch the seeder output** — it will print the act_runner registration token when done:
   ```bash
   docker compose logs -f seeder
   ```

4. **Register and start act_runner on the host**
   ```bash
   # Use the config generated by init.sh — it has PREPUB_URL and
   # PREPUB_API_TOKEN already filled in from .env, so the runner can
   # reach cvmfs-prepub without any project-level CI/CD variables.
   sudo mkdir -p /var/lib/act_runner /etc/act_runner
   sudo cp ~/cvmfs-testbed/config/act_runner/config.yaml /etc/act_runner/config.yaml

   # Register (use the token printed by the seeder)
   act_runner register \
     --instance http://localhost:3000 \
     --token <TOKEN_FROM_SEEDER> \
     --name bits-host-runner \
     --labels self-hosted,bits,ubuntu-latest \
     --no-interactive

   # Install as a systemd service
   sudo cp act_runner/act_runner.service /etc/systemd/system/
   # Edit the User= line if your username differs from cvmfs-testbed
   sudo systemctl daemon-reload
   sudo systemctl enable --now act_runner
   sudo systemctl status act_runner
   ```

5. **Open bits-console in a browser**
   ```
   http://testbed.localhost:3000/bits-project/testbed/
   ```
   Log in with the Gitea admin credentials (see `.env`).

6. **Submit a build job** from the bits-console UI. The workflow dispatches to Gitea Actions, act_runner picks it up, runs `bits build` and `bits publish` on the host, and cvmfs-prepub handles the rest.

### CORS and browser notes

bits-console is served from `testbed.localhost:3000` (a Gitea Pages subdomain) and calls the Gitea API at `localhost:3000` — two different browser origins. Gitea is configured with `CORS_ALLOW_DOMAIN = http://testbed.localhost:3000` to allow this.

All modern browsers (Chrome, Firefox, Edge) resolve `*.localhost` to `127.0.0.1` automatically per RFC 6761 — no `/etc/hosts` changes needed. **Safari** is the exception: add this line to `/etc/hosts`:
```
127.0.0.1 testbed.localhost
```

### bits-console community config (testbed)

The seeder injects a testbed community config at `communities/testbed/ui-config.yaml` in the repository. Key fields used by bits-console:

```yaml
api_type: gitea              # routes to Gitea API instead of GitLab
gitlab_url: http://localhost:3000
project_id: testbed/bits-project   # org/repo string (not an integer)
workflow_file: bits-publish.yaml
cvmfs_repo: test.cvmfs.io
```

### Re-seeding (after a `docker compose down -v`)

The seeder is idempotent: running it again after resetting Gitea is safe. It will recreate all resources. To force a re-seed without restarting all services:
```bash
docker compose -f docker-compose.yml -f docker-compose.bits.yml \
  up seeder --force-recreate
```

---

## Monitoring

### VictoriaMetrics
- **URL**: http://localhost:8428 (internal only)
- **Data Retention**: 1 month by default
- **Query Language**: PromQL (Prometheus-compatible)

### vmagent
- Scrapes metrics from cvmfs-prepub (port 8080), gateway (4929), and both Stratum 1 receivers (9100)
- Pushes metrics to VictoriaMetrics every 15 seconds
- Config: `monitoring/scrape.yml`

## Re-initialising

The easiest way is via `testbed.sh reset`:

```bash
# Core stack
sudo ./testbed.sh reset

# With bits overlay (bits-console/ must already be present)
sudo ./testbed.sh reset --bits
```

`reset` runs `clean` (stops containers, removes all host state) then `init` then `start`.

**Manual steps if you prefer:**
```bash
docker compose down -v
source .env
sudo rm -rf ${TESTBED_ROOT}/data ${TESTBED_ROOT}/cvmfs ${TESTBED_ROOT}/config
rm -f "$HOME/cvmfs-testbed/.env"

./install.sh             # re-populate software/ from cvmfs/build/
sudo ./testbed.sh init   # or: sudo ./init.sh
./testbed.sh start
```

## Troubleshooting

### Container fails to start
Check logs:
```bash
docker compose logs <service-name>
```

Common issues:
- **cvmfs-prepub can't connect to gateway**: gateway may not be running. Check: `docker compose exec cvmfs-prepub curl -v http://gateway:4929`
- **Binaries not found**: Ensure SOFTWARE_ROOT paths are correct in .env and binaries are copied and executable.
- **Permission denied on /data**: Containers run as user `prepub`. Ensure the host directories are writable by your user.

### Jobs timeout in published state
If jobs hang in "pending" state:
- Check gateway logs: `docker compose logs gateway`
- Verify the HMAC secret is correct: `docker compose exec cvmfs-prepub env | grep HMAC`
- Check Stratum 1 connectivity: `docker compose exec cvmfs-prepub curl -v http://stratum1-a:9100/metrics`

### Metrics not appearing in console
- Check vmagent: `docker compose logs vmagent` for scrape errors
- Verify scrape config: `docker compose exec vmagent cat /etc/vmagent/scrape.yml`
- Test VictoriaMetrics: `curl -s http://localhost:8428/api/v1/query?query=up | jq .`

### Stratum 1 receivers not receiving objects
- Check node IDs: `docker compose logs stratum1-a | grep node_id`
- Verify control channel: `docker compose exec cvmfs-prepub curl -v http://stratum1-a:9100/api/v1/info`
- Check data upload: `docker compose logs stratum1-a | grep "PUT"`

### CVMFS client container fails to mount
- Ensure `/dev/fuse` exists on the host: `ls -la /dev/fuse`
- Ensure the FUSE kernel module is loaded: `lsmod | grep fuse` (if absent: `sudo modprobe fuse`)
- Check AppArmor status: `aa-status | grep cvmfs` — the container must run unconfined
- Inspect entrypoint output: `docker compose logs cvmfs-client`
- Verify the public key was copied: `docker compose exec cvmfs-client ls /etc/cvmfs/keys/`

### verify-publish.sh reports "file not visible after 60 s"
- Confirm the job actually reached "published": `docker compose logs cvmfs-prepub | tail -40`
- Force a manual remount: `docker compose exec cvmfs-client cvmfs_talk -i ${REPO_NAME} remount sync`
- Check that Stratum 0 is serving the new manifest:
  ```bash
  docker compose exec cvmfs-client curl -sI http://stratum0/cvmfs/${REPO_NAME}/.cvmfspublished
  ```
- Check the client cache is not stale: `docker compose exec cvmfs-client cvmfs_talk -i ${REPO_NAME} cache list`

### Gitea: seeder exits with an error
- Check seeder logs: `docker compose logs seeder`
- Verify `BITS_CONSOLE_SRC` is set and points to a valid bits-console source tree
- Ensure `build-communities.sh` is present and executable in the bits-console root
- If Gitea itself failed to start: `docker compose logs gitea`
- Re-run the seeder: `docker compose -f docker-compose.yml -f docker-compose.bits.yml up seeder --force-recreate`

### bits-console SPA not loading
- Confirm the seeder completed successfully (exited 0)
- Check the `gh-pages` branch was pushed: browse to `http://localhost:3000/testbed/bits-project/src/branch/gh-pages`
- Gitea Pages uses the subdomain format `{org}.{PAGES_DOMAIN}:{port}/{repo}/`; the `testbed` org → `testbed.localhost:3000/bits-project/testbed/`
- Safari: add `127.0.0.1 testbed.localhost` to `/etc/hosts`

### act_runner: jobs are not picked up
- Check runner status: `systemctl status act_runner`
- Verify registration: `act_runner list` (should show the runner as online in Gitea)
- Ensure the runner labels match `runs-on: [self-hosted, bits]` in the workflow
- Check runner logs: `journalctl -u act_runner -f`
- Confirm the runner user is in the `docker` group: `groups $USER`

### act_runner: bits build step fails
- Ensure the `bits` binary is in the runner's PATH (see `act_runner/act_runner.service` `Environment=PATH=...`)
- Check that `PREPUB_API_TOKEN` is set as a repository secret in Gitea
- View the full step log in the Gitea Actions UI at `http://localhost:3000/testbed/bits-project/actions`

### MQTT mode: publishers or receivers not connecting
- Check Mosquitto is up: `docker compose logs mosquitto`
- Verify broker is reachable: `docker compose exec cvmfs-prepub curl -v telnet://mosquitto:1883` (should connect)
- Confirm `--broker-url` flag appears in the command: `docker compose exec cvmfs-prepub ps aux`
- Subscribe to all CVMFS topics to watch live traffic:
  ```bash
  docker compose exec mosquitto mosquitto_sub -h localhost -t 'cvmfs/prepub/#' -v
  ```

## Notes

### Development Mode
`dev: true` is enabled in all service configs. This means:
- **TLS is disabled**: Certificates are not verified or required
- **Private IPs allowed**: Services can announce Stratum 1 endpoints on internal docker networks
- **HMAC verification is relaxed**: Useful for testing but never use in production

**Never use these configurations in production.**

### Shared State
The gateway and cvmfs-prepub both have write access to `${TESTBED_ROOT}/cvmfs/${REPO_NAME}`. Do not write to this directory from the host while containers are running, as you may corrupt the repository.

### Binary Hotswapping
To test different binary versions without rebuilding images:
1. Stop the relevant container: `docker compose stop cvmfs-prepub`
2. Replace the binary: `cp /path/to/new/cvmfs-prepub ${TESTBED_ROOT}/software/`
3. Restart: `docker compose start cvmfs-prepub`

### Quorum and Failure Tolerance
The testbed is configured with:
- Two Stratum 1 receivers (stratum1-a and stratum1-b)
- Quorum: 0.5 (at least one receiver must acknowledge)
- commit_anyway: true (proceed even if distribution fails)

This means a job succeeds if at least one receiver receives the objects, and catalog commits to the gateway regardless.

### Scaling
To test with more receivers, add more services to `docker-compose.yml` following the `stratum1-a` and `stratum1-b` pattern. Update the `stratum1_endpoints` list in the cvmfs-prepub config, and adjust the quorum threshold as needed.
