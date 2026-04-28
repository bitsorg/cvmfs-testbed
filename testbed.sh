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
load_env() {
    if [[ -f "$SCRIPT_DIR/.env" ]]; then
        set -a; source "$SCRIPT_DIR/.env"; set +a
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

    # If bits-src override given, write it into .env before running init.sh
    if [[ -n "$BITS_SRC_OVERRIDE" ]] && [[ -f "$SCRIPT_DIR/.env" ]]; then
        if grep -q "^BITS_CONSOLE_SRC=" "$SCRIPT_DIR/.env"; then
            sed -i "s|^BITS_CONSOLE_SRC=.*|BITS_CONSOLE_SRC=$BITS_SRC_OVERRIDE|" "$SCRIPT_DIR/.env"
        else
            echo "BITS_CONSOLE_SRC=$BITS_SRC_OVERRIDE" >> "$SCRIPT_DIR/.env"
        fi
        info "Set BITS_CONSOLE_SRC=$BITS_SRC_OVERRIDE in .env"
    elif [[ -n "$BITS_SRC_OVERRIDE" ]] && [[ ! -f "$SCRIPT_DIR/.env" ]]; then
        cp "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/.env"
        echo "BITS_CONSOLE_SRC=$BITS_SRC_OVERRIDE" >> "$SCRIPT_DIR/.env"
        info "Created .env with BITS_CONSOLE_SRC=$BITS_SRC_OVERRIDE"
    fi

    bash "$SCRIPT_DIR/init.sh"
    ok "Init complete"
}

cmd_start() {
    section "Starting testbed"
    load_env

    if $USE_BITS && [[ -z "${BITS_CONSOLE_SRC:-}" ]]; then
        error "--bits requires BITS_CONSOLE_SRC to be set in .env or via --bits-src"
        exit 1
    fi

    # Build any images that need it
    info "Building images (if needed) ..."
    run_compose build --parallel

    info "Starting services ..."
    run_compose up -d

    # Show status after a brief settle
    sleep 3
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
