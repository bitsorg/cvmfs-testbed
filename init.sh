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
        --software-root)   SOFTWARE_ROOT_ARG="$2"; shift 2 ;;
        --software-root=*) SOFTWARE_ROOT_ARG="${1#*=}"; shift ;;
        --testbed-root)    TESTBED_ROOT_ARG="$2"; shift 2 ;;
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
    REPO_NAME="${REPO_NAME:-test.cvmfs.io}"
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
    # SOFTWARE_ROOT uses the resolved value (honours --software-root override).
    sed \
        -e "s|^TESTBED_ROOT=.*|TESTBED_ROOT=$TESTBED_ROOT|" \
        -e "s|^SOFTWARE_ROOT=.*|SOFTWARE_ROOT=$SOFTWARE_ROOT|" \
        -e "s|^REPO_NAME=.*|REPO_NAME=$REPO_NAME|" \
        -e "s|^CVMFS_GATEWAY_SECRET=|CVMFS_GATEWAY_SECRET=$CVMFS_GATEWAY_SECRET|" \
        -e "s|^PREPUB_API_TOKEN=|PREPUB_API_TOKEN=$PREPUB_API_TOKEN|" \
        -e "s|^PREPUB_HMAC_SECRET=|PREPUB_HMAC_SECRET=$PREPUB_HMAC_SECRET|" \
        -e "s|^CVMFS_GATEWAY_KEY_ID=.*|CVMFS_GATEWAY_KEY_ID=$CVMFS_GATEWAY_KEY_ID|" \
        -e "s|^GITEA_ADMIN_USER=.*|GITEA_ADMIN_USER=$GITEA_ADMIN_USER|" \
        -e "s|^GITEA_ADMIN_PASSWORD=|GITEA_ADMIN_PASSWORD=$GITEA_ADMIN_PASSWORD|" \
        -e "s|^GITEA_SECRET_KEY=|GITEA_SECRET_KEY=$GITEA_SECRET_KEY|" \
        -e "s|^GITEA_INTERNAL_TOKEN=|GITEA_INTERNAL_TOKEN=$GITEA_INTERNAL_TOKEN|" \
        -e "s|^BITS_CONSOLE_SRC=.*|BITS_CONSOLE_SRC=${BITS_CONSOLE_SRC:-}|" \
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
if [[ -f "$TESTBED_ROOT/cvmfs/$REPO_NAME/.cvmfspublished" ]]; then
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
        # That automount is used by the CVMFS client and must be stopped first.
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
        info "Running: sudo $CVMFS_SERVER_BIN mkfs -w http://stratum0/cvmfs/$REPO_NAME -o $USER $REPO_NAME"
        # sudo strips PATH by default; pass CVMFS_SERVER_BIN as an explicit path.
        if sudo "$CVMFS_SERVER_BIN" mkfs \
                -w "http://stratum0/cvmfs/$REPO_NAME" \
                -o "$USER" "$REPO_NAME"; then
            # Copy signing keys produced by mkfs into our config tree.
            for _keyfile in \
                "/etc/cvmfs/keys/$REPO_NAME.crt" \
                "/etc/cvmfs/keys/$REPO_NAME.key" \
                "/etc/cvmfs/keys/master.pub"; do
                if [[ -f "$_keyfile" ]]; then
                    sudo cp "$_keyfile" "$TESTBED_ROOT/config/keys/"
                    sudo chown "$USER:$USER" "$TESTBED_ROOT/config/keys/$(basename "$_keyfile")"
                fi
            done
            sudo chown -R "$USER:$USER" "$TESTBED_ROOT/cvmfs/$REPO_NAME"
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
echo ""
echo "──────────────────────────────────────────────────────────"
echo "  NEXT STEPS — core testbed"
echo "──────────────────────────────────────────────────────────"
echo ""
echo "1. Ensure binaries are in SOFTWARE_ROOT:"
echo "   ls -1 $SOFTWARE_ROOT"
echo "   # must contain: cvmfs-prepub  cvmfs_gateway  cvmfs2  cvmfs_talk"
echo "   chmod +x $SOFTWARE_ROOT/*"
echo ""
echo "2. Start containers:"
echo "   cd $SCRIPT_DIR"
echo "   ./testbed.sh start"
echo ""
echo "   Or with MQTT control-plane:"
echo "   ./testbed.sh start --mqtt"
echo ""
echo "3. Run smoke test:"
echo "   ./testbed.sh test"
echo ""
echo "4. Verify end-to-end file visibility after a publish job:"
echo "   ./testbed.sh verify <job-uuid> usr/share/test/hello.txt"
echo ""
echo "5. Open Grafana (core stack):"
echo "   http://localhost:${GRAFANA_PORT}  (admin / admin)"
echo ""
echo "6. Query cvmfs-prepub API directly:"
echo "   curl -s -H 'Authorization: Bearer ${PREPUB_API_TOKEN}' \\"
echo "        http://localhost:8080/api/v1/metrics"
echo ""
if [[ -n "${BITS_CONSOLE_SRC:-}" ]]; then
echo "──────────────────────────────────────────────────────────"
echo "  NEXT STEPS — bits-console overlay (Gitea + act_runner)"
echo "──────────────────────────────────────────────────────────"
echo ""
echo "7. Start with the bits overlay:"
echo "   ./testbed.sh start --bits"
echo "   (Seeder container prints the act_runner registration token on first run.)"
echo ""
echo "8. Register act_runner on this host (requires Docker group access):"
echo "   sudo cp $SCRIPT_DIR/act_runner/act_runner.service /etc/systemd/system/"
echo "   sudo mkdir -p /var/lib/act_runner /etc/act_runner"
echo "   sudo cp $SCRIPT_DIR/act_runner/config.yaml /etc/act_runner/"
echo "   act_runner register \\"
echo "     --instance http://localhost:3000 \\"
echo "     --token <TOKEN_FROM_SEEDER> \\"
echo "     --name bits-host-runner \\"
echo "     --labels self-hosted,bits,ubuntu-latest \\"
echo "     --no-interactive"
echo "   sudo systemctl daemon-reload && sudo systemctl enable --now act_runner"
echo ""
echo "9. Open bits-console:"
echo "   http://testbed.localhost:3000/bits-project/testbed/"
echo "   (Add '127.0.0.1 testbed.localhost' to /etc/hosts if needed.)"
echo ""
fi
