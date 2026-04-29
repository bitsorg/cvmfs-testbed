#!/usr/bin/env bash
# testbed.sh — Top-level bootstrap and management script for the cvmfs-prepub testbed.
#
# Usage:
#   ./testbed.sh [command] [options]
#
# Commands:
#   init      One-time host setup: create directories, generate secrets,
#             initialise CVMFS repository, write service configs.
#   start     Build images (if needed) and start containers.
#   stop      Stop containers without removing state.
#   restart   Stop then start.
#   status    Show container status and key service health.
#   logs      Tail logs (all services, or pass a service name).
#   test      Run the smoke test.
#   verify    Verify end-to-end file visibility (needs a job UUID).
#   clean     Stop containers AND remove all persistent state.
#   reset     clean + init (full teardown and reinitialisation).
#   help      Show this help text.
#
# Options:
#   --bits           Include the bits-console overlay (Gitea + seeder)
#   --mqtt           Include the MQTT control-plane overlay
#   --bits-src PATH  Path to bits-console source (overrides BITS_CONSOLE_SRC)
#
# Examples:
#   # First-time setup (core stack):
#   ./testbed.sh init
#   ./testbed.sh start
#   ./testbed.sh test
#
#   # With bits-console and Gitea:
#   ./testbed.sh init --bits --bits-src /path/to/bits-console
#   ./testbed.sh start --bits
#
#   # Full teardown and reinitialise:
#   ./testbed.sh reset --bits --bits-src /path/to/bits-console

set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
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
BITS_SRC_OVERRIDE=""

# ── Argument parsing ──────────────────────────────────────────────────────────
CMD="${1:-help}"
shift || true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bits)           USE_BITS=true ;;
        --mqtt)           USE_MQTT=true ;;
        --bits-src)       BITS_SRC_OVERRIDE="$2"; shift ;;
        --bits-src=*)     BITS_SRC_OVERRIDE="${1#*=}" ;;
        *)                error "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

# ── .env helpers ──────────────────────────────────────────────────────────────
# .env lives in TESTBED_ROOT (the script dir may be read-only).
# Bootstrap: use TESTBED_ROOT from the environment, then re-read it from .env.
_env_file() {
    local root="${TESTBED_ROOT:-$HOME/cvmfs-testbed}"
    echo "$root/.env"
}

load_env() {
    local env_file
    env_file="$(_env_file)"
    if [[ -f "$env_file" ]]; then
        set -a; source "$env_file"; set +a
    else
        warn ".env not found at $env_file — run: ./testbed.sh init"
    fi
    # Allow command-line override of BITS_CONSOLE_SRC
    if [[ -n "$BITS_SRC_OVERRIDE" ]]; then
        BITS_CONSOLE_SRC="$BITS_SRC_OVERRIDE"
    fi
}

# ── Compose file list ─────────────────────────────────────────────────────────
compose_files() {
    local files="-f $SCRIPT_DIR/docker-compose.yml"
    $USE_MQTT && files="$files -f $SCRIPT_DIR/docker-compose.mqtt.yml"
    $USE_BITS && files="$files -f $SCRIPT_DIR/docker-compose.bits.yml"
    echo "$files"
}

run_compose() {
    # shellcheck disable=SC2046
    docker compose $(compose_files) "$@"
}

# ── Commands ──────────────────────────────────────────────────────────────────

cmd_init() {
    section "Initialising testbed"

    # If bits-src override given, export it so init.sh picks it up
    if [[ -n "$BITS_SRC_OVERRIDE" ]]; then
        export BITS_CONSOLE_SRC="$BITS_SRC_OVERRIDE"
        info "BITS_CONSOLE_SRC=$BITS_SRC_OVERRIDE (will be written to .env by init.sh)"
    fi

    bash "$SCRIPT_DIR/init.sh"
    ok "Init complete"
}

cmd_start() {
    section "Starting testbed"
    load_env

    # Preflight: TESTBED_ROOT must exist and be writable
    if [[ -z "${TESTBED_ROOT:-}" ]]; then
        error "TESTBED_ROOT is not set. Run: ./testbed.sh init"
        exit 1
    fi
    if [[ ! -d "${TESTBED_ROOT}" ]]; then
        error "TESTBED_ROOT=${TESTBED_ROOT} does not exist. Run: ./testbed.sh init"
        exit 1
    fi
    if [[ ! -w "${TESTBED_ROOT}" ]]; then
        error "TESTBED_ROOT=${TESTBED_ROOT} is not writable."
        error "Choose a writable path (e.g. \$HOME/cvmfs-testbed) and re-run: ./testbed.sh init"
        exit 1
    fi

    # Preflight: SOFTWARE_ROOT binaries must be regular files, not directories
    local sw="${SOFTWARE_ROOT:-${TESTBED_ROOT}/software}"
    local missing=()
    for bin in cvmfs_gateway cvmfs-prepub cvmfs2 cvmfs_talk; do
        local p="$sw/$bin"
        if [[ -d "$p" ]]; then
            error "  $p is a directory, not a binary."
            error "  Docker created it as a placeholder when the file was missing."
            error "  Remove it: rm -rf $p"
            missing+=("$bin")
        elif [[ ! -f "$p" ]]; then
            warn "  $p not found — container will fail to start."
            missing+=("$bin")
        elif [[ ! -x "$p" ]]; then
            error "  $p exists but is not executable. Run: chmod +x $p"
            missing+=("$bin")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing or broken binaries in $sw: ${missing[*]}"
        error "Copy the built binaries there, then re-run: ./testbed.sh start"
        exit 1
    fi

    # Preflight: config files must be regular files, not directories
    local cfg_root="${TESTBED_ROOT}/config"
    local bad_configs=()
    for cfg in \
        "cvmfs-prepub/config.yaml" \
        "gateway/gw.json" \
        "gateway/user.json" \
        "gateway/repo.json" \
        "stratum1-a/config.yaml" \
        "stratum1-b/config.yaml"; do
        local p="$cfg_root/$cfg"
        if [[ -d "$p" ]]; then
            error "  $p is a directory (Docker placeholder). Remove it: rm -rf $p"
            bad_configs+=("$cfg")
        elif [[ ! -f "$p" ]]; then
            error "  $p is missing."
            bad_configs+=("$cfg")
        fi
    done
    if [[ ${#bad_configs[@]} -gt 0 ]]; then
        error "Config files missing or corrupted. Run: ./testbed.sh init"
        exit 1
    fi

    if $USE_BITS && [[ -z "${BITS_CONSOLE_SRC:-}" ]]; then
        error "--bits requires BITS_CONSOLE_SRC to be set in .env or via --bits-src"
        exit 1
    fi

    # Build any images that need it
    info "Building images (if needed) ..."
    run_compose build --parallel

    info "Starting services ..."
    run_compose up -d

    # Wait for services to initialise, then show health
    info "Waiting for services to initialise ..."
    local deadline=$(( $(date +%s) + 60 ))
    local all_up=false
    while [[ $(date +%s) -lt $deadline ]]; do
        sleep 5
        local ok=true
        for url in \
            "http://localhost:8080/api/v1/version" \
            "http://localhost:4929/api/v1/meta/info" \
            "http://localhost:8090/"; do
            curl -sf --max-time 2 "$url" > /dev/null 2>&1 || { ok=false; break; }
        done
        if $USE_BITS; then
            curl -sf --max-time 2 "http://localhost:3000/api/v1/version" > /dev/null 2>&1 || ok=false
        fi
        if $ok; then
            all_up=true
            break
        fi
        echo -n "."
    done
    echo ""
    if ! $all_up; then
        warn "Some services did not respond within 60 s — check logs: ./testbed.sh logs"
    fi
    cmd_status
}

cmd_stop() {
    section "Stopping testbed"
    load_env
    run_compose stop
    ok "All containers stopped"
}

cmd_restart() {
    cmd_stop
    cmd_start
}

cmd_status() {
    section "Testbed status"
    load_env
    run_compose ps
    echo ""

    # Spot-check key service endpoints
    info "Checking service health ..."

    local all_ok=true

    check_http() {
        local name="$1" url="$2"
        if curl -sf --max-time 3 "$url" > /dev/null 2>&1; then
            ok "$name  →  $url"
        else
            warn "$name  ✗  $url (not reachable)"
            all_ok=false
        fi
    }

    check_http "cvmfs-prepub API" "http://localhost:8080/api/v1/version" || true
    check_http "gateway"          "http://localhost:4929/api/v1/meta/info" || true
    check_http "stratum0 (apache)" "http://localhost:8090/" || true

    if $USE_BITS; then
        check_http "Gitea API"     "http://localhost:3000/api/v1/version" || true
        check_http "Grafana"       "http://localhost:3001/api/health" || true
    else
        check_http "Grafana"       "http://localhost:3000/api/health" || true
    fi

    if $all_ok; then
        ok "All checked endpoints are reachable"
    else
        warn "Some endpoints are not yet reachable — containers may still be starting"
    fi
}

cmd_logs() {
    load_env
    local svc="${1:-}"
    if [[ -n "$svc" ]]; then
        run_compose logs -f "$svc"
    else
        run_compose logs -f
    fi
}

cmd_test() {
    section "Running smoke test"
    load_env
    run_compose exec publisher /scripts/smoke-test.sh
}

cmd_verify() {
    local job_id="${1:-}"
    local file_path="${2:-}"
    if [[ -z "$job_id" ]]; then
        error "Usage: $0 verify <job_id> [expected/file/path]"
        exit 1
    fi
    load_env
    run_compose exec cvmfs-client verify-publish.sh "$job_id" $file_path
}

cmd_clean() {
    section "Cleaning testbed (destroying all state)"
    load_env

    warn "This will remove ALL container state and testbed data."
    read -p "Continue? [y/N] " confirm
    [[ "${confirm,,}" == "y" ]] || { info "Aborted"; exit 0; }

    run_compose down -v --remove-orphans || true

    if [[ -n "${TESTBED_ROOT:-}" ]]; then
        info "Removing $TESTBED_ROOT/data ..."
        sudo rm -rf "${TESTBED_ROOT}/data"
        info "Removing $TESTBED_ROOT/config ..."
        sudo rm -rf "${TESTBED_ROOT}/config"
        info "Removing $TESTBED_ROOT/cvmfs ..."
        sudo rm -rf "${TESTBED_ROOT}/cvmfs"
        info "Removing $SCRIPT_DIR/.env ..."
        rm -f "$SCRIPT_DIR/.env"
        ok "State removed"
    else
        warn "TESTBED_ROOT not set — skipped host directory removal"
    fi
}

cmd_reset() {
    cmd_clean
    cmd_init
    cmd_start
}

cmd_help() {
    sed -n '/^# testbed.sh/,/^[^#]/p' "${BASH_SOURCE[0]}" \
      | grep '^#' | sed 's/^# \?//'
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
case "$CMD" in
    init)    cmd_init ;;
    start)   cmd_start ;;
    stop)    cmd_stop ;;
    restart) cmd_restart ;;
    status)  load_env; cmd_status ;;
    logs)    cmd_logs "${@:-}" ;;
    test)    cmd_test ;;
    verify)  cmd_verify "${@:-}" ;;
    clean)   cmd_clean ;;
    reset)   cmd_reset ;;
    help|--help|-h) cmd_help ;;
    *)
        error "Unknown command: $CMD"
        echo "Run: $0 help"
        exit 1
        ;;
esac
