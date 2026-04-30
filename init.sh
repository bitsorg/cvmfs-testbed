#!/usr/bin/env bash
# init.sh — One-time host setup for the cvmfs-prepub testbed.
#
# Directory convention (enforced here):
#   <cvmfs-testbed>/cvmfs/          CVMFS source tree  (git clone or symlink)
#   <cvmfs-testbed>/bits-console/   bits-console source (git clone or symlink)
#   <cvmfs-testbed>/software/       built CVMFS binaries (populated by install.sh)
#
# Before running init.sh for the first time:
#   1. Clone / symlink the CVMFS source:
#        git clone https://github.com/cvmfs/cvmfs cvmfs
#        cmake -S cvmfs -B cvmfs/build && make -C cvmfs/build -j$(nproc)
#   2. Run install.sh to populate software/:
#        ./install.sh
#   3. (bits overlay) Clone / symlink bits-console:
#        git clone https://github.com/your-org/bits-console bits-console
#
# What init.sh does (in order):
#   1. Parse command-line arguments.
#   2. Determine TESTBED_ROOT and locate .env (in TESTBED_ROOT, not next to
#      this script — the script directory may be read-only).
#   3. Load existing .env so SOFTWARE_ROOT and other overrides are available
#      before PATH is modified.
#   4. Apply --software-root / --testbed-root overrides over .env values.
#   5. Check that the conventional subdirectories exist (cvmfs/, bits-console/).
#   6. Prepend SOFTWARE_ROOT to PATH (locally built binaries win over system ones).
#   7. Check prerequisites (docker, openssl, cvmfs_server).
#   8. Create directory tree under TESTBED_ROOT.
#   9. Generate secrets and write .env (idempotent — reuses existing secrets).
#  10. Write all service config files (gateway, cvmfs-prepub, stratum1-a/b).
#  11. Run install.sh to (re-)populate software/ from the build tree.
#  12. Optionally initialise the CVMFS repository via cvmfs_server mkfs.
#
# Usage:
#   ./init.sh [--testbed-root PATH] [--software-root PATH]
#
# Options:
#   --testbed-root PATH   Root directory for testbed data (default: $HOME/cvmfs-testbed).
#                         Overrides the TESTBED_ROOT environment variable and any
#                         value already in .env.
#   --software-root PATH  Directory containing the CVMFS binaries under test.
#                         Overrides SOFTWARE_ROOT from .env.
#                         Default: <cvmfs-testbed>/software  (next to this script)
#
# Environment variables (all can also be set in .env):
#   TESTBED_ROOT          See --testbed-root above.
#   SOFTWARE_ROOT         See --software-root above.
#   REPO_NAME             CVMFS repository FQDN (default: test.cvmfs.io).
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
        # --bits-src is no longer needed: bits-console lives at $SCRIPT_DIR/bits-console
        # Accept it silently for backward compatibility with any existing scripts.
        --bits-src|--bits-src=*) shift; [[ "$1" == --bits-src ]] && shift || true ;;
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
# Default: software/ lives next to this script (within the cvmfs-testbed repo),
# not inside TESTBED_ROOT.  This keeps source/binaries together and eliminates
# the need to set SOFTWARE_ROOT in .env.
SOFTWARE_ROOT="${SOFTWARE_ROOT:-$SCRIPT_DIR/software}"

# ── Check conventional subdirectories ────────────────────────────────────────
# cvmfs/ must exist (contains source and build tree used by install.sh).
if [[ ! -d "$SCRIPT_DIR/cvmfs" ]]; then
    warn "CVMFS source not found at $SCRIPT_DIR/cvmfs"
    warn "Clone or symlink it before running install.sh:"
    warn "  git clone https://github.com/cvmfs/cvmfs $SCRIPT_DIR/cvmfs"
    warn "  cmake -S $SCRIPT_DIR/cvmfs -B $SCRIPT_DIR/cvmfs/build"
    warn "  make -C $SCRIPT_DIR/cvmfs/build -j\$(nproc)"
    warn "  $SCRIPT_DIR/install.sh"
fi

# bits-console/ is optional (needed for the --bits overlay only).
BITS_CONSOLE_SRC="$SCRIPT_DIR/bits-console"
if [[ ! -d "$BITS_CONSOLE_SRC" ]]; then
    warn "bits-console source not found at $BITS_CONSOLE_SRC"
    warn "Clone or symlink it if you need the bits/Gitea overlay:"
    warn "  git clone https://github.com/your-org/bits-console $BITS_CONSOLE_SRC"
fi

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
    "$TESTBED_ROOT/repos" \
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

# Directories that are mounted as writable volumes inside containers running
# as non-root users need to be world-writable on the host.  The affected
# services and their in-container UIDs are:
#   cvmfs-prepub / stratum1-a / stratum1-b  — 'prepub' (system UID, ~100-999)
#   grafana                                 — UID 472
#   vmagent / victoriametrics               — UID 1000 (victoriametrics image)
chmod 777 \
    "$TESTBED_ROOT/data/spool" \
    "$TESTBED_ROOT/data/s1a" \
    "$TESTBED_ROOT/data/s1b" \
    "$TESTBED_ROOT/data/monitoring/vm" \
    "$TESTBED_ROOT/data/monitoring/vmagent" \
    "$TESTBED_ROOT/data/monitoring/grafana" \
    "$TESTBED_ROOT/data/cvmfs-client"
success "Directory structure created."

# (BITS_CONSOLE_SRC is derived from the conventional path $SCRIPT_DIR/bits-console
# and has already been checked above — no further action needed here.)

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

# Gateway key file: plain_text format read by LoadKey() in gateway/internal/gateway/keys.go
# Format: "plain_text <key_id> <secret>"
# Mounted into the gateway container at /etc/cvmfs/keys/${REPO_NAME}.gw (read-only via
# the same ${TESTBED_ROOT}/config/keys volume used for signing keys).
cat > "$TESTBED_ROOT/config/keys/$REPO_NAME.gw" <<EOF
plain_text prepub-key $CVMFS_GATEWAY_SECRET
EOF
chmod 600 "$TESTBED_ROOT/config/keys/$REPO_NAME.gw"

# repo.json (access config): maps key IDs to path prefixes per repo, AND registers
# the key secrets (loaded from the .gw file) in the global keystore.
# The top-level "keys" array populates c.Keys[keyID] = {Secret, Admin};
# the per-repo "keys" array populates c.Repositories[repo].Keys[keyID] = path.
# Both are needed — without the top-level entry the HMAC lookup returns "invalid key ID".
cat > "$TESTBED_ROOT/config/gateway/repo.json" <<EOF
{
  "version": 2,
  "keys": [
    {
      "type": "file",
      "file_name": "/etc/cvmfs/keys/$REPO_NAME.gw"
    }
  ],
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
# data_host is the hostname cvmfs-prepub uses to open the data (TCP) channel.
# Must be the Docker service name, not "localhost", to avoid SSRF detection.
data_host: stratum1-a
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
# data_host is the hostname cvmfs-prepub uses to open the data (TCP) channel.
# Must be the Docker service name, not "localhost", to avoid SSRF detection.
data_host: stratum1-b
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
    "$TESTBED_ROOT/repos/$REPO_NAME/.cvmfspublished" \
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
        _want="$(readlink -f "$TESTBED_ROOT/repos")"
        if [[ "$_target" != "$_want" ]]; then
            warn "/srv/cvmfs currently points to $_target"
            warn "Expected: $_want"
            read -rp "Remove stale symlink and recreate it? [y/N] " _fix
            if [[ "${_fix,,}" == "y" ]]; then
                if sudo rm /srv/cvmfs && sudo ln -s "$TESTBED_ROOT/repos" /srv/cvmfs; then
                    info "Recreated /srv/cvmfs → $TESTBED_ROOT/repos"
                else
                    warn "Failed to recreate /srv/cvmfs — CVMFS repo init skipped."
                    CVMFS_REPO_INIT_OK=false
                fi
            else
                warn "Skipping CVMFS repo init.  Fix manually with:"
                warn "  sudo rm /srv/cvmfs && sudo ln -s $TESTBED_ROOT/repos /srv/cvmfs"
                CVMFS_REPO_INIT_OK=false
            fi
        else
            info "/srv/cvmfs already points to $TESTBED_ROOT/repos — OK."
        fi
    elif [[ -d "/srv/cvmfs" ]]; then
        warn "/srv/cvmfs exists as a real directory, not a symlink."
        read -rp "Remove it and replace with a symlink? [y/N] " _fix
        if [[ "${_fix,,}" == "y" ]]; then
            if sudo rm -rf /srv/cvmfs && sudo ln -s "$TESTBED_ROOT/repos" /srv/cvmfs; then
                info "Replaced /srv/cvmfs with symlink → $TESTBED_ROOT/repos"
            else
                warn "Failed — CVMFS repo init skipped."
                CVMFS_REPO_INIT_OK=false
            fi
        else
            warn "Skipping CVMFS repo init.  Fix manually with:"
            warn "  sudo rm -rf /srv/cvmfs && sudo ln -s $TESTBED_ROOT/repos /srv/cvmfs"
            CVMFS_REPO_INIT_OK=false
        fi
    elif ! sudo ln -s "$TESTBED_ROOT/repos" /srv/cvmfs 2>/dev/null; then
        warn "Cannot create /srv/cvmfs → $TESTBED_ROOT/repos (/srv may be read-only)."
        warn "CVMFS repository init skipped. Create the symlink manually and re-run:"
        warn "  sudo ln -s $TESTBED_ROOT/repos /srv/cvmfs"
        CVMFS_REPO_INIT_OK=false
    else
        info "Created symlink /srv/cvmfs → $TESTBED_ROOT/repos"
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
        # ── Rebuild cvmfs_server from patched source via install.sh ─────────────
        # install.sh finds the CVMFS source (cvmfs/ subdir or ../cvmfs sibling),
        # copies cvmfs_* binaries and libcvmfs_* libraries, and rebuilds the
        # cvmfs_server shell script with CVMFS_TESTBED support.
        # Nothing is written to /usr/bin or any system directory.
        # We always run it so the assembled script stays in sync with the patched
        # server/*.sh source files.
        info "Running install.sh to rebuild cvmfs_server from patched source ..."
        if bash "$SCRIPT_DIR/install.sh" --software-root "$SOFTWARE_ROOT"; then
            # install.sh always produces software/cvmfs_server when it succeeds.
            CVMFS_SERVER_BIN="$SOFTWARE_ROOT/cvmfs_server"
        else
            warn "install.sh failed — mkfs will use whatever is already in SOFTWARE_ROOT."
        fi

        # ── Clean up any partial registration from a previous failed run ─────────
        if [[ -d "/etc/cvmfs/repositories.d/$REPO_NAME" ]]; then
            warn "Partial repository registration found in /etc/cvmfs/repositories.d/$REPO_NAME"
            warn "Running: sudo $CVMFS_SERVER_BIN rmfs -f $REPO_NAME"
            sudo env PATH="$SOFTWARE_ROOT:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
                "$CVMFS_SERVER_BIN" rmfs -f "$REPO_NAME" 2>/dev/null || true
        fi

        # ── Run mkfs ─────────────────────────────────────────────────────────────
        # CVMFS_TESTBED=true  — skips Apache vhost setup (cvmfs_server_mkfs.sh).
        # CVMFS_TESTBED_SOFTWARE_ROOT — tells cvmfs_server_{coda,util}.sh where
        #   binaries (cvmfs_publish, cvmfs_swissknife) and libraries live, so
        #   setcap runs on the real files in SOFTWARE_ROOT and LD_LIBRARY_PATH is
        #   set correctly for all child processes.
        # Nothing is copied to /usr/bin or any system directory.
        info "Running: sudo env CVMFS_TESTBED=true CVMFS_TESTBED_SOFTWARE_ROOT=$SOFTWARE_ROOT ... cvmfs_server mkfs"
        _mkfs_ok=false
        if sudo env \
                CVMFS_TESTBED=true \
                CVMFS_TESTBED_SOFTWARE_ROOT="$SOFTWARE_ROOT" \
                PATH="$SOFTWARE_ROOT:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
                "$CVMFS_SERVER_BIN" mkfs -I -P \
                -w "http://stratum0/cvmfs/$REPO_NAME" \
                -o "$USER" "$REPO_NAME"; then
            _mkfs_ok=true
        fi

        if $_mkfs_ok; then
            # Copy signing keys produced by mkfs into our config tree.
            for _keyfile in \
                "/etc/cvmfs/keys/$REPO_NAME.crt" \
                "/etc/cvmfs/keys/$REPO_NAME.key" \
                "/etc/cvmfs/keys/$REPO_NAME.pub" \
                "/etc/cvmfs/keys/$REPO_NAME.masterkey"; do
                if [[ -f "$_keyfile" ]]; then
                    sudo cp "$_keyfile" "$TESTBED_ROOT/config/keys/"
                    sudo chown "$USER:$(id -gn)" "$TESTBED_ROOT/config/keys/$(basename "$_keyfile")"
                else
                    case "$_keyfile" in
                        *.crt)
                            warn "Key file not found after mkfs: $_keyfile"
                            warn "The cvmfs-client container will fail to mount until this is copied to:"
                            warn "  $TESTBED_ROOT/config/keys/"
                            ;;
                        *.masterkey)
                            warn "Master private key not found: $_keyfile"
                            warn "Back it up manually: sudo cp $_keyfile $TESTBED_ROOT/config/keys/"
                            ;;
                        *)
                            warn "Key file not found after mkfs: $_keyfile"
                            ;;
                    esac
                fi
            done
            sudo chown -R "$USER:$(id -gn)" "$TESTBED_ROOT/repos/$REPO_NAME"
            # Make repo tree world-writable so container services (cvmfs-prepub,
            # gateway) running as non-root users can write to the CAS and spool.
            chmod -R 777 "$TESTBED_ROOT/repos/$REPO_NAME"
            success "CVMFS repository initialised."
        else
            warn "cvmfs_server mkfs failed — check output above."
            warn "Once fixed, re-run: ./testbed.sh init"
        fi
    fi
fi

# ── Print next-steps summary ──────────────────────────────────────────────────
# Grafana moves to port 3001 when the bits overlay is active (docker-compose.bits.yml
# remaps it to avoid conflict with Gitea on 3000).
GRAFANA_PORT=3000
_BITS_AVAILABLE=false
[[ -d "$SCRIPT_DIR/bits-console" ]] && _BITS_AVAILABLE=true
$_BITS_AVAILABLE && GRAFANA_PORT=3001

echo ""
echo "========================================================"
echo "  CVMFS-Prepub Testbed  —  Initialisation complete"
echo "========================================================"
echo "  Testbed root:         $TESTBED_ROOT"
echo "  Software root:        $SOFTWARE_ROOT"
echo "  .env file:            $ENV_FILE"
echo "  Repository:           $REPO_NAME"
echo "  API token (prepub):   ${PREPUB_API_TOKEN:0:16}...  (see $ENV_FILE for full value)"
if $_BITS_AVAILABLE && [[ -n "${GITEA_ADMIN_PASSWORD:-}" ]]; then
echo "  Gitea admin user:     ${GITEA_ADMIN_USER:-gitea-admin}"
echo "  Gitea admin password: ${GITEA_ADMIN_PASSWORD:0:8}...  (see $ENV_FILE for full value)"
fi
echo "========================================================"
