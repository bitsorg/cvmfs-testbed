#!/usr/bin/env bash
# init.sh — One-time host setup for the cvmfs-prepub testbed.
#
# What it does (in order):
#   1. Parse command-line arguments.
#   2. Determine TESTBED_ROOT and locate .env (in TESTBED_ROOT, not next to
#      this script — the script directory may be read-only).
#   3. Load existing .env so SOFTWARE_ROOT and other overrides are available
#      before PATH is modified.
#   4. Apply --software-root / --testbed-root overrides over .env values.
#   5. Prepend SOFTWARE_ROOT to PATH (locally built binaries win over system ones).
#   6. Check prerequisites (docker, openssl, cvmfs_server).
#   7. Create directory tree under TESTBED_ROOT.
#   8. Generate secrets and write .env (idempotent — reuses existing secrets).
#   9. Write all service config files (gateway, cvmfs-prepub, stratum1-a/b).
#  10. Optionally initialise the CVMFS repository via cvmfs_server mkfs.
#
# Usage:
#   ./init.sh [--testbed-root PATH] [--software-root PATH]
#
# Options:
#   --testbed-root PATH   Root directory for testbed data (default: $HOME/cvmfs-testbed).
#                         Overrides the TESTBED_ROOT environment variable and any
#                         value already in .env.
#   --software-root PATH  Directory containing the CVMFS binaries under test
#                         (cvmfs_gateway, cvmfs-prepub, cvmfs2, cvmfs_talk,
#                         optionally cvmfs_server).
#                         Overrides SOFTWARE_ROOT from .env.
#                         Default: $TESTBED_ROOT/software
#
# Environment variables (all can also be set in .env):
#   TESTBED_ROOT          See --testbed-root above.
#   SOFTWARE_ROOT         See --software-root above.
#   REPO_NAME             CVMFS repository FQDN (default: test.cvmfs.io).
#   BITS_CONSOLE_SRC      Path to checked-out bits-console source tree.
#                         Required only for the Gitea/bits overlay.
#
# Idempotency:
#   Re-running init.sh is safe.  Secrets are reused if .env already contains
#   CVMFS_GATEWAY_SECRET.  Config files are always overwritten from templates.
#   The CVMFS repository is only initialised if .cvmfspublished is absent.

set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERR ]${NC}  $*"; }

# ── Argument parsing ──────────────────────────────────────────────────────────
SOFTWARE_ROOT_ARG=""
TESTBED_ROOT_ARG=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --software-root)
            [[ $# -ge 2 ]] || { error "--software-root requires a value"; exit 1; }
            SOFTWARE_ROOT_ARG="$2"; shift 2 ;;
        --software-root=*) SOFTWARE_ROOT_ARG="${1#*=}"; shift ;;
        --testbed-root)
            [[ $# -ge 2 ]] || { error "--testbed-root requires a value"; exit 1; }
            TESTBED_ROOT_ARG="$2"; shift 2 ;;
        --testbed-root=*)  TESTBED_ROOT_ARG="${1#*=}"; shift ;;
        *)                 shift ;;   # silently skip unknown flags from testbed.sh
    esac
done

# ── Script location ───────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Determine TESTBED_ROOT ────────────────────────────────────────────────────
# Priority: command-line arg > environment variable > $HOME default.
TESTBED_ROOT="${TESTBED_ROOT_ARG:-${TESTBED_ROOT:-$HOME/cvmfs-testbed}}"

# .env lives in TESTBED_ROOT — the script directory may be read-only.
ENV_FILE="$TESTBED_ROOT/.env"

# ── Load existing .env before touching PATH ───────────────────────────────────
# This makes SOFTWARE_ROOT (and all other settings) available immediately.
if [[ -f "$ENV_FILE" ]]; then
    info "Loading existing .env from $ENV_FILE"
    # shellcheck source=/dev/null
    source "$ENV_FILE"
else
    info "No .env found at $ENV_FILE — will create it."
    # Do NOT default REPO_NAME here; let the interactive prompt below fire
    # so the user can choose a custom repository FQDN on first run.
fi

# ── Apply command-line overrides (highest priority) ───────────────────────────
[[ -n "$TESTBED_ROOT_ARG"   ]] && TESTBED_ROOT="$TESTBED_ROOT_ARG"
[[ -n "$SOFTWARE_ROOT_ARG"  ]] && SOFTWARE_ROOT="$SOFTWARE_ROOT_ARG"

# ── Resolve SOFTWARE_ROOT ─────────────────────────────────────────────────────
SOFTWARE_ROOT="${SOFTWARE_ROOT:-$TESTBED_ROOT/software}"

# Prompt for REPO_NAME only if still unset (not in .env, not in environment).
if [[ -z "${REPO_NAME:-}" ]]; then
    read -rp "Enter REPO_NAME [test.cvmfs.io]: " REPO_NAME
    REPO_NAME="${REPO_NAME:-test.cvmfs.io}"
fi

info "TESTBED_ROOT:  $TESTBED_ROOT"
info "SOFTWARE_ROOT: $SOFTWARE_ROOT"
info "REPO_NAME:     $REPO_NAME"
info ".env file:     $ENV_FILE"

# ── Prepend SOFTWARE_ROOT to PATH ─────────────────────────────────────────────
# Locally built binaries must shadow any system-wide CVMFS installation.
if [[ ":$PATH:" != *":$SOFTWARE_ROOT:"* ]]; then
    export PATH="$SOFTWARE_ROOT:$PATH"
    info "PATH prepended with $SOFTWARE_ROOT"
fi

# ── Check prerequisites ───────────────────────────────────────────────────────
info "Checking prerequisites..."
_require() {
    local cmd="$1" label="${2:-$1}"
    if ! command -v "$cmd" &>/dev/null; then
        error "$label not found in PATH. Please install it first."
        exit 1
    fi
}
_require docker   "Docker"
# Accept either "docker compose" (plugin) or the legacy "docker-compose" binary.
if ! docker compose version &>/dev/null 2>&1; then
    _require docker-compose "Docker Compose"
fi
_require openssl "OpenSSL"

# cvmfs_server may be in SOFTWARE_ROOT (already in PATH) or in standard locations.
CVMFS_SERVER_BIN=""
for _p in \
    "$(command -v cvmfs_server 2>/dev/null || true)" \
    /opt/cvmfs/bin/cvmfs_server \
    /usr/bin/cvmfs_server \
    /usr/local/bin/cvmfs_server; do
    [[ -n "$_p" && -x "$_p" ]] && { CVMFS_SERVER_BIN="$_p"; break; }
done
if [[ -z "$CVMFS_SERVER_BIN" ]]; then
    error "cvmfs_server not found in PATH, $SOFTWARE_ROOT, or standard locations."
    error "Install CVMFS server tools or place cvmfs_server in $SOFTWARE_ROOT."
    exit 1
fi
success "Prerequisites OK  (cvmfs_server: $CVMFS_SERVER_BIN)"

# Check optional act_runner for the bits overlay.
if command -v act_runner &>/dev/null; then
    success "act_runner found — bits overlay fully supported."
else
    warn "act_runner not found — bits-console overlay will not run CI jobs."
    warn "Install from: https://gitea.com/gitea/act_runner/releases"
fi

# ── Create directory tree ─────────────────────────────────────────────────────
info "Creating directory structure under $TESTBED_ROOT ..."
mkdir -p \
    "$TESTBED_ROOT/software" \
    "$TESTBED_ROOT/cvmfs" \
    "$TESTBED_ROOT/data/spool" \
    "$TESTBED_ROOT/data/s1a" \
    "$TESTBED_ROOT/data/s1b" \
    "$TESTBED_ROOT/data/monitoring/vm" \
    "$TESTBED_ROOT/data/monitoring/vmagent" \
    "$TESTBED_ROOT/data/monitoring/grafana" \
    "$TESTBED_ROOT/data/cvmfs-client" \
    "$TESTBED_ROOT/data/mosquitto" \
    "$TESTBED_ROOT/data/mosquitto-log" \
    "$TESTBED_ROOT/data/gitea" \
    "$TESTBED_ROOT/config/gateway" \
    "$TESTBED_ROOT/config/keys" \
    "$TESTBED_ROOT/config/cvmfs-prepub" \
    "$TESTBED_ROOT/config/stratum1-a" \
    "$TESTBED_ROOT/config/stratum1-b"
success "Directory structure created."

# Warn (do not fail) if BITS_CONSOLE_SRC is missing — it is optional.
if [[ -z "${BITS_CONSOLE_SRC:-}" ]]; then
    warn "BITS_CONSOLE_SRC not set — Gitea/bits overlay will be skipped."
    warn "Set it in $ENV_FILE or pass --bits-src to testbed.sh."
fi

# ── Generate secrets and write .env ──────────────────────────────────────────
# Idempotent: if CVMFS_GATEWAY_SECRET is already set (loaded from .env above),
# the existing secrets are reused and .env is not rewritten.
info "Handling secrets..."
if [[ -z "${CVMFS_GATEWAY_SECRET:-}" ]]; then
    CVMFS_GATEWAY_SECRET=$(openssl rand -hex 32)
    PREPUB_API_TOKEN=$(openssl rand -hex 24)
    PREPUB_HMAC_SECRET=$(openssl rand -hex 32)
    CVMFS_GATEWAY_KEY_ID="prepub-key"

    # Gitea secrets — use hex to avoid the head/tr/SIGPIPE problem under pipefail.
    GITEA_ADMIN_PASSWORD=$(openssl rand -hex 10)   # 20 hex chars, always safe
    GITEA_SECRET_KEY=$(openssl rand -hex 32)
    GITEA_INTERNAL_TOKEN=$(openssl rand -hex 32)
    GITEA_ADMIN_USER="${GITEA_ADMIN_USER:-gitea-admin}"

    # Write .env from template, substituting all known variables.
    # Use awk instead of sed: awk's gsub replacement is literal, so values
    # containing '|', '&', '\', or '/' cannot corrupt the substitution.
    awk \
        -v TESTBED_ROOT="$TESTBED_ROOT" \
        -v SOFTWARE_ROOT="$SOFTWARE_ROOT" \
        -v REPO_NAME="$REPO_NAME" \
        -v CVMFS_GATEWAY_SECRET="$CVMFS_GATEWAY_SECRET" \
        -v PREPUB_API_TOKEN="$PREPUB_API_TOKEN" \
        -v PREPUB_HMAC_SECRET="$PREPUB_HMAC_SECRET" \
        -v CVMFS_GATEWAY_KEY_ID="$CVMFS_GATEWAY_KEY_ID" \
        -v GITEA_ADMIN_USER="$GITEA_ADMIN_USER" \
        -v GITEA_ADMIN_PASSWORD="$GITEA_ADMIN_PASSWORD" \
        -v GITEA_SECRET_KEY="$GITEA_SECRET_KEY" \
        -v GITEA_INTERNAL_TOKEN="$GITEA_INTERNAL_TOKEN" \
        -v BITS_CONSOLE_SRC="${BITS_CONSOLE_SRC:-}" \
        'BEGIN { FS="="; OFS="=" }
         /^TESTBED_ROOT=/          { $2=TESTBED_ROOT;          print; next }
         /^SOFTWARE_ROOT=/         { $2=SOFTWARE_ROOT;         print; next }
         /^REPO_NAME=/             { $2=REPO_NAME;             print; next }
         /^CVMFS_GATEWAY_SECRET=$/ { $2=CVMFS_GATEWAY_SECRET;  print; next }
         /^PREPUB_API_TOKEN=$/     { $2=PREPUB_API_TOKEN;      print; next }
         /^PREPUB_HMAC_SECRET=$/   { $2=PREPUB_HMAC_SECRET;    print; next }
         /^CVMFS_GATEWAY_KEY_ID=/  { $2=CVMFS_GATEWAY_KEY_ID;  print; next }
         /^GITEA_ADMIN_USER=/      { $2=GITEA_ADMIN_USER;      print; next }
         /^GITEA_ADMIN_PASSWORD=$/ { $2=GITEA_ADMIN_PASSWORD;  print; next }
         /^GITEA_SECRET_KEY=$/     { $2=GITEA_SECRET_KEY;      print; next }
         /^GITEA_INTERNAL_TOKEN=$/ { $2=GITEA_INTERNAL_TOKEN;  print; next }
         /^BITS_CONSOLE_SRC=/      { $2=BITS_CONSOLE_SRC;      print; next }
         { print }' \
        "$SCRIPT_DIR/.env.example" > "$ENV_FILE"
    success "Generated secrets and wrote $ENV_FILE"
else
    warn "Reusing existing secrets from $ENV_FILE"
fi

# Re-source .env so any newly written values are available for config templates.
# shellcheck source=/dev/null
source "$ENV_FILE"

# ── Write service config files ────────────────────────────────────────────────
# Done unconditionally — always re-written from templates so they stay in sync
# with the current TESTBED_ROOT, REPO_NAME, and gateway secret.

info "Writing gateway config..."
cat > "$TESTBED_ROOT/config/gateway/gw.json" <<EOF
{
  "version": 2,
  "port": 4929,
  "max_lease_time": 7200,
  "log_level": "info"
}
EOF

cat > "$TESTBED_ROOT/config/gateway/user.json" <<EOF
{
  "version": 2,
  "users": [
    {
      "name": "prepub",
      "key_id": "prepub-key",
      "secret": "$CVMFS_GATEWAY_SECRET"
    }
  ]
}
EOF

cat > "$TESTBED_ROOT/config/gateway/repo.json" <<EOF
{
  "version": 2,
  "repos": [
    {
      "domain": "$REPO_NAME",
      "keys": [
        {
          "id": "prepub-key",
          "path": "/"
        }
      ]
    }
  ]
}
EOF
success "Gateway config written."

info "Writing cvmfs-prepub config..."
cat > "$TESTBED_ROOT/config/cvmfs-prepub/config.yaml" <<'EOFCONFIG'
dev: true
log_level: info
spool_root: /data/spool
cas:
  type: localfs
  root: /data/cas
server:
  listen: ":8080"
gateway:
  url: http://gateway:4929
distribution:
  stratum1_endpoints:
    - http://stratum1-a:9100
    - http://stratum1-b:9100
  quorum: 0.5
  timeout: 2m
  commit_anyway: true
EOFCONFIG
success "cvmfs-prepub config written."

info "Writing stratum1-a config..."
cat > "$TESTBED_ROOT/config/stratum1-a/config.yaml" <<'EOFCONFIG'
mode: receiver
dev: true
log_level: info
cas:
  type: localfs
  root: /data/cas
control_addr: ":9100"
data_addr: ":9101"
node_id: "stratum1-a"
EOFCONFIG
success "stratum1-a config written."

info "Writing stratum1-b config..."
cat > "$TESTBED_ROOT/config/stratum1-b/config.yaml" <<'EOFCONFIG'
mode: receiver
dev: true
log_level: info
cas:
  type: localfs
  root: /data/cas
control_addr: ":9100"
data_addr: ":9101"
node_id: "stratum1-b"
EOFCONFIG
success "stratum1-b config written."

# ── Initialise CVMFS repository ───────────────────────────────────────────────
# Requires cvmfs_server and a writable /srv for the symlink.
# Failures here are non-fatal: all config files are already written and
# containers that don't touch the CVMFS repo will start correctly.
info "Checking CVMFS repository..."
# Check both the direct path and via the /srv/cvmfs symlink (they should be the
# same after a successful init, but may differ if TESTBED_ROOT changed).
_repo_published=false
for _rpath in \
    "$TESTBED_ROOT/cvmfs/$REPO_NAME/.cvmfspublished" \
    "/srv/cvmfs/$REPO_NAME/.cvmfspublished"; do
    [[ -f "$_rpath" ]] && { _repo_published=true; break; }
done
if $_repo_published; then
    success "CVMFS repository already initialised."
else
    info "Initialising CVMFS repository..."

    # Determine whether /srv/cvmfs symlink is present and correct.
    CVMFS_REPO_INIT_OK=true
    if [[ -L "/srv/cvmfs" ]]; then
        # Symlink exists — verify it points to our TESTBED_ROOT.
        _target="$(readlink -f /srv/cvmfs)"
        _want="$(readlink -f "$TESTBED_ROOT/cvmfs")"
        if [[ "$_target" != "$_want" ]]; then
            warn "/srv/cvmfs currently points to $_target"
            warn "Expected: $_want"
            read -rp "Remove stale symlink and recreate it? [y/N] " _fix
            if [[ "${_fix,,}" == "y" ]]; then
                if sudo rm /srv/cvmfs && sudo ln -s "$TESTBED_ROOT/cvmfs" /srv/cvmfs; then
                    info "Recreated /srv/cvmfs → $TESTBED_ROOT/cvmfs"
                else
                    warn "Failed to recreate /srv/cvmfs — CVMFS repo init skipped."
                    CVMFS_REPO_INIT_OK=false
                fi
            else
                warn "Skipping CVMFS repo init.  Fix manually with:"
                warn "  sudo rm /srv/cvmfs && sudo ln -s $TESTBED_ROOT/cvmfs /srv/cvmfs"
                CVMFS_REPO_INIT_OK=false
            fi
        else
            info "/srv/cvmfs already points to $TESTBED_ROOT/cvmfs — OK."
        fi
    elif [[ -d "/srv/cvmfs" ]]; then
        warn "/srv/cvmfs exists as a real directory, not a symlink."
        read -rp "Remove it and replace with a symlink? [y/N] " _fix
        if [[ "${_fix,,}" == "y" ]]; then
            if sudo rm -rf /srv/cvmfs && sudo ln -s "$TESTBED_ROOT/cvmfs" /srv/cvmfs; then
                info "Replaced /srv/cvmfs with symlink → $TESTBED_ROOT/cvmfs"
            else
                warn "Failed — CVMFS repo init skipped."
                CVMFS_REPO_INIT_OK=false
            fi
        else
            warn "Skipping CVMFS repo init.  Fix manually with:"
            warn "  sudo rm -rf /srv/cvmfs && sudo ln -s $TESTBED_ROOT/cvmfs /srv/cvmfs"
            CVMFS_REPO_INIT_OK=false
        fi
    elif ! sudo ln -s "$TESTBED_ROOT/cvmfs" /srv/cvmfs 2>/dev/null; then
        warn "Cannot create /srv/cvmfs → $TESTBED_ROOT/cvmfs (/srv may be read-only)."
        warn "CVMFS repository init skipped. Create the symlink manually and re-run:"
        warn "  sudo ln -s $TESTBED_ROOT/cvmfs /srv/cvmfs"
        CVMFS_REPO_INIT_OK=false
    else
        info "Created symlink /srv/cvmfs → $TESTBED_ROOT/cvmfs"
    fi

    if $CVMFS_REPO_INIT_OK; then
        # cvmfs_server mkfs refuses to run when autofs is mounted on /cvmfs.
        if mount | grep -q 'autofs.*on /cvmfs'; then
            warn "autofs is mounted on /cvmfs — cvmfs_server will refuse to run."
            read -rp "Stop autofs now (sudo systemctl stop autofs)? [y/N] " _stop_autofs
            if [[ "${_stop_autofs,,}" == "y" ]]; then
                if sudo systemctl stop autofs 2>/dev/null; then
                    info "autofs stopped."
                else
                    warn "Failed to stop autofs — trying 'sudo umount /cvmfs' instead."
                    sudo umount /cvmfs 2>/dev/null || true
                fi
            else
                warn "Skipping CVMFS repo init. Stop autofs manually and re-run:"
                warn "  sudo systemctl stop autofs"
                CVMFS_REPO_INIT_OK=false
            fi
        fi
    fi

    if $CVMFS_REPO_INIT_OK; then
        # ── Rebuild cvmfs_server from source if the source tree is available ─────
        # cvmfs_server_mkfs.sh honours CVMFS_TESTBED=true to skip Apache vhost
        # setup (the Docker stratum0 container handles serving).  For this to take
        # effect the binary must be rebuilt from the modified source.
        # We look for the source tree relative to this script (common dev layout:
        # cvmfs-testbed/ and cvmfs/ are siblings), and rebuild automatically.
        _cvmfs_src=""
        for _try in \
            "${CVMFS_SRC:-}" \
            "$SCRIPT_DIR/../cvmfs"; do
            if [[ -n "$_try" && -f "$_try/cvmfs/make_cvmfs_server.sh" ]]; then
                _cvmfs_src="$_try"
                break
            fi
        done

        if [[ -n "$_cvmfs_src" ]]; then
            info "Rebuilding cvmfs_server from source: $_cvmfs_src/cvmfs/make_cvmfs_server.sh"
            ( cd "$_cvmfs_src/cvmfs" && ./make_cvmfs_server.sh "$CVMFS_SERVER_BIN" ) \
                && info "cvmfs_server rebuilt → $CVMFS_SERVER_BIN" \
                || warn "Rebuild failed — using existing binary (CVMFS_TESTBED support may be missing)"
        else
            warn "CVMFS source tree not found; cannot rebuild cvmfs_server."
            warn "If cvmfs_server predates the CVMFS_TESTBED patch, mkfs may fail."
            warn "Set CVMFS_SRC=/path/to/cvmfs and re-run, or rebuild manually:"
            warn "  cd /path/to/cvmfs/cvmfs && ./make_cvmfs_server.sh $CVMFS_SERVER_BIN"
        fi

        # ── Copy missing hard-coded binaries to their expected paths ─────────────
        # cvmfs_server mkfs hard-codes /usr/(local/)bin/cvmfs_* paths for some
        # calls and also runs:
        #   setcap cap_sys_admin+ep /usr/bin/cvmfs_swissknife
        # setcap refuses symlinks, so we copy (not symlink) any binary that is
        # absent at its hard-coded location but present in SOFTWARE_ROOT.
        # Copies are removed after mkfs.
        _copied=()
        info "Checking for hard-coded CVMFS binary paths in $CVMFS_SERVER_BIN ..."
        while IFS= read -r _hpath; do
            _bname="$(basename "$_hpath")"
            if [[ ! -e "$_hpath" ]] && [[ -x "$SOFTWARE_ROOT/$_bname" ]]; then
                if sudo cp "$SOFTWARE_ROOT/$_bname" "$_hpath" 2>/dev/null; then
                    _copied+=("$_hpath")
                    info "  Copied (temporary): $_hpath ← $SOFTWARE_ROOT/$_bname"
                else
                    warn "Could not copy to $_hpath — mkfs may fail."
                fi
            fi
        done < <(grep -oE '/usr(/local)?/bin/cvmfs_[a-z_]+' "$CVMFS_SERVER_BIN" 2>/dev/null | sort -u || true)

        # ── Clean up any partial registration from a previous failed run ─────────
        if [[ -d "/etc/cvmfs/repositories.d/$REPO_NAME" ]]; then
            warn "Partial repository registration found in /etc/cvmfs/repositories.d/$REPO_NAME"
            warn "Running: sudo $CVMFS_SERVER_BIN rmfs -f $REPO_NAME"
            sudo env PATH="$SOFTWARE_ROOT:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
                "$CVMFS_SERVER_BIN" rmfs -f "$REPO_NAME" 2>/dev/null || true
        fi

        # ── Run mkfs ─────────────────────────────────────────────────────────────
        # CVMFS_TESTBED=true tells cvmfs_server_mkfs to skip Apache vhost setup
        # (configure_apache=0): no reload_apache, no wait_for_apache poll against
        # the Docker-internal stratum0 URL.
        # sudo strips PATH; pass SOFTWARE_ROOT explicitly so bare binary names
        # (e.g. cvmfs_swissknife) resolve correctly alongside the hard-coded paths.
        info "Running: sudo env CVMFS_TESTBED=true PATH=$SOFTWARE_ROOT:... LD_LIBRARY_PATH=$SOFTWARE_ROOT cvmfs_server mkfs -I -w http://stratum0/cvmfs/$REPO_NAME -o $USER $REPO_NAME"
        _mkfs_ok=false
        if sudo env \
                CVMFS_TESTBED=true \
                PATH="$SOFTWARE_ROOT:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
                LD_LIBRARY_PATH="$SOFTWARE_ROOT" \
                "$CVMFS_SERVER_BIN" mkfs -I \
                -w "http://stratum0/cvmfs/$REPO_NAME" \
                -o "$USER" "$REPO_NAME"; then
            _mkfs_ok=true
        fi

        # ── Remove temporary binary copies ────────────────────────────────────────
        if [[ ${#_copied[@]} -gt 0 ]]; then
            info "Removing temporary binary copies ..."
            for _dest in "${_copied[@]}"; do
                sudo rm -f "$_dest" 2>/dev/null || true
            done
        fi

        if $_mkfs_ok; then
            # Copy signing keys produced by mkfs into our config tree.
            for _keyfile in \
                "/etc/cvmfs/keys/$REPO_NAME.crt" \
                "/etc/cvmfs/keys/$REPO_NAME.key" \
                "/etc/cvmfs/keys/master.pub"; do
                if [[ -f "$_keyfile" ]]; then
                    sudo cp "$_keyfile" "$TESTBED_ROOT/config/keys/"
                    sudo chown "$USER:$(id -gn)" "$TESTBED_ROOT/config/keys/$(basename "$_keyfile")"
                else
                    warn "Key file not found after mkfs: $_keyfile"
                    warn "The cvmfs-client container will fail to mount until keys are copied to:"
                    warn "  $TESTBED_ROOT/config/keys/"
                fi
            done
            sudo chown -R "$USER:$(id -gn)" "$TESTBED_ROOT/cvmfs/$REPO_NAME"
            success "CVMFS repository initialised."
        else
            warn "cvmfs_server mkfs failed — check output above."
            warn "Once fixed, re-run: ./testbed.sh init"
        fi
    fi
fi

# ── Print next-steps summary ──────────────────────────────────────────────────
GRAFANA_PORT=3000
[[ -n "${GITEA_ADMIN_PASSWORD:-}" ]] && _BITS_ENABLED=true || _BITS_ENABLED=false
# If the bits overlay is expected, Grafana moves to 3001 (docker-compose.bits.yml).
[[ -n "${BITS_CONSOLE_SRC:-}" ]] && GRAFANA_PORT=3001

echo ""
echo "========================================================"
echo "  CVMFS-Prepub Testbed  —  Initialisation complete"
echo "========================================================"
echo "  Testbed root:         $TESTBED_ROOT"
echo "  Software root:        $SOFTWARE_ROOT"
echo "  .env file:            $ENV_FILE"
echo "  Repository:           $REPO_NAME"
echo "  API token (prepub):   ${PREPUB_API_TOKEN:0:16}...  (see $ENV_FILE for full value)"
if [[ -n "${BITS_CONSOLE_SRC:-}" ]]; then
echo "  Gitea admin user:     ${GITEA_ADMIN_USER:-gitea-admin}"
echo "  Gitea admin password: ${GITEA_ADMIN_PASSWORD:0:8}...  (see $ENV_FILE for full value)"
fi
echo "========================================================"
