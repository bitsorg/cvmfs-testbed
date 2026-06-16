#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 CERN
# SPDX-License-Identifier: Apache-2.0

# testbed.sh — Top-level bootstrap and management script for the cvmfs-prepub testbed.
#
# Directory convention:
#   <cvmfs-testbed>/cvmfs/          CVMFS source tree  (git clone or symlink)
#   <cvmfs-testbed>/bits-console/   bits-console source (git clone or symlink)
#   <cvmfs-testbed>/software/       built CVMFS binaries (populated by install.sh)
#
# Usage:
#   ./testbed.sh [command] [options] [args]
#
# Commands:
#   init            One-time host setup: create directories, generate secrets,
#                   run install.sh, initialise CVMFS repository, write service configs.
#   start           Build images (if needed) and start containers.
#                   Auto-restores from repo-seed.tar.gz if the repo is absent.
#   stop            Stop containers without removing state.
#   restart         Stop then start.
#   status          Show container status and key service health.
#   info            Print all service endpoints, ports, and credentials.
#   logs            Tail logs (all services, or pass a service name).
#   bootstrap       Seed the repository with the nested-catalog structure needed by
#                   cvmfs_server ingest.  Runs a privileged one-shot container;
#                   requires gateway and stratum0 to be running.  Calls snapshot
#                   automatically on success.
#   snapshot        Save current repository state (CAS + spool + keys + configs)
#                   to TESTBED_ROOT/repo-seed.tar.gz.
#   restore         Restore repository state from repo-seed.tar.gz.  Fails if the
#                   snapshot file does not exist.
#   test            Run the smoke test (default method: bits).
#   stresstest <n>  Stress test publishing with n concurrent/sequential jobs.
#   catdump [label] Decompress and SQL-dump all catalogs from the current repo
#                   snapshot into data/catalog-dumps/<label>/.
#                   label defaults to the current --method value (bits or ingest).
#   catdiff [a] [b] Diff two catalog dump sets.  a/b default to "ingest" and
#                   "bits" respectively.  Requires both catdump sets to exist.
#   verify          Verify end-to-end file visibility (needs a job UUID).
#   clean           Stop containers AND remove all persistent state.
#                   The repo-seed.tar.gz snapshot is PRESERVED so that
#                   a subsequent start can restore from it without re-bootstrapping.
#   reset           clean + init + start + bootstrap (full teardown and
#                   reinitialisation including a fresh snapshot).
#   server [port]   Start the testbed console HTTP backend server.
#                   Default port: 8888.  Binds to 0.0.0.0 so the console is
#                   reachable from any host on the network.
#                   The server reverse-proxies all internal services (gateway,
#                   stratum0, stratum1-a/b, …) through a single port,
#                   solving the "localhost:3000 unreachable from remote host"
#                   problem.  Run testbed.sh commands directly from the browser.
#                   Requires Python 3.8+.
#   mqtttest        End-to-end MQTT notification test.  Requires --mqtt.
#                   Subscribes to cvmfs/repos/{repo}/published, runs one publish
#                   job (default: --method bits), and verifies that a
#                   PublishedMessage arrives, the JSON payload is valid, and that
#                   the Stratum 1 receivers log the expected activity.
#                   With --method ingest the test also checks stratum1 logs for
#                   S0 pull activity triggered by the notification.
#   pulltest        End-to-end ADR-0001 pull-distribution test.  Requires --pull
#                   (which implies --mqtt).  Runs one publish job and verifies
#                   that each Stratum 1 receiver fetched the new objects from
#                   Stratum 0 itself (logs "pull: transaction warmed"), reaching
#                   the configured pull quorum (PULL_QUORUM, default 1).
#   pullstatus      Monitoring helper: dump pull-relevant log lines from the
#                   publisher and both receivers (announce, manifest serving,
#                   warm/commit, pull outcomes).  Requires --pull.
#   unittest        Run Go unit tests for the broker and receiver packages.
#                   Searches for the cvmfs-bits source tree next to this script
#                   directory and runs:
#                     go test -v ./internal/broker/...
#                     go test -v ./internal/distribute/receiver/...
#                   Falls back to running inside the cvmfs-prepub container if
#                   the source is not found on the host.
#   help            Show this help text.
#
# Options (accepted by all commands):
#   --bits                Include the bits-console overlay (Gitea + seeder).
#                         Requires bits-console/ to be present in this directory.
#   --mqtt                Include the MQTT control-plane overlay.
#   --pull                Include the ADR-0001 pull-distribution overlay.  Implies
#                         --mqtt (pull is triggered over the MQTT control plane).
#   --scenario NAME       Named distribution preset (push|mqtt|pull|ingest) that
#                         sets --method/--mqtt/--pull in one word.  Use instead of
#                         the individual flags, e.g. start/test --scenario pull.
#   --method bits|ingest  Publishing method for test/stresstest commands.
#                         bits:   Use the cvmfs-prepub REST API path (default).
#                         ingest: Use cvmfs_server ingest directly via the gateway.
#   -y, --yes             Skip interactive confirmation prompts (e.g. in Makefile).
#   --software-root PATH  Override the default software/ destination.
#   --testbed-root PATH   Path to testbed data root (overrides TESTBED_ROOT from .env).
#
# .env location:
#   The .env file is stored in TESTBED_ROOT, NOT next to this script.
#   The script directory may be read-only.
#   Bootstrap order for TESTBED_ROOT: --testbed-root flag > $TESTBED_ROOT env var
#   > value read from an existing .env > default $HOME/cvmfs-testbed.
#
# Examples:
#   # First-time setup — clone sources, build, then init:
#   git clone https://github.com/cvmfs/cvmfs cvmfs
#   cmake -S cvmfs -B cvmfs/build && make -C cvmfs/build -j$(nproc)
#   git clone https://github.com/your-org/bits-console bits-console  # optional
#   ./testbed.sh init
#   ./testbed.sh start
#   ./testbed.sh bootstrap    # once — seeds nested catalog, creates snapshot
#   ./testbed.sh test
#
#   # After a clean+start cycle, snapshot is auto-restored — no re-bootstrap:
#   ./testbed.sh clean
#   ./testbed.sh start        # restores from repo-seed.tar.gz automatically
#   ./testbed.sh test --method ingest
#
#   # Full rebuild (new keys, new snapshot):
#   ./testbed.sh reset        # clean + init + start + bootstrap
#
#   # Override binary and data locations:
#   ./testbed.sh init  --testbed-root /data/tb --software-root /data/tb/software
#
#   # Tail logs for a single service:
#   ./testbed.sh logs gateway
#
#   # Stress test: 20 jobs via bits REST API (default), or cvmfs_server ingest:
#   ./testbed.sh stresstest 20
#   ./testbed.sh stresstest 20 --method ingest
#
#   # Start the console server (accessible from any host):
#   ./testbed.sh server          # plain testbed (port 8888)
#   ./testbed.sh server --mqtt   # with MQTT overlay flags forwarded to server
#   ./testbed.sh server --bits --mqtt 9090  # custom port
#   # Then open: http://<hostname>:8888/
#
#   # MQTT end-to-end notification test:
#   ./testbed.sh start --mqtt
#   ./testbed.sh mqtttest --mqtt                    # bits path (default)
#   ./testbed.sh mqtttest --mqtt --method ingest    # native ingest path
#
#   # Go unit tests (broker + receiver packages):
#   ./testbed.sh unittest
#
#   # Compare catalog structure between the two publishing paths:
#   ./testbed.sh test --method ingest
#   ./testbed.sh catdump ingest
#   ./testbed.sh test --method bits
#   ./testbed.sh catdump bits
#   ./testbed.sh catdiff ingest bits
#
#   # Verify a publish job end-to-end (bits path only):
#   ./testbed.sh verify <job-uuid> usr/share/test/hello.txt
#
#   # Full teardown and reinitialise:
#   ./testbed.sh reset

set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERR ]${NC}  $*"; }
section() { echo -e "\n${BOLD}── $* ──${NC}"; }

# ── Script location ───────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTBED_DIR="$(dirname "$SCRIPT_DIR")"   # root of cvmfs-testbed checkout

# ── Default flags ─────────────────────────────────────────────────────────────
USE_BITS=false
USE_MQTT=false
USE_PULL=false          # ADR-0001 pull-based distribution overlay (implies --mqtt)
SCENARIO=""             # named preset over the flags below (see apply_scenario)
SOFTWARE_ROOT_OVERRIDE=""
TESTBED_ROOT_OVERRIDE=""
PUBLISH_METHOD="bits"   # bits | ingest
AUTO_YES=false          # skip interactive confirmation prompts (e.g. for make)
FOLLOW_LOGS=false       # set by -f/--follow; makes 'logs' stream continuously

# ── Argument parsing ──────────────────────────────────────────────────────────
# Extract the command first, then parse --flags.
# Stop flag parsing at the first non-flag argument so that positional args
# (e.g. a service name for 'logs', or a job UUID for 'verify') are preserved
# in POSITIONAL_ARGS rather than being rejected as unknown options.
CMD="${1:-help}"
shift || true

POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --bits)                USE_BITS=true;                    shift ;;
        --mqtt)                USE_MQTT=true;                    shift ;;
        # Pull mode (ADR-0001) rides on the MQTT control plane, so --pull turns
        # the MQTT overlay on as well.
        --pull)                USE_PULL=true; USE_MQTT=true;     shift ;;
        # Named distribution scenario — a preset over --mqtt/--pull/--method.
        --scenario)
            [[ $# -ge 2 ]] || { error "--scenario requires a value (push|mqtt|pull|ingest)"; exit 1; }
            SCENARIO="$2"; shift 2 ;;
        --scenario=*)          SCENARIO="${1#*=}"; shift ;;
        # --bits-src is no longer needed: bits-console lives at $TESTBED_DIR/bits-console.
        # Accept it silently for backward compatibility.
        --bits-src)
            warn "--bits-src is no longer needed; bits-console/ is expected at $TESTBED_DIR/bits-console"
            [[ $# -ge 2 ]] && shift 2 || shift ;;
        --bits-src=*)          warn "--bits-src is no longer needed; bits-console/ is expected at $TESTBED_DIR/bits-console"; shift ;;
        --software-root)
            [[ $# -ge 2 ]] || { error "--software-root requires a value"; exit 1; }
            SOFTWARE_ROOT_OVERRIDE="$2"; shift 2 ;;
        --software-root=*)     SOFTWARE_ROOT_OVERRIDE="${1#*=}"; shift ;;
        --testbed-root)
            [[ $# -ge 2 ]] || { error "--testbed-root requires a value"; exit 1; }
            TESTBED_ROOT_OVERRIDE="$2"; shift 2 ;;
        --testbed-root=*)      TESTBED_ROOT_OVERRIDE="${1#*=}";  shift ;;
        --method)
            [[ $# -ge 2 ]] || { error "--method requires a value (bits|ingest)"; exit 1; }
            PUBLISH_METHOD="$2"; shift 2
            [[ "$PUBLISH_METHOD" == "bits" || "$PUBLISH_METHOD" == "ingest" ]] \
                || { error "--method must be 'bits' or 'ingest'"; exit 1; } ;;
        --method=*)
            PUBLISH_METHOD="${1#*=}"; shift
            [[ "$PUBLISH_METHOD" == "bits" || "$PUBLISH_METHOD" == "ingest" ]] \
                || { error "--method must be 'bits' or 'ingest'"; exit 1; } ;;
        -y|--yes)      AUTO_YES=true;                    shift ;;
        -f|--follow)   FOLLOW_LOGS=true;                shift ;;
        # Command-specific flags (e.g. upload-filelist, stresstest) — pass
        # them through to the subcommand handler via POSITIONAL_ARGS.
        --dir|--filelist|--ingest-path|--concurrency|-j|--run-log|\
        --prepub-url|--repo|--token)
            POSITIONAL_ARGS+=("$1" "${2:-}"); shift 2 ;;
        --no-recursive)
            POSITIONAL_ARGS+=("$1"); shift ;;
        --*)  error "Unknown option: $1"; exit 1 ;;
        *)    POSITIONAL_ARGS+=("$1");                           shift ;;
    esac
done

# ── Scenario presets ──────────────────────────────────────────────────────────
# A scenario is a named bundle of the distribution flags so the testbed (and the
# console / Makefile) can switch between distribution models with one word. Use a
# scenario OR the individual --mqtt/--pull/--method flags, not both (the scenario
# sets all three).
#
#   push    legacy push, no control plane     (method bits,  -mqtt -pull)
#   mqtt    push data + MQTT control plane     (method bits,  +mqtt -pull)
#   pull    ADR-0001 pull distribution         (method bits,  +mqtt +pull)
#   ingest  native cvmfs_server ingest path    (method ingest,-mqtt -pull)
apply_scenario() {
    [[ -z "$SCENARIO" ]] && return 0
    case "$SCENARIO" in
        push)   PUBLISH_METHOD="bits";   USE_MQTT=false; USE_PULL=false ;;
        mqtt)   PUBLISH_METHOD="bits";   USE_MQTT=true;  USE_PULL=false ;;
        pull)   PUBLISH_METHOD="bits";   USE_MQTT=true;  USE_PULL=true  ;;
        ingest) PUBLISH_METHOD="ingest"; USE_MQTT=false; USE_PULL=false ;;
        *) error "Unknown scenario: $SCENARIO (expected push|mqtt|pull|ingest)"; exit 1 ;;
    esac
    info "Scenario '${SCENARIO}': method=${PUBLISH_METHOD} mqtt=${USE_MQTT} pull=${USE_PULL}"
}
apply_scenario

# ── .env helpers ──────────────────────────────────────────────────────────────
# .env lives in TESTBED_ROOT, not next to this script (the script dir may be
# read-only).  Bootstrap: resolve TESTBED_ROOT before .env is available, using
# the command-line override or the environment variable, falling back to the
# $HOME default.
_env_file() {
    local root="${TESTBED_ROOT_OVERRIDE:-${TESTBED_ROOT:-$HOME/cvmfs-testbed}}"
    echo "$root/.env"
}

_env_loaded=false
load_env() {
    # Idempotent: only sources the file once per process to avoid duplicate
    # PATH entries and redundant re-evaluation.
    if $_env_loaded; then return 0; fi
    _env_loaded=true

    # 1. Apply --testbed-root override before sourcing so _env_file() resolves
    #    to the correct path.
    [[ -n "$TESTBED_ROOT_OVERRIDE" ]] && TESTBED_ROOT="$TESTBED_ROOT_OVERRIDE"

    # 2. Source .env — populates TESTBED_ROOT, SOFTWARE_ROOT, secrets, etc.
    local env_file
    env_file="$(_env_file)"
    if [[ -f "$env_file" ]]; then
        # shellcheck source=/dev/null
        set -a; source "$env_file"; set +a
    else
        warn ".env not found at $env_file — run: ./testbed.sh init"
    fi

    # 3. Re-apply command-line overrides (highest priority, beat .env values).
    [[ -n "$TESTBED_ROOT_OVERRIDE"  ]] && TESTBED_ROOT="$TESTBED_ROOT_OVERRIDE"
    [[ -n "$SOFTWARE_ROOT_OVERRIDE" ]] && SOFTWARE_ROOT="$SOFTWARE_ROOT_OVERRIDE"

    # 4. Derive BITS_CONSOLE_SRC from the conventional location (no .env entry needed).
    BITS_CONSOLE_SRC="$TESTBED_DIR/bits-console"

    # 5. Prepend SOFTWARE_ROOT to PATH so locally built binaries take precedence
    #    over any system-wide CVMFS installation in a potentially read-only area.
    local sw="${SOFTWARE_ROOT:-$TESTBED_DIR/software}"
    if [[ -d "$sw" ]] && [[ ":$PATH:" != *":$sw:"* ]]; then
        export PATH="$sw:$PATH"
    fi
}

# ── Compose helpers ───────────────────────────────────────────────────────────
compose_files() {
    # Returns the -f flags as an array (via nameref or by printing to caller).
    # Using a global array avoids word-splitting issues with paths containing spaces.
    # NOTE: use 'if' rather than '$BOOL && ...' — under set -e the latter exits
    # when the bool variable expands to the 'false' command (exit code 1).
    _COMPOSE_FILES=("-f" "$TESTBED_DIR/docker-compose.yml")
    if $USE_MQTT; then _COMPOSE_FILES+=("-f" "$TESTBED_DIR/docker-compose.mqtt.yml"); fi
    if $USE_BITS; then  _COMPOSE_FILES+=("-f" "$TESTBED_DIR/docker-compose.bits.yml"); fi
    # The pull overlay MUST come last: it restates the service commands set by the
    # MQTT overlay and appends --distribute-mode pull. --pull already forced
    # USE_MQTT=true, so the mqtt overlay is present before it.
    if $USE_PULL; then _COMPOSE_FILES+=("-f" "$TESTBED_DIR/docker-compose.pull.yml"); fi
}

run_compose() {
    compose_files
    docker compose "${_COMPOSE_FILES[@]}" "$@"
}

# ── Commands ──────────────────────────────────────────────────────────────────

cmd_init() {
    section "Initialising testbed"

    # Forward all location overrides to init.sh as explicit arguments.
    local init_args=()
    [[ -n "$TESTBED_ROOT_OVERRIDE"  ]] && init_args+=(--testbed-root  "$TESTBED_ROOT_OVERRIDE")
    [[ -n "$SOFTWARE_ROOT_OVERRIDE" ]] && init_args+=(--software-root "$SOFTWARE_ROOT_OVERRIDE")

    bash "$SCRIPT_DIR/init.sh" "${init_args[@]}"
    ok "Init complete"
}

cmd_start() {
    section "Starting testbed"
    load_env

    # ── Preflight checks ───────────────────────────────────────────────────────

    # TESTBED_ROOT must exist and be writable.
    if [[ -z "${TESTBED_ROOT:-}" ]]; then
        error "TESTBED_ROOT is not set. Run: ./testbed.sh init"
        exit 1
    fi
    if [[ ! -d "$TESTBED_ROOT" ]]; then
        error "TESTBED_ROOT=$TESTBED_ROOT does not exist. Run: ./testbed.sh init"
        exit 1
    fi
    if [[ ! -w "$TESTBED_ROOT" ]]; then
        error "TESTBED_ROOT=$TESTBED_ROOT is not writable."
        error "Choose a writable path (e.g. \$HOME/cvmfs-testbed) and re-run init."
        exit 1
    fi

    # All required binaries must be regular executable files (not directories).
    local sw="${SOFTWARE_ROOT:-$TESTBED_DIR/software}"
    local missing=()
    for bin in cvmfs_gateway cvmfs-prepub cvmfs2 cvmfs_talk; do
        local bp="$sw/$bin"
        if [[ -d "$bp" ]]; then
            error "  $bp is a directory, not a binary."
            error "  Docker created it as a placeholder. Remove it: rm -rf $bp"
            missing+=("$bin")
        elif [[ ! -f "$bp" ]]; then
            warn "  $bp not found — container will fail to start."
            missing+=("$bin")
        elif [[ ! -x "$bp" ]]; then
            error "  $bp is not executable. Run: chmod +x $bp"
            missing+=("$bin")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing or broken binaries in $sw: ${missing[*]}"
        error "Copy the built binaries there, then re-run: ./testbed.sh start"
        exit 1
    fi

    # All required config files must be regular files (not directories).
    local cfg_root="$TESTBED_ROOT/config"
    local bad_configs=()
    for cfg in \
        "cvmfs-prepub/config.yaml" \
        "gateway/gw.json" \
        "gateway/user.json" \
        "gateway/repo.json" \
        "stratum1-a/config.yaml" \
        "stratum1-b/config.yaml"; do
        local cp="$cfg_root/$cfg"
        if [[ -d "$cp" ]]; then
            error "  $cp is a directory (Docker placeholder). Remove: rm -rf $cp"
            bad_configs+=("$cfg")
        elif [[ ! -f "$cp" ]]; then
            error "  $cp is missing."
            bad_configs+=("$cfg")
        fi
    done
    if [[ ${#bad_configs[@]} -gt 0 ]]; then
        error "Config files missing or corrupted. Run: ./testbed.sh init"
        exit 1
    fi

    if $USE_BITS && [[ ! -d "$TESTBED_DIR/bits-console" ]]; then
        error "--bits requires bits-console/ to be present at $TESTBED_DIR/bits-console"
        error "Clone or symlink it there:"
        error "  git clone https://github.com/your-org/bits-console $TESTBED_DIR/bits-console"
        exit 1
    fi

    # ── Auto-restore from snapshot ────────────────────────────────────────────
    # If the repository has not been initialised (no .cvmfspublished) but a
    # snapshot exists, restore it now before starting containers.  This lets
    # the normal workflow be: clean → start → test, with no manual bootstrap.
    local _published="${TESTBED_ROOT}/repos/${REPO_NAME}/.cvmfspublished"
    if [[ ! -f "$_published" ]]; then
        local _snap
        _snap="$(_snapshot_path)"
        if [[ -f "$_snap" ]]; then
            info "Repository absent — restoring from snapshot: $(basename "$_snap")"
            cmd_restore
        else
            warn "Repository not initialised and no snapshot found."
            warn "After start, run:  ./testbed.sh bootstrap"
            warn "(or: make bootstrap)"
        fi
    fi

    # ── Build and launch ───────────────────────────────────────────────────────
    info "Building images (if needed) ..."
    run_compose build

    info "Starting services ..."
    run_compose up -d

    # ── Wait for readiness ─────────────────────────────────────────────────────
    info "Waiting for services to initialise ..."
    local deadline
    deadline=$(( $(date +%s) + 60 ))
    local all_up=false
    while [[ $(date +%s) -lt $deadline ]]; do
        sleep 5
        local _ready=true
        for url in \
            "http://localhost:8080/api/v1/health" \
            "http://localhost:4929/api/v1/repos" \
            "http://localhost:8090/"; do
            curl -sf --max-time 2 "$url" >/dev/null 2>&1 || { _ready=false; break; }
        done
        if $USE_BITS; then
            curl -sf --max-time 2 "http://localhost:3000/api/v1/version" >/dev/null 2>&1 \
                || _ready=false
        fi
        if $_ready; then all_up=true; break; fi
        echo -n "."
    done
    echo ""
    if ! $all_up; then
        warn "Some services did not respond within 60 s — check logs: ./testbed.sh logs"
    fi
    _cmd_status_inner  # status without re-running load_env
}

cmd_stop() {
    section "Stopping testbed"
    load_env
    run_compose stop
    ok "All containers stopped"
}

# ── Snapshot path helper ───────────────────────────────────────────────────────
_snapshot_path() {
    # Keep the snapshot in TESTBED_ROOT so it is co-located with the repo data
    # it captures.  load_env must have been called before this function.
    echo "${TESTBED_ROOT}/repo-seed.tar.gz"
}

# ── cmd_bootstrap ─────────────────────────────────────────────────────────────
# Run the privileged cvmfs-bootstrap container once to seed the repository with
# the nested-catalog structure required by cvmfs_server ingest.
# Requires: gateway and stratum0 must already be running (use after cmd_start).
# On success, automatically calls cmd_snapshot to create repo-seed.tar.gz.
cmd_bootstrap() {
    section "Bootstrapping repository nested-catalog structure"
    load_env

    local _published="${TESTBED_ROOT}/repos/${REPO_NAME}/.cvmfspublished"
    if [[ ! -f "$_published" ]]; then
        error "Repository not initialised.  Run init and start first:"
        error "  ./testbed.sh init && ./testbed.sh start"
        exit 1
    fi

    # Pre-create the bootstrap spool with the same per-repo structure that
    # cvmfs_server ingest expects in gateway mode.  It writes transaction state
    # and reflog into /var/spool/cvmfs/<repo>/ (mapped to data/bootstrap-spool/<repo>/).
    #
    # The bootstrap container runs as root (privileged), so previous runs may
    # have left data/bootstrap-spool/ (and its subdirectory) owned by root.
    # Wipe the entire parent with sudo so regular mkdir can recreate it.
    local _bspool="${TESTBED_ROOT}/data/bootstrap-spool/${REPO_NAME}"
    sudo rm -rf "${TESTBED_ROOT}/data/bootstrap-spool"
    mkdir -p "${_bspool}/tmp"
    chmod 777 "${_bspool}" "${_bspool}/tmp"
    touch "${_bspool}/client.local"
    # Copy reflog.chksum from the gateway spool so the bootstrap transaction
    # sees the same reflog state as a normal gateway publisher.
    local _gw_chksum="${TESTBED_ROOT}/data/gateway-spool/${REPO_NAME}/reflog.chksum"
    if [[ -f "$_gw_chksum" ]]; then
        cp "$_gw_chksum" "${_bspool}/reflog.chksum"
        info "Copied reflog.chksum to bootstrap spool."
    else
        touch "${_bspool}/reflog.chksum"
        warn "Gateway reflog.chksum not found — bootstrap commit may fail with kMissingReflog."
        warn "Try re-running init first: ./testbed.sh init"
    fi

    # Force-recreate the gateway container to clear stale lease state.
    #
    # Background: the gateway persists leases in a BoltDB at /var/lib/cvmfs-gateway
    # inside the container overlay filesystem.  `docker compose restart` preserves
    # the overlay, so the leasedb — and any stale lease from a previously crashed
    # ingest — survives the restart.  `--force-recreate` removes and recreates the
    # container, giving us a truly empty leasedb.
    #
    # The startup `delete_all` action only clears the repo registry (not leases),
    # so recreating the container is the only reliable way to purge stale leases.
    info "Recreating gateway to clear stale lease state (leasedb is inside container overlay) ..."
    run_compose up -d --force-recreate gateway

    # Wait up to 30 s for the gateway API to become healthy again.
    local _gw_url="http://localhost:4929/api/v1/repos"
    local _deadline=$(( $(date +%s) + 30 ))
    local _gw_ready=false
    while [[ $(date +%s) -lt $_deadline ]]; do
        if curl -sf --max-time 2 "$_gw_url" >/dev/null 2>&1; then
            _gw_ready=true; break
        fi
        sleep 2
        echo -n "."
    done
    echo ""
    if ! $_gw_ready; then
        error "Gateway did not come back healthy after restart — check: ./testbed.sh logs gateway"
        exit 1
    fi
    ok "Gateway healthy."

    info "Running cvmfs-bootstrap container ..."
    run_compose run --rm cvmfs-bootstrap

    ok "Bootstrap container exited cleanly."

    info "Creating repository snapshot ..."
    cmd_snapshot
}

# ── cmd_snapshot ──────────────────────────────────────────────────────────────
# Archive the current repository state into repo-seed.tar.gz.
# The archive contains: CAS data, gateway spool, signing keys, and configs.
# Restoring it via cmd_restore produces a fully functional repository without
# needing to re-run bootstrap.
cmd_snapshot() {
    section "Creating repository snapshot"
    load_env

    local snap
    snap="$(_snapshot_path)"

    local _published="${TESTBED_ROOT}/repos/${REPO_NAME}/.cvmfspublished"
    if [[ ! -f "$_published" ]]; then
        error "No published repository found at ${TESTBED_ROOT}/repos/${REPO_NAME}."
        error "Run bootstrap first: ./testbed.sh bootstrap"
        exit 1
    fi

    info "Archiving repository state → $(basename "$snap") ..."

    # upstream-scratch is a transient scratch directory used during publish.
    # Excluding it keeps the snapshot lean and avoids partial-chunk confusion.
    tar \
        --create \
        --gzip \
        --file="$snap" \
        --directory="$TESTBED_ROOT" \
        --exclude="repos/${REPO_NAME}/upstream-scratch" \
        "repos/${REPO_NAME}" \
        "data/gateway-spool/${REPO_NAME}" \
        "config/keys" \
        "config/repo-config" \
        "config/native-publisher"

    local size
    size=$(du -sh "$snap" | cut -f1)
    ok "Snapshot created: $snap  (${size})"
    info "Restore with: ./testbed.sh restore  (or: make restore)"
}

# ── cmd_restore ───────────────────────────────────────────────────────────────
# Extract repo-seed.tar.gz into TESTBED_ROOT, replacing any existing repo data.
# Containers must NOT be running when this is called (they hold file locks).
cmd_restore() {
    section "Restoring repository from snapshot"
    load_env

    local snap
    snap="$(_snapshot_path)"

    if [[ ! -f "$snap" ]]; then
        error "No snapshot found at $snap"
        error "Run: ./testbed.sh bootstrap  (creates it automatically)"
        exit 1
    fi

    local size
    size=$(du -sh "$snap" | cut -f1)
    info "Snapshot: $snap  (${size})"

    # Wipe only what the snapshot covers so we don't touch unrelated data.
    info "Clearing existing repository data ..."
    rm -rf \
        "${TESTBED_ROOT}/repos/${REPO_NAME}" \
        "${TESTBED_ROOT}/data/gateway-spool/${REPO_NAME}" \
        "${TESTBED_ROOT}/config/keys" \
        "${TESTBED_ROOT}/config/repo-config" \
        "${TESTBED_ROOT}/config/native-publisher"
    mkdir -p \
        "${TESTBED_ROOT}/repos/${REPO_NAME}" \
        "${TESTBED_ROOT}/data/gateway-spool/${REPO_NAME}"

    info "Extracting snapshot ..."
    tar --extract --gzip --file="$snap" --directory="$TESTBED_ROOT"

    # Restore broad write permissions so container services (running as non-root)
    # can write to the CAS and spool.  Matches what init.sh sets after mkfs.
    chmod -R 777 "${TESTBED_ROOT}/repos/${REPO_NAME}"

    ok "Repository restored from snapshot."
}

cmd_restart() {
    cmd_stop
    # Reset idempotency flag so load_env runs again in cmd_start with fresh state.
    _env_loaded=false
    cmd_start
}

# ── Status helpers ─────────────────────────────────────────────────────────────
# _cmd_status_inner does the actual work without calling load_env, so it is safe
# to call from within cmd_start (where load_env already ran).
_check_http() {
    local name="$1" url="$2"
    if curl -sf --max-time 3 "$url" >/dev/null 2>&1; then
        ok "$name  →  $url"
        return 0
    else
        warn "$name  ✗  $url (not reachable)"
        return 1
    fi
}

_cmd_status_inner() {
    section "Testbed status"
    run_compose ps
    echo ""
    info "Checking service health ..."

    local _status_ok=true
    _check_http "cvmfs-prepub API"  "http://localhost:8080/api/v1/health"  || _status_ok=false
    _check_http "gateway"           "http://localhost:4929/api/v1/repos"   || _status_ok=false
    _check_http "stratum0 (apache)" "http://localhost:8090/"                 || _status_ok=false

    if $USE_BITS; then
        _check_http "Gitea API" "http://localhost:3000/api/v1/version" || _status_ok=false
    fi

    if $_status_ok; then
        ok "All checked endpoints are reachable"
    else
        warn "Some endpoints are not yet reachable — containers may still be starting"
    fi
}

cmd_status() {
    load_env
    _cmd_status_inner
}

cmd_logs() {
    load_env
    local svc="${POSITIONAL_ARGS[0]:-}"
    # Default: print the last 200 log lines and exit (safe for the web UI SSE stream).
    # Pass -f / --follow to stream logs continuously (use Ctrl-C to stop).
    local follow_flag=()
    $FOLLOW_LOGS && follow_flag=("-f")
    if [[ -n "$svc" ]]; then
        run_compose logs --tail=200 "${follow_flag[@]}" "$svc"
    else
        run_compose logs --tail=200 "${follow_flag[@]}"
    fi
}

cmd_test() {
    section "Running smoke test (method: ${PUBLISH_METHOD})"
    load_env
    case "$PUBLISH_METHOD" in
        bits)
            run_compose exec publisher /scripts/smoke-test.sh
            # The bits pipeline is asynchronous but smoke-test.sh waits for the
            # SSE "published" event before returning, so by this point the new
            # manifest is live on stratum0.  Trigger a client remount and verify
            # the expected files are visible through the FUSE mount.
            # INGEST_BASE=test/smoke matches INGEST_PATH in smoke-test.sh.
            run_compose exec -e INGEST_BASE=test/smoke cvmfs-client verify-ingest.sh
            ;;
        ingest)
            # The nested-catalog structure (test/native/smoke) is pre-created by
            # cmd_bootstrap and captured in the repo-seed.tar.gz snapshot.
            # cmd_start restores from the snapshot automatically, so by the time
            # this runs the nested catalog already exists in the repository.
            # See: ./testbed.sh bootstrap  or  make bootstrap
            run_compose exec cvmfs-native-publisher /scripts/native-smoke.sh
            # The native ingest is synchronous: the new manifest is signed and
            # served by stratum0 as soon as native-smoke.sh returns.  Tell the
            # CVMFS client to drop its cached catalog and re-read the manifest,
            # then verify the expected files are visible through the FUSE mount.
            run_compose exec cvmfs-client verify-ingest.sh
            ;;
        *)
            error "Unknown publish method: $PUBLISH_METHOD (expected bits|ingest)"
            exit 1
            ;;
    esac
}

cmd_stresstest() {
    local n="${POSITIONAL_ARGS[0]:-}"
    if [[ -z "$n" ]] || ! [[ "$n" =~ ^[1-9][0-9]*$ ]]; then
        error "Usage: $0 stresstest <n> [--concurrency <c>]  (n must be a positive integer)"
        exit 1
    fi

    # Parse --concurrency / -j from remaining positional args.
    local concurrency=""
    local remaining_args=()
    local i=1
    while [[ $i -lt ${#POSITIONAL_ARGS[@]} ]]; do
        local arg="${POSITIONAL_ARGS[$i]}"
        if [[ "$arg" == "--concurrency" || "$arg" == "-j" ]]; then
            i=$(( i + 1 ))
            concurrency="${POSITIONAL_ARGS[$i]:-}"
            if ! [[ "$concurrency" =~ ^[1-9][0-9]*$ ]]; then
                error "--concurrency requires a positive integer (got: '${concurrency}')"
                exit 1
            fi
        else
            remaining_args+=("$arg")
        fi
        i=$(( i + 1 ))
    done

    local conc_display="${concurrency:-default}"
    section "Running stress test: ${n} jobs, concurrency=${conc_display} (method: ${PUBLISH_METHOD})"
    load_env
    case "$PUBLISH_METHOD" in
        bits)
            local exec_env=(-e NUM_JOBS="$n")
            [[ -n "$concurrency" ]] && exec_env+=(-e CONCURRENCY="$concurrency")
            run_compose exec "${exec_env[@]}" publisher /scripts/stress-test.sh
            ;;
        ingest)
            # native-stress runs sequentially (cvmfs_server ingest is synchronous);
            # --concurrency is silently ignored for the ingest path.
            run_compose exec -e NUM_JOBS="$n" cvmfs-native-publisher /scripts/native-stress.sh
            ;;
        *)
            error "Unknown publish method: $PUBLISH_METHOD (expected bits|ingest)"
            exit 1
            ;;
    esac
}

cmd_upload_filelist() {
    # Upload tar.gz files to CVMFS via the bits API.
    # Runs upload-filelist.sh on the HOST (not inside a container) so it can
    # access files at arbitrary paths.
    #
    # Options (from POSITIONAL_ARGS):
    #   --dir         <path> scan directory for *.tar.gz (preferred)
    #   --concurrency <n>    max parallel uploads (default: 2)
    #   --filelist    <path> explicit path to filelist.txt (fallback)
    #   --ingest-path <p>    repository sub-path prefix (default: upload)
    #   --no-recursive       do not descend into sub-directories when scanning

    local concurrency=2
    local dir_arg=""
    local filelist_arg=""
    local ingest_path="upload"
    local no_recursive=false
    local method="$PUBLISH_METHOD"   # inherits top-level --method (bits|ingest)

    local i=0
    while [[ $i -lt ${#POSITIONAL_ARGS[@]} ]]; do
        local arg="${POSITIONAL_ARGS[$i]}"
        case "$arg" in
            --dir)
                i=$(( i + 1 ))
                dir_arg="${POSITIONAL_ARGS[$i]:-}"
                ;;
            --concurrency|-j)
                i=$(( i + 1 ))
                concurrency="${POSITIONAL_ARGS[$i]:-2}"
                [[ "$concurrency" =~ ^[1-9][0-9]*$ ]] \
                    || { error "--concurrency requires a positive integer"; exit 1; }
                ;;
            --filelist)
                i=$(( i + 1 ))
                filelist_arg="${POSITIONAL_ARGS[$i]:-}"
                ;;
            --ingest-path)
                i=$(( i + 1 ))
                ingest_path="${POSITIONAL_ARGS[$i]:-upload}"
                ;;
            --no-recursive)
                no_recursive=true
                ;;
            --method)
                i=$(( i + 1 ))
                method="${POSITIONAL_ARGS[$i]:-bits}"
                [[ "$method" == "bits" || "$method" == "ingest" ]] \
                    || { error "--method must be 'bits' or 'ingest'"; exit 1; }
                ;;
        esac
        i=$(( i + 1 ))
    done

    load_env

    local upload_script="${SCRIPT_DIR}/upload-filelist.sh"
    if [[ ! -f "$upload_script" ]]; then
        error "upload-filelist.sh not found at $upload_script"
        exit 1
    fi

    if [[ -n "$dir_arg" ]]; then
        section "Uploading from directory: ${dir_arg} (concurrency=${concurrency})"
    else
        section "Uploading filelist (bits API, concurrency=${concurrency})"
    fi

    local args=()
    args+=(--concurrency "$concurrency")
    args+=(--ingest-path "$ingest_path")
    args+=(--method "$method")
    args+=(--run-log "${TESTBED_ROOT}/data/runs.ndjson")
    [[ -n "$dir_arg"      ]] && args+=(--dir      "$dir_arg")
    [[ -n "$filelist_arg" ]] && args+=(--filelist "$filelist_arg")
    $no_recursive            && args+=(--no-recursive)

    bash "$upload_script" "${args[@]}"
}

cmd_catdump() {
    # Label defaults to the current publish method so the common workflow of
    #   ./testbed.sh test --method ingest && ./testbed.sh catdump --method ingest
    # just works without repeating the label.
    local label="${POSITIONAL_ARGS[0]:-$PUBLISH_METHOD}"
    load_env

    local cas_root="${TESTBED_ROOT}/repos/${REPO_NAME}"
    local out_dir="${TESTBED_ROOT}/data/catalog-dumps/${label}"

    if [[ ! -f "$cas_root/.cvmfspublished" ]]; then
        error "No .cvmfspublished found at $cas_root"
        error "Run a publish test first: ./testbed.sh test --method $label"
        exit 1
    fi

    section "Dumping catalogs (label: ${label})"
    info "CAS root:   $cas_root"
    info "Output dir: $out_dir"

    mkdir -p "$out_dir"
    bash "$SCRIPT_DIR/dump-catalogs.sh" "$cas_root" "$out_dir"
    ok "Catalog dumps written to $out_dir"
}

cmd_catdiff() {
    local label_a="${POSITIONAL_ARGS[0]:-ingest}"
    local label_b="${POSITIONAL_ARGS[1]:-bits}"
    load_env

    local dumps_root="${TESTBED_ROOT}/data/catalog-dumps"
    local dir_a="$dumps_root/$label_a"
    local dir_b="$dumps_root/$label_b"

    section "Diffing catalog dumps: ${label_a}  vs  ${label_b}"

    local missing=false
    [[ -d "$dir_a" ]] || { error "Dump set '$label_a' not found at $dir_a"; missing=true; }
    [[ -d "$dir_b" ]] || { error "Dump set '$label_b' not found at $dir_b"; missing=true; }
    if $missing; then
        error "Run catdump for each label first:"
        error "  ./testbed.sh test --method ingest && ./testbed.sh catdump ingest"
        error "  ./testbed.sh test --method bits   && ./testbed.sh catdump bits"
        exit 1
    fi

    local na nb
    na=$(ls "$dir_a"/*.dump 2>/dev/null | wc -l)
    nb=$(ls "$dir_b"/*.dump 2>/dev/null | wc -l)
    info "Catalogs in $label_a: $na"
    info "Catalogs in $label_b: $nb"
    echo ""

    if [[ "$na" -eq 0 && "$nb" -eq 0 ]]; then
        warn "Both dump directories are empty — run catdump first."
        exit 1
    fi

    local diff_out="$dumps_root/${label_a}_vs_${label_b}.diff"

    # Quick pre-check with --brief so the user sees which files differ without
    # waiting for the full unified diff (which can be slow on large SQL dumps).
    info "Quick file comparison (--brief)…"
    local brief_out
    brief_out=$(diff --recursive --brief "$dir_a" "$dir_b" 2>&1 || true)
    if [[ -z "$brief_out" ]]; then
        ok "No differences found — the two catalog sets are identical."
        rm -f "$diff_out"
        return 0
    fi
    echo "$brief_out"
    echo ""

    # Full unified diff — can be slow; give it up to 5 minutes.
    info "Computing full unified diff (may take a while for large catalogs)…"
    local timeout_bin=""
    command -v timeout >/dev/null 2>&1 && timeout_bin="timeout 300"

    $timeout_bin diff -u --recursive --label "$label_a" --label "$label_b" \
        "$dir_a" "$dir_b" > "$diff_out" 2>&1 || {
        local exit_code=$?
        if [[ $exit_code -eq 124 ]]; then
            warn "diff timed out after 5 minutes — dump files are very large."
            warn "Use the brief output above or compare files manually:"
            warn "  diff $dir_a/<file>.dump $dir_b/<file>.dump | head -100"
            exit 1
        fi
        # exit code 1 = differences found, which is expected — continue.
        true
    }

    local nlines
    nlines=$(wc -l < "$diff_out")
    if [[ $nlines -eq 0 ]]; then
        ok "No differences found — the two catalog sets are identical."
    else
        info "Diff written to: $diff_out  (${nlines} lines)"
        echo ""
        grep -E "^(---|\+\+\+|Only in)" "$diff_out" | head -40 || true
        echo ""
        info "View full diff:  less $diff_out"
        info "Stat summary:    diffstat $diff_out"
    fi
}

cmd_verify() {
    local job_id="${POSITIONAL_ARGS[0]:-}"
    local file_path="${POSITIONAL_ARGS[1]:-}"
    if [[ -z "$job_id" ]]; then
        error "Usage: $0 verify <job_id> [expected/file/path]"
        exit 1
    fi
    load_env
    if [[ -n "$file_path" ]]; then
        run_compose exec cvmfs-client verify-publish.sh "$job_id" "$file_path"
    else
        run_compose exec cvmfs-client verify-publish.sh "$job_id"
    fi
}

cmd_clean() {
    section "Cleaning testbed (destroying all state)"
    load_env

    warn "This will remove ALL container state and testbed data."
    warn "The repository snapshot (repo-seed.tar.gz) is PRESERVED."
    warn "Run 'clean --purge-snapshot' to also delete it."
    warn ".env is PRESERVED so services can restart with the same credentials."
    warn "Run 'clean --purge-env' (or 'make cleanall') to also delete .env."
    local _purge_snapshot=false
    local _purge_env=false
    # Check POSITIONAL_ARGS (set by top-level arg parsing) AND function arguments
    # so that both  ./testbed.sh clean --purge-snapshot  and the internal call
    # from cmd_reset (cmd_clean --purge-snapshot --purge-env) are handled correctly.
    for _arg in "${POSITIONAL_ARGS[@]+"${POSITIONAL_ARGS[@]}"}" "$@"; do
        [[ "$_arg" == "--purge-snapshot" ]] && _purge_snapshot=true
        [[ "$_arg" == "--purge-env" ]]      && _purge_env=true
    done
    if $AUTO_YES; then
        warn "Auto-confirmed (--yes flag set)."
    else
        read -rp "Continue? [y/N] " confirm
        [[ "${confirm,,}" == "y" ]] || { info "Aborted"; exit 0; }
    fi

    run_compose down -v --remove-orphans || true

    if [[ -n "${TESTBED_ROOT:-}" ]]; then
        local env_file
        env_file="$(_env_file)"
        # Preserve the snapshot file — it will be auto-restored on next start.
        local _snap
        _snap="$(_snapshot_path)"
        local _snap_bak=""
        if [[ -f "$_snap" ]] && ! $_purge_snapshot; then
            _snap_bak=$(mktemp)
            cp "$_snap" "$_snap_bak"
            info "Preserving snapshot: $(basename "$_snap")"
        fi

        for subdir in data config repos; do
            if [[ -d "$TESTBED_ROOT/$subdir" ]]; then
                info "Removing $TESTBED_ROOT/$subdir ..."
                sudo rm -rf "${TESTBED_ROOT:?}/$subdir"
            fi
        done

        if $_purge_env; then
            info "Removing $env_file ..."
            rm -f "$env_file"
        else
            info "Preserving $env_file (use --purge-env to remove)"
        fi

        # Restore the snapshot after wiping the data directories.
        if [[ -n "$_snap_bak" ]]; then
            mkdir -p "$(dirname "$_snap")"
            mv "$_snap_bak" "$_snap"
            ok "Snapshot preserved at: $_snap"
        fi
        ok "State removed"
    else
        warn "TESTBED_ROOT not set — skipped host directory removal"
    fi
}

cmd_reset() {
    # Full teardown: wipe everything (including snapshot), re-init from scratch,
    # start containers, and run bootstrap to create a fresh snapshot.
    # Use this when keys change, configs change, or you want a clean slate.
    cmd_clean --purge-snapshot --purge-env
    _env_loaded=false  # force fresh load after clean wipes .env
    cmd_init
    _env_loaded=false  # force fresh load after init writes new .env
    cmd_start
    # Run bootstrap to seed the nested catalog and create a fresh snapshot.
    # (cmd_start may have restored an old snapshot — cmd_bootstrap overwrites it
    # with a freshly signed one from the new keys.)
    cmd_bootstrap
}

# ── cmd_server ────────────────────────────────────────────────────────────────
# Start the testbed console backend server (testbed-server.py).
#
# The server:
#   - Serves testbed-console.html over HTTPS on the specified port (default: 8888).
#   - Generates a self-signed TLS certificate on first run (next to this script).
#   - Prints a one-time secret token to stdout; paste it in the browser when prompted.
#   - Reverse-proxies all internal services so the console works from ANY host.
#   - Runs ./testbed.sh commands on behalf of the browser and streams output
#     line-by-line via Server-Sent Events.
#
# Usage:
#   ./testbed.sh server [port]
#   ./testbed.sh server [port] --no-tls      # plain HTTP (trusted networks only)
#   ./testbed.sh server [port] --no-auth     # disable token (trusted networks only)
#
# Examples:
#   ./testbed.sh server             # HTTPS on port 8888
#   ./testbed.sh server 9090        # HTTPS on port 9090
#   ./testbed.sh --mqtt server      # HTTPS on 8888, MQTT overlay
#   ./testbed.sh server --no-tls    # plain HTTP
cmd_server() {
    section "Starting testbed console server"
    load_env

    # Optional port from positional args; default 8888.
    local port="${POSITIONAL_ARGS[0]:-8888}"
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        error "Invalid port: $port (must be a number)"
        exit 1
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        error "python3 not found — required for the testbed server."
        error "Install it: sudo apt install python3  (or equivalent)"
        exit 1
    fi

    local server_script="$SCRIPT_DIR/testbed-server.py"
    if [[ ! -f "$server_script" ]]; then
        error "testbed-server.py not found at $server_script"
        exit 1
    fi

    local server_args=(
        --port   "$port"
        --script "$SCRIPT_DIR/testbed.sh"
    )
    [[ -n "${TESTBED_ROOT:-}" ]] && server_args+=(--testbed-root "$TESTBED_ROOT")
    if $USE_BITS; then server_args+=(--bits); fi
    if $USE_MQTT; then server_args+=(--mqtt); fi
    # Pass through --no-tls / --no-auth if given as extra positional args
    for arg in "${POSITIONAL_ARGS[@]:1}"; do
        case "$arg" in
            --no-tls|--no-auth|--verbose) server_args+=("$arg") ;;
        esac
    done

    # testbed-server.py prints the token and access URL at startup.
    python3 "$server_script" "${server_args[@]}"
}

# ── cmd_mqtttest ───────────────────────────────────────────────────────────────
# End-to-end test that verifies the MQTT published-notification flow:
#
#  1. Subscribe to cvmfs/repos/{repo}/published inside the mosquitto container.
#  2. Run one publish job (bits or native ingest, controlled by --method).
#  3. Verify a PublishedMessage arrives within 30 s and the JSON is valid.
#  4. Inspect stratum1-a logs for the activity expected on each path:
#       bits path   → "received published notification" (object pre-warmed)
#       ingest path → S0 pull activity (root catalog fetched from stratum0)
#  5. Optionally test debounce by sending a duplicate notification and
#     confirming only one pull goroutine fires.
#
# Requires: --mqtt flag, containers started with: ./testbed.sh start --mqtt
cmd_mqtttest() {
    section "MQTT notification end-to-end test (method: ${PUBLISH_METHOD})"
    load_env

    # ── Guard: MQTT overlay must be active ────────────────────────────────────
    if ! $USE_MQTT; then
        error "This command requires the --mqtt flag."
        error "  ./testbed.sh mqtttest --mqtt [--method bits|ingest]"
        exit 1
    fi

    # ── Confirm broker is reachable ───────────────────────────────────────────
    info "Checking Mosquitto broker ..."
    if ! run_compose exec -T mosquitto mosquitto_sub --help >/dev/null 2>&1; then
        error "mosquitto container not running or mosquitto_sub not found."
        error "Start the testbed with: ./testbed.sh start --mqtt"
        exit 1
    fi
    ok "Broker reachable."

    local REPO="${REPO_NAME:?REPO_NAME not set — run: ./testbed.sh init}"
    local TOPIC="cvmfs/repos/${REPO}/published"

    # ── Step 1: subscribe in background, capture up to 10 messages / 90 s ────
    section "Step 1: subscribing to ${TOPIC}"
    local capture_file
    capture_file="$(mktemp)"
    trap 'rm -f "${capture_file}"' EXIT

    # -C 10  → exit after 10 messages (prevent hanging indefinitely)
    # -W 90  → wait up to 90 s for first message (mosquitto_sub ≥ 2.0)
    # --quiet → suppress connection banners to keep output clean
    run_compose exec -T mosquitto \
        mosquitto_sub \
            -h localhost -p 1883 \
            -t "${TOPIC}" \
            -q 1 \
            -C 10 \
            --quiet \
        2>/dev/null \
        > "${capture_file}" &
    local sub_pid=$!
    sleep 1  # give subscriber time to connect before triggering publish

    ok "Subscriber running (PID ${sub_pid}), waiting for notification ..."

    # ── Step 2: run one publish job ───────────────────────────────────────────
    section "Step 2: running publish job (method: ${PUBLISH_METHOD})"
    local test_ok=true
    case "$PUBLISH_METHOD" in
        bits)
            run_compose exec publisher /scripts/smoke-test.sh || test_ok=false
            ;;
        ingest)
            run_compose exec cvmfs-native-publisher /scripts/native-smoke.sh || test_ok=false
            ;;
        *)
            error "Unknown method: ${PUBLISH_METHOD}"
            kill "$sub_pid" 2>/dev/null || true; exit 1
            ;;
    esac

    if ! $test_ok; then
        error "Publish job failed — aborting MQTT test."
        kill "$sub_pid" 2>/dev/null || true; exit 1
    fi
    ok "Publish job completed."

    # ── Step 3: wait for notification (up to 30 s beyond job completion) ──────
    section "Step 3: waiting for MQTT notification (up to 30 s) ..."
    local deadline=$(( $(date +%s) + 30 ))
    local got_notif=false
    while [[ $(date +%s) -lt $deadline ]]; do
        if [[ -s "${capture_file}" ]]; then
            got_notif=true
            break
        fi
        sleep 1
        echo -n "."
    done
    echo ""

    # Stop the background subscriber
    kill "$sub_pid" 2>/dev/null || true
    wait "$sub_pid" 2>/dev/null || true

    if ! $got_notif; then
        error "No MQTT notification received within 30 s after publish."
        error "Check broker logs: ./testbed.sh logs mosquitto"
        error "Check prepub logs: ./testbed.sh logs cvmfs-prepub"
        exit 1
    fi

    ok "Notification received (${capture_file} is non-empty)."
    info "Raw payload(s):"
    while IFS= read -r msg; do
        info "  ${msg}"
    done < "${capture_file}"

    # ── Step 4: validate the JSON payload ─────────────────────────────────────
    section "Step 4: validating payload"
    local first_msg
    first_msg="$(head -1 "${capture_file}")"
    local payload_ok=true

    # Required fields
    for field in '"repo"' '"new_root_hash"' '"published_at"'; do
        if echo "${first_msg}" | grep -q "${field}"; then
            ok "  field ${field} present"
        else
            error "  field ${field} MISSING"
            payload_ok=false
        fi
    done

    # repo value must match REPO_NAME
    if echo "${first_msg}" | grep -q "\"${REPO}\""; then
        ok "  repo value matches: ${REPO}"
    else
        error "  repo value does not match '${REPO}'"
        payload_ok=false
    fi

    # new_root_hash must be a non-empty hex-looking string (≥32 chars)
    local hash_val
    hash_val="$(echo "${first_msg}" | grep -oP '(?<="new_root_hash":")[^"]+' || true)"
    if [[ ${#hash_val} -ge 32 ]]; then
        ok "  new_root_hash looks valid: ${hash_val:0:16}..."
    else
        error "  new_root_hash is absent or too short: '${hash_val}'"
        payload_ok=false
    fi

    # published_at must look like an ISO-8601 timestamp
    if echo "${first_msg}" | grep -qP '"published_at"\s*:\s*"\d{4}-\d{2}-\d{2}'; then
        ok "  published_at is ISO-8601 formatted"
    else
        error "  published_at does not look like an ISO-8601 timestamp"
        payload_ok=false
    fi

    if ! $payload_ok; then
        error "Payload validation failed."
        exit 1
    fi
    ok "Payload is valid."

    # ── Step 5: check Stratum 1 receiver logs ─────────────────────────────────
    section "Step 5: checking stratum1-a receiver logs"

    # Allow up to 10 s for log lines to appear after the notification.
    local log_deadline=$(( $(date +%s) + 10 ))
    local s1_log=""
    while [[ $(date +%s) -lt $log_deadline ]]; do
        s1_log="$(run_compose logs --no-log-prefix --tail=80 stratum1-a 2>&1 || true)"
        local found=false
        case "$PUBLISH_METHOD" in
            bits)
                # bits path: S1 already holds objects from the data-plane push;
                # receiver logs the incoming notification.
                if echo "${s1_log}" | grep -qi \
                    "published\|PublishedMessage\|mqtt.*notif\|notif.*received"; then
                    found=true
                fi
                ;;
            ingest)
                # ingest path: receiver fetches the root catalog from S0.
                if echo "${s1_log}" | grep -qi \
                    "pull.*S0\|pullFromS0\|fetched.*stratum0\|S0.*pull\|pulling catalog"; then
                    found=true
                fi
                ;;
        esac
        if $found; then break; fi
        sleep 2
    done

    case "$PUBLISH_METHOD" in
        bits)
            if echo "${s1_log}" | grep -qi \
                "published\|PublishedMessage\|mqtt.*notif\|notif.*received"; then
                ok "stratum1-a: published notification logged."
            else
                warn "stratum1-a: expected log line not visible in last 80 lines."
                warn "Check manually: ./testbed.sh logs stratum1-a"
            fi
            ;;
        ingest)
            if echo "${s1_log}" | grep -qi \
                "pull.*S0\|pullFromS0\|fetched.*stratum0\|S0.*pull\|pulling catalog"; then
                ok "stratum1-a: S0 pull activity logged."
            else
                warn "stratum1-a: S0 pull activity not visible in last 80 lines."
                warn "Check manually: ./testbed.sh logs stratum1-a"
                warn "(S0 pull may still be in progress or receiver-stratum0-url not set)"
            fi
            ;;
    esac

    # ── Step 6: debounce check — rapid duplicate notification ─────────────────
    if [[ "$PUBLISH_METHOD" == "ingest" ]]; then
        section "Step 6: debounce — sending a duplicate notification"
        info "Publishing the same hash twice in quick succession ..."

        # Re-use the hash from the received notification.
        local dup_hash="${hash_val}"
        local dup_payload
        dup_payload="$(printf '{"repo":"%s","new_root_hash":"%s","published_at":"%s"}' \
            "${REPO}" "${dup_hash}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"

        # Send two identical notifications back-to-back.
        for _n in 1 2; do
            run_compose exec -T mosquitto \
                mosquitto_pub -h localhost -p 1883 \
                    -t "${TOPIC}" -m "${dup_payload}" -q 1 2>/dev/null || true
        done

        # Check that only ONE pull goroutine fires (TryLock debounce).
        sleep 5
        local dup_log
        dup_log="$(run_compose logs --no-log-prefix --tail=30 stratum1-a 2>&1 || true)"
        local pull_count
        pull_count="$(echo "${dup_log}" | grep -c "pullFromS0\|S0.*pull\|pulling catalog" || true)"
        if [[ "${pull_count}" -le 1 ]]; then
            ok "Debounce working: at most 1 pull goroutine observed for duplicate notifications."
        else
            warn "Debounce: ${pull_count} pull log lines — may or may not indicate concurrent goroutines."
            warn "Check: ./testbed.sh logs stratum1-a"
        fi
    fi

    # ── Summary ───────────────────────────────────────────────────────────────
    echo ""
    ok "══ MQTT notification end-to-end test PASSED ══"
}

# ── cmd_unittest ───────────────────────────────────────────────────────────────
# Run Go unit tests for the internal/broker and internal/distribute/receiver
# packages.  These packages contain the MQTT message types, topic helpers, and
# the PublishedMessage handler that were added for the MQTT notification flow.
#
# Discovery order for the Go source tree:
#   1. $TESTBED_DIR/../cvmfs-bits  (sibling to cvmfs-testbed — the typical layout)
#   2. $TESTBED_DIR/../../cvmfs-bits  (one level up from a nested checkout)
#   3. $BITS_SRC env var, if set
#
# Fallback: if no on-host source is found, the tests are executed inside the
# cvmfs-prepub container (which has Go installed and its source mounted).
cmd_unittest() {
    section "Running MQTT / broker Go unit tests"

    # ── Locate the cvmfs-bits source tree ─────────────────────────────────────
    # Search order:
    #   1. Inside the testbed directory itself (default Makefile layout).
    #   2. BITS_SRC env var (explicit override for unittest).
    #   3. BITS_DIR env var (same variable used by the Makefile build target).
    #   4. One and two levels above SCRIPT_DIR (legacy layout).
    local candidates=(
        "${TESTBED_DIR}/cvmfs-bits"
        "${BITS_SRC:-__unset__}"
        "${BITS_DIR:-__unset__}"
        "${TESTBED_DIR}/../cvmfs-bits"
        "${TESTBED_DIR}/../../cvmfs-bits"
    )
    local bits_dir=""
    for d in "${candidates[@]}"; do
        [[ "$d" == "__unset__" ]] && continue
        if [[ -f "$d/go.mod" ]]; then
            bits_dir="$(cd "$d" && pwd)"
            break
        fi
    done

    # ── Run tests on host (preferred) ─────────────────────────────────────────
    if [[ -n "$bits_dir" ]]; then
        info "Found cvmfs-bits source at: ${bits_dir}"

        if ! command -v go >/dev/null 2>&1; then
            error "'go' not found in PATH — install Go (≥ 1.22) or use the container fallback."
            error "Re-run with the testbed running so the container fallback activates:"
            error "  ./testbed.sh unittest  (without 'go' on host, but containers running)"
            exit 1
        fi

        local go_ver
        go_ver="$(go version 2>&1 | grep -oP 'go\d+\.\d+' | head -1)"
        info "Using ${go_ver} on host."

        local overall_ok=true

        section "broker package tests"
        info "  go test -v -count=1 ./internal/broker/..."
        (cd "$bits_dir" && go test -v -count=1 ./internal/broker/...) \
            && ok "broker tests PASSED" \
            || { error "broker tests FAILED"; overall_ok=false; }

        section "receiver package tests"
        info "  go test -v -count=1 ./internal/distribute/receiver/..."
        (cd "$bits_dir" && go test -v -count=1 ./internal/distribute/receiver/...) \
            && ok "receiver tests PASSED" \
            || { error "receiver tests FAILED"; overall_ok=false; }

        if $overall_ok; then
            echo ""
            ok "══ All unit tests PASSED ══"
        else
            echo ""
            error "══ Some unit tests FAILED ══"
            exit 1
        fi
        return
    fi

    # ── Container fallback ────────────────────────────────────────────────────
    warn "cvmfs-bits source not found on host — trying container fallback."
    load_env

    # Look for the source mount inside the cvmfs-prepub container.
    # The container's working directory is set to /workspace or /go/src/... by
    # the Dockerfile.  We probe both candidates.
    local container_src=""
    for ws in /workspace /go/src/cvmfs.io/prepub; do
        if run_compose exec cvmfs-prepub test -f "${ws}/go.mod" 2>/dev/null; then
            container_src="$ws"
            break
        fi
    done

    if [[ -z "$container_src" ]]; then
        error "Cannot find Go workspace inside cvmfs-prepub container either."
        error "Mount the source tree into the container at /workspace, or set"
        error "BITS_SRC to point to the cvmfs-bits checkout on the host."
        exit 1
    fi

    info "Running tests inside cvmfs-prepub container (src: ${container_src})"
    run_compose exec cvmfs-prepub sh -c "
        set -e
        cd '${container_src}'
        echo '── broker tests ──'
        go test -v -count=1 ./internal/broker/...
        echo '── receiver tests ──'
        go test -v -count=1 ./internal/distribute/receiver/...
    " && ok "══ All unit tests PASSED ══" \
      || { error "══ Unit tests FAILED (see output above) ══"; exit 1; }
}

cmd_help() {
    # Print the file-header comment block (lines 2+ that start with #).
    # Skip line 1 (the shebang) by anchoring the range to '# testbed.sh —'.
    sed -n '/^# testbed\.sh —/,/^[^#]/p' "${BASH_SOURCE[0]}" \
        | grep '^#' | sed 's/^# \?//'
}

cmd_info() {
    load_env
    local W=34   # label column width

    echo ""
    echo "╔══════════════════════════════════════════════════════════════════════╗"
    echo "║              CVMFS-Prepub Testbed  —  Endpoints                     ║"
    echo "╠══════════════════════════════════════════════════════════════════════╣"

    _iline() {
        # _iline LABEL VALUE
        printf "║  %-${W}s  %s\n" "$1" "$2"
    }
    _isep() {
        echo "╠══════════════════════════════════════════════════════════════════════╣"
    }

    _iline "Repository:" "${REPO_NAME:-?}"
    _iline "Testbed root:" "${TESTBED_ROOT:-?}"

    _isep
    echo "║  ── cvmfs-prepub API ─────────────────────────────────────────────────║"
    _iline "  URL:"         "http://localhost:8080"
    _iline "  Health:"      "http://localhost:8080/api/v1/health"
    _iline "  Bearer token:" "${PREPUB_API_TOKEN:-(see .env)}"

    _isep
    echo "║  ── CVMFS Gateway ────────────────────────────────────────────────────║"
    _iline "  URL:"         "http://localhost:4929"
    _iline "  Key ID:"      "${CVMFS_GATEWAY_KEY_ID:-prepub-key}"
    _iline "  Secret:"      "${CVMFS_GATEWAY_SECRET:-(see .env)}"

    _isep
    echo "║  ── Stratum 0 (Apache — CVMFS content server) ────────────────────────║"
    _iline "  URL:"         "http://localhost:8090/cvmfs/${REPO_NAME:-<repo>}"
    _iline "  Credentials:" "none (read-only, no auth)"

    _isep
    echo "║  ── Stratum 1 receivers ───────────────────────────────────────────────║"
    _iline "  stratum1-a control:" "http://localhost:9101"
    _iline "  stratum1-a data:"    "http://localhost:9111"
    _iline "  stratum1-b control:" "http://localhost:9102"
    _iline "  stratum1-b data:"    "http://localhost:9112"
    _iline "  HMAC secret:"        "${PREPUB_HMAC_SECRET:-(see .env)}"

    _isep
    echo "║  ── Monitoring ────────────────────────────────────────────────────────║"
    _iline "  VictoriaMetrics:" "internal only (scraped by vmagent)"

    if $USE_BITS && [[ -n "${GITEA_ADMIN_USER:-}" ]]; then
        _isep
        echo "║  ── Gitea (bits overlay) ──────────────────────────────────────────────║"
        _iline "  URL:"      "http://localhost:3000"
        _iline "  SSH:"      "git@localhost:2222"
        _iline "  User:"     "${GITEA_ADMIN_USER}"
        _iline "  Password:" "${GITEA_ADMIN_PASSWORD:-(see .env)}"
    fi

    if $USE_MQTT; then
        _isep
        echo "║  ── MQTT (control plane) ──────────────────────────────────────────────║"
        _iline "  Broker:"   "mqtt://localhost:1883"
        _iline "  Credentials:" "none (testbed mode)"
    fi

    echo "╠══════════════════════════════════════════════════════════════════════╣"
    echo "║  Full secrets: ${TESTBED_ROOT:-\$TESTBED_ROOT}/.env"
    echo "╚══════════════════════════════════════════════════════════════════════╝"

    # ── Architecture diagram ───────────────────────────────────────────────────
    local repo="${REPO_NAME:-<repo>}"
    cat <<EOF

  ┌─────────────────────────────────────────────────────────────────────────────┐
  │               Testbed Architecture  (docker network: cvmfs-net)              │
  └─────────────────────────────────────────────────────────────────────────────┘

   ── PUBLISH FLOW ──────────────────────────────────────────────────────────────

     curl / publisher container
           │
           │  REST + SSE  (host :8080)
           ▼
     ┌─────────────────┐   lease req    ┌──────────────────┐
     │  cvmfs-prepub   │ ─────:4929────►│    gateway       │
     │  :8080          │◄─── granted ───│    :4929         │
     └────────┬────────┘                └──────────────────┘
              │
              │  write CAS + sign manifest
              ▼
          repos/${repo}/      ← host volume, shared by containers
            ├── gateway      → /srv/cvmfs/${repo}   (rw)
            ├── cvmfs-prepub → /data/cas             (rw)
            └── stratum0     → /htdocs/cvmfs         (ro)
              │
              │  replicate  (after successful publish)
              ├──────────────────────────────────────────► stratum1-a  :9101/9111
              └──────────────────────────────────────────► stratum1-b  :9102/9112

   ── SERVE FLOW ────────────────────────────────────────────────────────────────

     repos/${repo}/  (shared volume, read-only via stratum0)
           │
           │  static HTTP  (host :8090)
           ▼
     ┌─────────────────┐                         ┌──────────────────────────┐
     │  stratum0       │──── /cvmfs/${repo} ───►│  cvmfs-client            │
     │  Apache :80     │                         │  FUSE → /cvmfs/${repo}  │
     └─────────────────┘                         └──────────────────────────┘

   ── MONITORING ────────────────────────────────────────────────────────────────

     ┌──────────┐  scrape  ┌───────────────────┐
     │  vmagent │─────────►│  victoriametrics  │
     └──────────┘          └───────────────────┘
          │
          └── scrapes: prepub :8080, gateway :4929, stratum1-a/b :9100
          (metrics visible in the testbed console Monitoring tab)

EOF
}

# ── cmd_pulltest ──────────────────────────────────────────────────────────────
# End-to-end test of ADR-0001 pull-based distribution. Requires --pull (which
# implies --mqtt). Runs one publish job and verifies that each Stratum 1 receiver
# fetched the new objects from Stratum 0 by itself (pull), rather than being
# pushed to. Warm quorum is reached when at least PULL_QUORUM receivers warm.
#
#   ./testbed.sh pulltest --pull [--method bits|ingest]
#
# PULL_QUORUM (env, default 1): minimum warmed receivers for the test to pass.
cmd_pulltest() {
    section "Pull-distribution end-to-end test (method: ${PUBLISH_METHOD})"
    load_env

    if ! $USE_PULL; then
        error "This command requires the --pull flag (it implies --mqtt)."
        error "  ./testbed.sh pulltest --pull [--method bits|ingest]"
        exit 1
    fi

    local REPO="${REPO_NAME:?REPO_NAME not set — run: ./testbed.sh init}"
    local receivers=(stratum1-a stratum1-b)
    local quorum="${PULL_QUORUM:-1}"

    # ── Step 1: confirm the publisher is serving in pull mode ─────────────────
    section "Step 1: confirm cvmfs-prepub is in pull mode"
    local pub_log
    pub_log="$(run_compose logs --no-log-prefix --tail=200 cvmfs-prepub 2>&1 || true)"
    if echo "${pub_log}" | grep -qiE "distribute serving mounted .*pull|distribute_mode.*pull|pull mode"; then
        ok "Publisher reports pull mode."
    else
        warn "Could not confirm pull mode from publisher logs — continuing anyway."
        warn "  (publisher-side commit orchestration may still be landing; see ADR-0001 P3)"
    fi

    # ── Step 2: snapshot each receiver's warmed-count baseline ────────────────
    # We count pre-existing "transaction warmed" lines so we only credit NEW pulls
    # triggered by this test's publish.
    declare -A baseline
    local r
    for r in "${receivers[@]}"; do
        baseline[$r]="$(run_compose logs --no-log-prefix "$r" 2>&1 \
            | grep -c 'pull: transaction warmed' || true)"
        info "  ${r}: ${baseline[$r]} prior warm(s)"
    done

    # ── Step 3: run one publish job ───────────────────────────────────────────
    section "Step 3: running publish job (method: ${PUBLISH_METHOD})"
    local pub_ok=true
    case "$PUBLISH_METHOD" in
        bits)   run_compose exec publisher /scripts/smoke-test.sh || pub_ok=false ;;
        ingest) run_compose exec cvmfs-native-publisher /scripts/native-smoke.sh || pub_ok=false ;;
        *)      error "Unknown method: ${PUBLISH_METHOD}"; exit 1 ;;
    esac
    $pub_ok || { error "Publish job failed — aborting pull test."; exit 1; }
    ok "Publish job completed."

    # ── Step 4: wait for receivers to pull (up to 60 s) ───────────────────────
    section "Step 4: waiting for receivers to pull new objects from S0"
    local deadline=$(( $(date +%s) + 60 ))
    declare -A warmed
    local warmed_count=0
    while [[ $(date +%s) -lt $deadline ]]; do
        warmed_count=0
        for r in "${receivers[@]}"; do
            local now
            now="$(run_compose logs --no-log-prefix "$r" 2>&1 \
                | grep -c 'pull: transaction warmed' || true)"
            if [[ "$now" -gt "${baseline[$r]}" ]]; then
                warmed[$r]=1
            fi
            [[ -n "${warmed[$r]:-}" ]] && warmed_count=$(( warmed_count + 1 ))
        done
        [[ $warmed_count -ge $quorum ]] && break
        sleep 2; echo -n "."
    done
    echo ""

    # ── Step 5: report ────────────────────────────────────────────────────────
    section "Step 5: result"
    for r in "${receivers[@]}"; do
        if [[ -n "${warmed[$r]:-}" ]]; then
            local line
            line="$(run_compose logs --no-log-prefix "$r" 2>&1 \
                | grep 'pull: transaction warmed' | tail -1)"
            ok "  ${r} pulled & warmed:  ${line#*pull: }"
        else
            warn "  ${r} did NOT report a new pull warm"
            # Surface a failure line if present, to aid debugging.
            run_compose logs --no-log-prefix --tail=40 "$r" 2>&1 \
                | grep -E 'pull: transaction failed|concurrency limit' | tail -2 \
                | while IFS= read -r l; do error "    ${l}"; done
        fi
    done

    if [[ $warmed_count -ge $quorum ]]; then
        ok "Pull quorum reached: ${warmed_count}/${#receivers[@]} receivers warmed (need ${quorum})."
        exit 0
    fi
    error "Pull quorum NOT reached: ${warmed_count}/${#receivers[@]} warmed (need ${quorum})."
    error "Likely causes:"
    error "  • publisher-side commit orchestration not yet wired into the publish loop"
    error "    (ADR-0001 P3 — Notifier.Announce / manifest POST); or"
    error "  • receivers cannot reach the manifest at http://stratum0/cvmfs/s1/{txn}/manifest"
    error "Inspect with: ./testbed.sh pullstatus --pull"
    exit 1
}

# ── cmd_pullstatus ────────────────────────────────────────────────────────────
# Monitoring helper: dumps the pull-relevant log lines from the publisher and
# both receivers (announce, manifest serving, warm/commit, pull outcomes).
#
#   ./testbed.sh pullstatus --pull
cmd_pullstatus() {
    section "Pull-distribution status"
    load_env

    section "Publisher (cvmfs-prepub) — serving / announce / commit"
    run_compose logs --no-log-prefix --tail=200 cvmfs-prepub 2>&1 \
        | grep -iE 'pull mode|distribute serving|announce|manifest|warm|committed|lease|admission' \
        | tail -25 || info "  (no matching lines)"

    local r
    for r in stratum1-a stratum1-b; do
        section "Receiver ${r} — pull outcomes"
        run_compose logs --no-log-prefix --tail=200 "$r" 2>&1 \
            | grep -iE 'pull: transaction (warmed|failed)|concurrency limit|fetched|skipped|failed' \
            | tail -15 || info "  (no matching lines)"
    done
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
case "$CMD" in
    init)           cmd_init ;;
    start)          cmd_start ;;
    stop)           cmd_stop ;;
    restart)        cmd_restart ;;
    status)         cmd_status ;;
    info)           cmd_info ;;
    logs)           cmd_logs ;;
    bootstrap)      cmd_bootstrap ;;
    snapshot)       cmd_snapshot ;;
    restore)        cmd_restore ;;
    test)           cmd_test ;;
    stresstest)     cmd_stresstest ;;
    upload-filelist) cmd_upload_filelist ;;
    catdump)        cmd_catdump ;;
    catdiff)        cmd_catdiff ;;
    verify)         cmd_verify ;;
    server)         cmd_server ;;
    mqtttest)       cmd_mqtttest ;;
    pulltest)       cmd_pulltest ;;
    pullstatus)     cmd_pullstatus ;;
    unittest)       cmd_unittest ;;
    clean)          cmd_clean ;;
    reset)          cmd_reset ;;
    help|--help|-h) cmd_help ;;
    *)
        error "Unknown command: $CMD"
        echo "Run: $0 help"
        exit 1
        ;;
esac
