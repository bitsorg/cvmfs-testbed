#!/usr/bin/env bash
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
#   help            Show this help text.
#
# Options (accepted by all commands):
#   --bits                Include the bits-console overlay (Gitea + seeder).
#                         Requires bits-console/ to be present in this directory.
#   --mqtt                Include the MQTT control-plane overlay.
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

# ── Default flags ─────────────────────────────────────────────────────────────
USE_BITS=false
USE_MQTT=false
SOFTWARE_ROOT_OVERRIDE=""
TESTBED_ROOT_OVERRIDE=""
PUBLISH_METHOD="bits"   # bits | ingest
AUTO_YES=false          # skip interactive confirmation prompts (e.g. for make)

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
        # --bits-src is no longer needed: bits-console lives at $SCRIPT_DIR/bits-console.
        # Accept it silently for backward compatibility.
        --bits-src)
            warn "--bits-src is no longer needed; bits-console/ is expected at $SCRIPT_DIR/bits-console"
            [[ $# -ge 2 ]] && shift 2 || shift ;;
        --bits-src=*)          warn "--bits-src is no longer needed; bits-console/ is expected at $SCRIPT_DIR/bits-console"; shift ;;
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
        --*)  error "Unknown option: $1"; exit 1 ;;
        *)    POSITIONAL_ARGS+=("$1");                           shift ;;
    esac
done

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
    BITS_CONSOLE_SRC="$SCRIPT_DIR/bits-console"

    # 5. Prepend SOFTWARE_ROOT to PATH so locally built binaries take precedence
    #    over any system-wide CVMFS installation in a potentially read-only area.
    local sw="${SOFTWARE_ROOT:-$SCRIPT_DIR/software}"
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
    _COMPOSE_FILES=("-f" "$SCRIPT_DIR/docker-compose.yml")
    if $USE_MQTT; then _COMPOSE_FILES+=("-f" "$SCRIPT_DIR/docker-compose.mqtt.yml"); fi
    if $USE_BITS; then  _COMPOSE_FILES+=("-f" "$SCRIPT_DIR/docker-compose.bits.yml"); fi
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
    local sw="${SOFTWARE_ROOT:-$SCRIPT_DIR/software}"
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

    if $USE_BITS && [[ ! -d "$SCRIPT_DIR/bits-console" ]]; then
        error "--bits requires bits-console/ to be present at $SCRIPT_DIR/bits-console"
        error "Clone or symlink it there:"
        error "  git clone https://github.com/your-org/bits-console $SCRIPT_DIR/bits-console"
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
    cmd_info           # print endpoint summary
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

    # Pre-create the spool directory the bootstrap container needs.
    mkdir -p "${TESTBED_ROOT}/data/bootstrap-spool"

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
        _check_http "Grafana"   "http://localhost:3001/api/health"     || _status_ok=false
    else
        _check_http "Grafana"   "http://localhost:3000/api/health"     || _status_ok=false
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
    if [[ -n "$svc" ]]; then
        run_compose logs -f "$svc"
    else
        run_compose logs -f
    fi
}

cmd_test() {
    section "Running smoke test (method: ${PUBLISH_METHOD})"
    load_env
    case "$PUBLISH_METHOD" in
        bits)
            run_compose exec publisher /scripts/smoke-test.sh
            ;;
        ingest)
            # The nested-catalog structure (test/native/smoke) is pre-created by
            # cmd_bootstrap and captured in the repo-seed.tar.gz snapshot.
            # cmd_start restores from the snapshot automatically, so by the time
            # this runs the nested catalog already exists in the repository.
            # See: ./testbed.sh bootstrap  or  make bootstrap
            run_compose exec cvmfs-native-publisher /scripts/native-smoke.sh
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
        error "Usage: $0 stresstest <n>  (n must be a positive integer)"
        exit 1
    fi
    section "Running stress test: ${n} jobs (method: ${PUBLISH_METHOD})"
    load_env
    case "$PUBLISH_METHOD" in
        bits)
            run_compose exec -e NUM_JOBS="$n" publisher /scripts/stress-test.sh
            ;;
        ingest)
            run_compose exec -e NUM_JOBS="$n" cvmfs-native-publisher /scripts/native-stress.sh
            ;;
        *)
            error "Unknown publish method: $PUBLISH_METHOD (expected bits|ingest)"
            exit 1
            ;;
    esac
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
    bash "$SCRIPT_DIR/tools/dump-catalogs.sh" "$cas_root" "$out_dir"
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

    info "Catalogs in $label_a: $(ls "$dir_a"/*.dump 2>/dev/null | wc -l)"
    info "Catalogs in $label_b: $(ls "$dir_b"/*.dump 2>/dev/null | wc -l)"
    echo ""

    local diff_out="$dumps_root/${label_a}_vs_${label_b}.diff"
    diff -u --recursive --label "$label_a" --label "$label_b" "$dir_a" "$dir_b" \
        > "$diff_out" 2>&1 || true

    local nlines
    nlines=$(wc -l < "$diff_out")
    if [[ $nlines -eq 0 ]]; then
        ok "No differences found — the two catalog sets are identical."
    else
        info "Diff written to: $diff_out  (${nlines} lines)"
        echo ""
        # Print a summary: which files differ, added, removed.
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
    local _purge_snapshot=false
    # Check POSITIONAL_ARGS (set by top-level arg parsing) AND function arguments
    # so that both  ./testbed.sh clean --purge-snapshot  and the internal call
    # from cmd_reset (cmd_clean --purge-snapshot) are handled correctly.
    for _arg in "${POSITIONAL_ARGS[@]+"${POSITIONAL_ARGS[@]}"}" "$@"; do
        [[ "$_arg" == "--purge-snapshot" ]] && _purge_snapshot=true
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
        info "Removing $env_file ..."
        rm -f "$env_file"

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
    cmd_clean --purge-snapshot
    _env_loaded=false  # force fresh load after clean wipes .env
    cmd_init
    _env_loaded=false  # force fresh load after init writes new .env
    cmd_start
    # Run bootstrap to seed the nested catalog and create a fresh snapshot.
    # (cmd_start may have restored an old snapshot — cmd_bootstrap overwrites it
    # with a freshly signed one from the new keys.)
    cmd_bootstrap
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

    # Grafana port: 3000 normally, 3001 when bits overlay remaps it.
    local grafana_port=3000
    if $USE_BITS; then grafana_port=3001; fi

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
    _iline "  Grafana:"      "http://localhost:${grafana_port}  (admin / admin)"
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
    local gport="${grafana_port}"
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

     ┌──────────┐  scrape  ┌───────────────────┐  query  ┌──────────────────┐
     │  vmagent │─────────►│  victoriametrics  │────────►│  Grafana  :${gport}  │
     └──────────┘          └───────────────────┘         │  admin / admin   │
          │                                               └──────────────────┘
          └── scrapes: prepub :8080, gateway :4929, stratum1-a/b :9100

EOF
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
    catdump)        cmd_catdump ;;
    catdiff)        cmd_catdiff ;;
    verify)         cmd_verify ;;
    clean)          cmd_clean ;;
    reset)          cmd_reset ;;
    help|--help|-h) cmd_help ;;
    *)
        error "Unknown command: $CMD"
        echo "Run: $0 help"
        exit 1
        ;;
esac
