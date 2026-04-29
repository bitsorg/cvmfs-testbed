#!/usr/bin/env bash
# testbed.sh — Top-level bootstrap and management script for the cvmfs-prepub testbed.
#
# Usage:
#   ./testbed.sh [command] [options] [args]
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
#   reset     clean + init + start (full teardown and reinitialisation).
#   help      Show this help text.
#
# Options (accepted by all commands):
#   --bits                Include the bits-console overlay (Gitea + seeder).
#   --mqtt                Include the MQTT control-plane overlay.
#   --bits-src PATH       Path to bits-console source tree (overrides BITS_CONSOLE_SRC).
#   --software-root PATH  Path to directory containing CVMFS binaries under test
#                         (overrides SOFTWARE_ROOT from .env).
#   --testbed-root PATH   Path to testbed data root (overrides TESTBED_ROOT from .env).
#
# .env location:
#   The .env file is stored in TESTBED_ROOT, NOT next to this script.
#   The script directory (/opt/bits/cvmfs-testbed) may be read-only.
#   Bootstrap order for TESTBED_ROOT: --testbed-root flag > $TESTBED_ROOT env var
#   > value read from an existing .env > default $HOME/cvmfs-testbed.
#
# Examples:
#   # First-time setup (core stack):
#   ./testbed.sh init
#   ./testbed.sh start
#   ./testbed.sh test
#
#   # Override binary and data locations:
#   ./testbed.sh init  --testbed-root /data/tb --software-root /data/tb/software
#   ./testbed.sh start --software-root ~/cvmfs-testbed/software
#
#   # With bits-console and Gitea:
#   ./testbed.sh init  --bits --bits-src /path/to/bits-console
#   ./testbed.sh start --bits
#
#   # Tail logs for a single service:
#   ./testbed.sh logs gateway
#
#   # Verify a publish job end-to-end:
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
BITS_SRC_OVERRIDE=""
SOFTWARE_ROOT_OVERRIDE=""
TESTBED_ROOT_OVERRIDE=""

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
        --bits-src)
            [[ $# -ge 2 ]] || { error "--bits-src requires a value"; exit 1; }
            BITS_SRC_OVERRIDE="$2"; shift 2 ;;
        --bits-src=*)          BITS_SRC_OVERRIDE="${1#*=}";      shift ;;
        --software-root)
            [[ $# -ge 2 ]] || { error "--software-root requires a value"; exit 1; }
            SOFTWARE_ROOT_OVERRIDE="$2"; shift 2 ;;
        --software-root=*)     SOFTWARE_ROOT_OVERRIDE="${1#*=}"; shift ;;
        --testbed-root)
            [[ $# -ge 2 ]] || { error "--testbed-root requires a value"; exit 1; }
            TESTBED_ROOT_OVERRIDE="$2"; shift 2 ;;
        --testbed-root=*)      TESTBED_ROOT_OVERRIDE="${1#*=}";  shift ;;
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
    [[ -n "$BITS_SRC_OVERRIDE"      ]] && BITS_CONSOLE_SRC="$BITS_SRC_OVERRIDE"

    # 4. Prepend SOFTWARE_ROOT to PATH so locally built binaries take precedence
    #    over any system-wide CVMFS installation in a potentially read-only area.
    local sw="${SOFTWARE_ROOT:-${TESTBED_ROOT:-$HOME/cvmfs-testbed}/software}"
    if [[ -d "$sw" ]] && [[ ":$PATH:" != *":$sw:"* ]]; then
        export PATH="$sw:$PATH"
    fi
}

# ── Compose helpers ───────────────────────────────────────────────────────────
compose_files() {
    # Returns the -f flags as an array (via nameref or by printing to caller).
    # Using a global array avoids word-splitting issues with paths containing spaces.
    _COMPOSE_FILES=("-f" "$SCRIPT_DIR/docker-compose.yml")
    $USE_MQTT && _COMPOSE_FILES+=("-f" "$SCRIPT_DIR/docker-compose.mqtt.yml")
    $USE_BITS && _COMPOSE_FILES+=("-f" "$SCRIPT_DIR/docker-compose.bits.yml")
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
    # BITS_CONSOLE_SRC is passed via environment so init.sh writes it into .env.
    [[ -n "$BITS_SRC_OVERRIDE" ]] && export BITS_CONSOLE_SRC="$BITS_SRC_OVERRIDE"

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
    local sw="${SOFTWARE_ROOT:-$TESTBED_ROOT/software}"
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

    if $USE_BITS && [[ -z "${BITS_CONSOLE_SRC:-}" ]]; then
        error "--bits requires BITS_CONSOLE_SRC to be set in .env or via --bits-src"
        exit 1
    fi

    # ── Build and launch ───────────────────────────────────────────────────────
    info "Building images (if needed) ..."
    run_compose build --parallel

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
            "http://localhost:8080/api/v1/version" \
            "http://localhost:4929/api/v1/meta/info" \
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
    _check_http "cvmfs-prepub API"  "http://localhost:8080/api/v1/version"  || _status_ok=false
    _check_http "gateway"           "http://localhost:4929/api/v1/meta/info" || _status_ok=false
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
    section "Running smoke test"
    load_env
    run_compose exec publisher /scripts/smoke-test.sh
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
    read -rp "Continue? [y/N] " confirm
    [[ "${confirm,,}" == "y" ]] || { info "Aborted"; exit 0; }

    run_compose down -v --remove-orphans || true

    if [[ -n "${TESTBED_ROOT:-}" ]]; then
        local env_file
        env_file="$(_env_file)"
        for subdir in data config cvmfs; do
            if [[ -d "$TESTBED_ROOT/$subdir" ]]; then
                info "Removing $TESTBED_ROOT/$subdir ..."
                sudo rm -rf "${TESTBED_ROOT:?}/$subdir"
            fi
        done
        info "Removing $env_file ..."
        rm -f "$env_file"
        ok "State removed"
    else
        warn "TESTBED_ROOT not set — skipped host directory removal"
    fi
}

cmd_reset() {
    cmd_clean
    _env_loaded=false  # force fresh load after clean wipes .env
    cmd_init
    _env_loaded=false  # force fresh load after init writes new .env
    cmd_start
}

cmd_help() {
    # Print the file-header comment block (lines 2+ that start with #).
    # Skip line 1 (the shebang) by anchoring the range to '# testbed.sh —'.
    sed -n '/^# testbed\.sh —/,/^[^#]/p' "${BASH_SOURCE[0]}" \
        | grep '^#' | sed 's/^# \?//'
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
case "$CMD" in
    init)           cmd_init ;;
    start)          cmd_start ;;
    stop)           cmd_stop ;;
    restart)        cmd_restart ;;
    status)         cmd_status ;;
    logs)           cmd_logs ;;
    test)           cmd_test ;;
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
