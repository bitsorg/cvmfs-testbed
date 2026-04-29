#!/usr/bin/env bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

success() {
    echo -e "${GREEN}[OK]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

check_command() {
    local cmd=$1
    local name=${2:-$cmd}
    if ! command -v $cmd &> /dev/null;
    then
        error "$name not found. Please install it first."
        return 1
    fi
}

# Check prerequisites
info "Checking prerequisites..."
check_command "docker" "Docker"
check_command "docker compose" "Docker Compose" || check_command "docker-compose" "Docker Compose"
check_command "openssl" "OpenSSL"
# cvmfs_server may live outside PATH (e.g. /opt/cvmfs/bin/)
CVMFS_SERVER_BIN=""
for _p in "$(command -v cvmfs_server 2>/dev/null)" /opt/cvmfs/bin/cvmfs_server /usr/bin/cvmfs_server /usr/local/bin/cvmfs_server; do
    [[ -x "$_p" ]] && { CVMFS_SERVER_BIN="$_p"; break; }
done
if [[ -z "$CVMFS_SERVER_BIN" ]]; then
    error "cvmfs_server not found in PATH or /opt/cvmfs/bin. Please install CVMFS server tools."
    exit 1
fi
success "All prerequisites found (cvmfs_server: $CVMFS_SERVER_BIN)"

# Check optional prerequisites for the bits overlay
BITS_OVERLAY=false
if command -v act_runner &> /dev/null; then
    success "act_runner found (bits overlay supported)"
    BITS_OVERLAY=true
else
    warn "act_runner not found — bits-console overlay will not be fully functional"
    warn "Install act_runner from https://gitea.com/gitea/act_runner/releases"
fi

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Determine TESTBED_ROOT early (before we know where .env lives) ─────────────
# Priority: environment variable > existing .env in TESTBED_ROOT > prompt
TESTBED_ROOT="${TESTBED_ROOT:-$HOME/cvmfs-testbed}"
if [[ -z "${TESTBED_ROOT:-}" ]]; then
    read -p "Enter TESTBED_ROOT [$HOME/cvmfs-testbed]: " TESTBED_ROOT
    TESTBED_ROOT="${TESTBED_ROOT:-$HOME/cvmfs-testbed}"
fi

# .env lives in TESTBED_ROOT, not next to the script (the script dir may be read-only)
ENV_FILE="$TESTBED_ROOT/.env"

# Load existing .env if present
if [[ -f "$ENV_FILE" ]]; then
    info "Loading existing .env from $ENV_FILE"
    source "$ENV_FILE"
else
    info "No .env found; will create $ENV_FILE"
    REPO_NAME="${REPO_NAME:-test.cvmfs.io}"
fi

if [[ -z "${REPO_NAME:-}" ]]; then
    read -p "Enter REPO_NAME [test.cvmfs.io]: " REPO_NAME
    REPO_NAME="${REPO_NAME:-test.cvmfs.io}"
fi

info "TESTBED_ROOT: $TESTBED_ROOT"
info "REPO_NAME:    $REPO_NAME"
info ".env file:    $ENV_FILE"

# Create directory tree (must happen before writing .env there)
info "Creating directory structure..."
mkdir -p "$TESTBED_ROOT/software"
mkdir -p "$TESTBED_ROOT/cvmfs"
mkdir -p "$TESTBED_ROOT/data/spool"
mkdir -p "$TESTBED_ROOT/data/s1a"
mkdir -p "$TESTBED_ROOT/data/s1b"
mkdir -p "$TESTBED_ROOT/data/monitoring/vm"
mkdir -p "$TESTBED_ROOT/data/monitoring/vmagent"
mkdir -p "$TESTBED_ROOT/data/monitoring/grafana"
mkdir -p "$TESTBED_ROOT/data/cvmfs-client"
mkdir -p "$TESTBED_ROOT/data/mosquitto"
mkdir -p "$TESTBED_ROOT/data/mosquitto-log"
mkdir -p "$TESTBED_ROOT/data/gitea"
mkdir -p "$TESTBED_ROOT/config/gateway"
mkdir -p "$TESTBED_ROOT/config/keys"
mkdir -p "$TESTBED_ROOT/config/cvmfs-prepub"
mkdir -p "$TESTBED_ROOT/config/stratum1-a"
mkdir -p "$TESTBED_ROOT/config/stratum1-b"
success "Directory structure created"

# Validate BITS_CONSOLE_SRC if provided
if [[ -z "${BITS_CONSOLE_SRC:-}" ]]; then
    warn "BITS_CONSOLE_SRC not set — bits-console overlay (Gitea/act_runner) will be skipped."
    warn "Set BITS_CONSOLE_SRC in $ENV_FILE or pass it on the command line to enable it."
fi

# Generate secrets if not present
info "Handling secrets..."
if [[ ! -f "$ENV_FILE" ]] || [[ -z "${CVMFS_GATEWAY_SECRET:-}" ]]; then
    CVMFS_GATEWAY_SECRET=$(openssl rand -hex 32)
    PREPUB_API_TOKEN=$(openssl rand -hex 24)
    PREPUB_HMAC_SECRET=$(openssl rand -hex 32)
    CVMFS_GATEWAY_KEY_ID="prepub-key"

    # Gitea secrets
    GITEA_ADMIN_PASSWORD=$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c 20)
    GITEA_SECRET_KEY=$(openssl rand -hex 32)
    GITEA_INTERNAL_TOKEN=$(openssl rand -hex 32)

    sed \
        -e "s|^TESTBED_ROOT=.*|TESTBED_ROOT=$TESTBED_ROOT|" \
        -e "s|^SOFTWARE_ROOT=.*|SOFTWARE_ROOT=$TESTBED_ROOT/software|" \
        -e "s|^REPO_NAME=.*|REPO_NAME=$REPO_NAME|" \
        -e "s|^CVMFS_GATEWAY_SECRET=|CVMFS_GATEWAY_SECRET=$CVMFS_GATEWAY_SECRET|" \
        -e "s|^PREPUB_API_TOKEN=|PREPUB_API_TOKEN=$PREPUB_API_TOKEN|" \
        -e "s|^PREPUB_HMAC_SECRET=|PREPUB_HMAC_SECRET=$PREPUB_HMAC_SECRET|" \
        -e "s|^GITEA_ADMIN_USER=.*|GITEA_ADMIN_USER=gitea-admin|" \
        -e "s|^GITEA_ADMIN_PASSWORD=|GITEA_ADMIN_PASSWORD=$GITEA_ADMIN_PASSWORD|" \
        -e "s|^GITEA_SECRET_KEY=|GITEA_SECRET_KEY=$GITEA_SECRET_KEY|" \
        -e "s|^GITEA_INTERNAL_TOKEN=|GITEA_INTERNAL_TOKEN=$GITEA_INTERNAL_TOKEN|" \
        -e "s|^BITS_CONSOLE_SRC=.*|BITS_CONSOLE_SRC=${BITS_CONSOLE_SRC:-}|" \
        "$SCRIPT_DIR/.env.example" > "$ENV_FILE"
    success "Generated secrets and wrote $ENV_FILE"
else
    warn "Reusing existing secrets from $ENV_FILE"
fi

# Source the .env to get all values
source "$ENV_FILE"

# ── Write service configs first ───────────────────────────────────────────────
# These are independent of the CVMFS repo and must exist before containers start.

# Write gateway config
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

success "Gateway config written"

# Write cvmfs-prepub config
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

success "cvmfs-prepub config written"

# Write stratum1-a config
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

success "stratum1-a config written"

# Write stratum1-b config
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

success "stratum1-b config written"

# ── Initialize CVMFS repository ───────────────────────────────────────────────
# This step requires cvmfs_server and a writable /srv (for the symlink).
# If it fails the configs above are already written; containers that don't need
# the CVMFS repo (gateway, monitoring, etc.) will still start correctly.
info "Checking CVMFS repository..."
if [[ -f "$TESTBED_ROOT/cvmfs/$REPO_NAME/.cvmfspublished" ]]; then
    success "CVMFS repository already initialized"
else
    info "Initializing CVMFS repository..."

    # Create /srv/cvmfs symlink if needed.
    # Skip gracefully when /srv is read-only (common on immutable distros).
    CVMFS_REPO_INIT_OK=true
    if [[ ! -L "/srv/cvmfs" ]]; then
        if [[ -d "/srv/cvmfs" ]]; then
            warn "/srv/cvmfs exists and is not a symlink — skipping repo init."
            warn "Remove /srv/cvmfs or use a different TESTBED_ROOT, then re-run init."
            CVMFS_REPO_INIT_OK=false
        elif ! sudo ln -s "$TESTBED_ROOT/cvmfs" /srv/cvmfs 2>/dev/null; then
            warn "Cannot create /srv/cvmfs symlink (/srv is read-only)."
            warn "CVMFS repository init skipped. Run manually when /srv is writable."
            CVMFS_REPO_INIT_OK=false
        else
            info "Created symlink /srv/cvmfs → $TESTBED_ROOT/cvmfs"
        fi
    fi

    if $CVMFS_REPO_INIT_OK; then
        info "Running: sudo $CVMFS_SERVER_BIN mkfs -I -w http://stratum0/cvmfs/$REPO_NAME -o $USER $REPO_NAME"
        if sudo "$CVMFS_SERVER_BIN" mkfs -I -w "http://stratum0/cvmfs/$REPO_NAME" -o "$USER" "$REPO_NAME"; then
            # Copy signing keys
            for keyfile in "/etc/cvmfs/keys/$REPO_NAME.crt" "/etc/cvmfs/keys/$REPO_NAME.key" "/etc/cvmfs/keys/master.pub"; do
                if [[ -f "$keyfile" ]]; then
                    sudo cp "$keyfile" "$TESTBED_ROOT/config/keys/"
                    sudo chown "$USER:$USER" "$TESTBED_ROOT/config/keys/$(basename "$keyfile")"
                fi
            done
            sudo chown -R "$USER:$USER" "$TESTBED_ROOT/cvmfs/$REPO_NAME"
            success "CVMFS repository initialized"
        else
            warn "cvmfs_server mkfs failed — you may need to run it manually."
        fi
    fi
fi

# Print summary
echo ""
echo "========================================================"
echo "  CVMFS-Prepub Testbed Initialization"
echo "========================================================"
echo "  Testbed root:         $TESTBED_ROOT"
echo "  Repository:           $REPO_NAME"
echo "  API Token (prepub):   ${PREPUB_API_TOKEN:0:16}..."
echo "  Gitea admin user:     ${GITEA_ADMIN_USER:-gitea-admin}"
echo "  Gitea admin password: ${GITEA_ADMIN_PASSWORD:0:8}..."
echo "========================================================"
echo ""
echo "──────────────────────────────────────────────────────"
echo "  CORE TESTBED (cvmfs-prepub + gateway + monitoring)"
echo "──────────────────────────────────────────────────────"
echo ""
echo "1. Copy binaries to $TESTBED_ROOT/software/"
echo "   cp /path/to/cvmfs-prepub      $TESTBED_ROOT/software/"
echo "   cp /path/to/cvmfs_gateway     $TESTBED_ROOT/software/"
echo "   cp /path/to/cvmfs2            $TESTBED_ROOT/software/"
echo "   cp /path/to/cvmfs_talk        $TESTBED_ROOT/software/"
echo "   chmod +x $TESTBED_ROOT/software/*"
echo ""
echo "2. Start containers (HTTP control-plane — default):"
echo "   cd $SCRIPT_DIR"
echo "   docker compose up -d"
echo ""
echo "   OR with MQTT control-plane:"
echo "   docker compose -f docker-compose.yml -f docker-compose.mqtt.yml up -d"
echo ""
echo "3. Run smoke test:"
echo "   docker compose exec publisher /scripts/smoke-test.sh"
echo ""
echo "4. Verify end-to-end file visibility:"
echo "   JOB_ID=<uuid returned by smoke test>"
echo "   docker compose exec cvmfs-client verify-publish.sh \$JOB_ID usr/share/test/hello.txt"
echo ""
echo "5. Open Grafana:"
echo "   http://localhost:3001  (admin / admin)"
echo ""
echo "6. Access cvmfs-prepub API:"
echo "   curl -s -H 'Authorization: Bearer $PREPUB_API_TOKEN' http://localhost:8080/api/v1/metrics"
echo ""
echo "──────────────────────────────────────────────────────"
echo "  BITS-CONSOLE OVERLAY (Gitea + act_runner)"
echo "──────────────────────────────────────────────────────"
echo ""
echo "7. Set BITS_CONSOLE_SRC in .env, then start the overlay:"
echo "   edit $SCRIPT_DIR/.env  # set BITS_CONSOLE_SRC=/path/to/bits-console"
echo "   docker compose -f docker-compose.yml -f docker-compose.bits.yml up -d"
echo ""
echo "   The seeder will print the act_runner registration token."
echo ""
echo "8. Register act_runner on this host (requires Docker group membership):"
echo "   sudo cp act_runner/act_runner.service /etc/systemd/system/"
echo "   sudo mkdir -p /var/lib/act_runner /etc/act_runner"
echo "   sudo cp act_runner/config.yaml /etc/act_runner/config.yaml"
echo "   act_runner register \\"
echo "     --instance http://localhost:3000 \\"
echo "     --token <TOKEN_FROM_SEEDER> \\"
echo "     --name bits-host-runner \\"
echo "     --labels self-hosted,bits,ubuntu-latest \\"
echo "     --no-interactive"
echo "   sudo systemctl daemon-reload"
echo "   sudo systemctl enable --now act_runner"
echo ""
echo "9. Open bits-console in a browser:"
echo "   http://testbed.localhost:3000/bits-project/testbed/"
echo "   (Safari: add '127.0.0.1 testbed.localhost' to /etc/hosts)"
echo ""
