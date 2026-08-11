#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 CERN
# SPDX-License-Identifier: Apache-2.0

# init.sh — One-time host setup for the cvmfs-prepub testbed.
#
# Directory convention (enforced here):
#   <cvmfs-testbed>/cvmfs/          CVMFS source tree  (git clone or symlink)
#   <cvmfs-testbed>/software/       built CVMFS binaries (populated by install.sh)
#
# Before running init.sh for the first time:
#   1. Clone / symlink the CVMFS source:
#        git clone https://github.com/cvmfs/cvmfs cvmfs
#        cmake -S cvmfs -B cvmfs/build && make -C cvmfs/build -j$(nproc)
#   2. Run install.sh to populate software/:
#        ./install.sh
#
# What init.sh does (in order):
#   1. Parse command-line arguments.
#   2. Determine TESTBED_ROOT and locate .env (in TESTBED_ROOT, not next to
#      this script — the script directory may be read-only).
#   3. Load existing .env so SOFTWARE_ROOT and other overrides are available
#      before PATH is modified.
#   4. Apply --software-root / --testbed-root overrides over .env values.
#   5. Check that the conventional subdirectories exist (cvmfs/).
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
        *)                 shift ;;   # silently skip unknown flags from testbed.sh
    esac
done

# ── Script location ───────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTBED_DIR="$(dirname "$SCRIPT_DIR")"   # root of cvmfs-testbed checkout

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
SOFTWARE_ROOT="${SOFTWARE_ROOT:-$TESTBED_DIR/software}"

# ── Check conventional subdirectories ────────────────────────────────────────
# cvmfs/ must exist (contains source and build tree used by install.sh).
if [[ ! -d "$TESTBED_DIR/cvmfs" ]]; then
    warn "CVMFS source not found at $TESTBED_DIR/cvmfs"
    warn "Clone or symlink it before running install.sh:"
    warn "  git clone https://github.com/cvmfs/cvmfs $TESTBED_DIR/cvmfs"
    warn "  cmake -S $TESTBED_DIR/cvmfs -B $TESTBED_DIR/cvmfs/build"
    warn "  make -C $TESTBED_DIR/cvmfs/build -j\$(nproc)"
    warn "  $SCRIPT_DIR/install.sh"
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

# ── Create directory tree ─────────────────────────────────────────────────────
info "Creating directory structure under $TESTBED_ROOT ..."
mkdir -p \
    "$TESTBED_ROOT/software" \
    "$TESTBED_ROOT/repos" \
    "$TESTBED_ROOT/config/s3" \
    "$TESTBED_ROOT/data/spool" \
    "$TESTBED_ROOT/data/spool/dist-queue" \
    "$TESTBED_ROOT/data/s1a" \
    "$TESTBED_ROOT/data/s1b" \
    "$TESTBED_ROOT/data/monitoring/vm" \
    "$TESTBED_ROOT/data/monitoring/vmagent" \
    "$TESTBED_ROOT/data/cvmfs-client" \
    "$TESTBED_ROOT/data/mosquitto" \
    "$TESTBED_ROOT/data/mosquitto-log" \
    "$TESTBED_ROOT/data/receiver-logs" \
    "$TESTBED_ROOT/data/gateway-spool" \
    "$TESTBED_ROOT/data/native-ingest" \
    "$TESTBED_ROOT/data/prepub-ingest" \
    "$TESTBED_ROOT/data/catalog-dumps" \
    "$TESTBED_ROOT/config/gateway" \
    "$TESTBED_ROOT/config/keys" \
    "$TESTBED_ROOT/config/cvmfs-prepub" \
    "$TESTBED_ROOT/config/broker-tls" \
    "$TESTBED_ROOT/config/stratum1-a" \
    "$TESTBED_ROOT/config/stratum1-b" \
    "$TESTBED_ROOT/config/repo-config" \
    "$TESTBED_ROOT/config/native-publisher"

# Directories that are mounted as writable volumes inside containers running
# as non-root users need to be world-writable on the host.  The affected
# services and their in-container UIDs are:
#   cvmfs-prepub / stratum1-a / stratum1-b  — 'prepub' (system UID, ~100-999)
#   vmagent / victoriametrics               — UID 1000 (victoriametrics image)
chmod 777 \
    "$TESTBED_ROOT/data/spool" \
    "$TESTBED_ROOT/data/spool/dist-queue" \
    "$TESTBED_ROOT/data/s1a" \
    "$TESTBED_ROOT/data/s1b" \
    "$TESTBED_ROOT/data/monitoring/vm" \
    "$TESTBED_ROOT/data/monitoring/vmagent" \
    "$TESTBED_ROOT/data/cvmfs-client" \
    "$TESTBED_ROOT/data/receiver-logs" \
    "$TESTBED_ROOT/data/gateway-spool" \
    "$TESTBED_ROOT/data/prepub-ingest"
# prepub-ingest is world-writable for the same reason as the others: the
# cvmfs-prepub container runs as a non-root user (uid 999), so a host directory
# owned by the invoking user is not writable inside it.  cvmfs_server ingest
# then cannot create its per-repo spool and the ingest path silently does
# nothing useful, while /api/v1/health still advertises it.
# NDJSON log files — must exist as regular files before docker-compose mounts
# them (bind-mounting a non-existent path creates a directory, not a file).
for _log in ingest-jobs.ndjson runs.ndjson test-results.ndjson; do
    if [[ ! -f "$TESTBED_ROOT/data/$_log" ]]; then
        touch "$TESTBED_ROOT/data/$_log"
        chmod 666 "$TESTBED_ROOT/data/$_log"
        success "Created $_log log file."
    fi
done
unset _log
# Live test-suite status (single JSON object, overwritten by `testbed.sh suite`).
# Seed an idle default so the console's Tests tab renders before any suite runs.
if [[ ! -f "$TESTBED_ROOT/data/test-suite-status.json" ]]; then
    printf '%s\n' '{"suite_run_id":null,"started_at":null,"finished_at":null,"running":false,"selected":[],"current":null,"results":[]}' \
        > "$TESTBED_ROOT/data/test-suite-status.json"
    chmod 666 "$TESTBED_ROOT/data/test-suite-status.json"
    success "Created test-suite-status.json (idle)."
fi
success "Directory structure created."

# ── Generate secrets and write .env ──────────────────────────────────────────
# Idempotent: if CVMFS_GATEWAY_SECRET is already set (loaded from .env above),
# the existing secrets are reused and .env is not rewritten.
info "Handling secrets..."
# Gateway key id: reused from .env if present, else the conventional default.
# The gatewaykey/.gw files below are built from this id + CVMFS_GATEWAY_SECRET.
CVMFS_GATEWAY_KEY_ID="${CVMFS_GATEWAY_KEY_ID:-prepub-key}"
if [[ -z "${CVMFS_GATEWAY_SECRET:-}" ]]; then
    CVMFS_GATEWAY_SECRET=$(openssl rand -hex 32)
    PREPUB_API_TOKEN=$(openssl rand -hex 24)
    PREPUB_HMAC_SECRET=$(openssl rand -hex 32)
    CVMFS_GATEWAY_KEY_ID="prepub-key"

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
        'BEGIN { FS="="; OFS="=" }
         /^TESTBED_ROOT=/             { $2=TESTBED_ROOT;             print; next }
         /^SOFTWARE_ROOT=/            { $2=SOFTWARE_ROOT;            print; next }
         /^REPO_NAME=/                { $2=REPO_NAME;                print; next }
         /^CVMFS_GATEWAY_SECRET=$/    { $2=CVMFS_GATEWAY_SECRET;     print; next }
         /^PREPUB_API_TOKEN=$/        { $2=PREPUB_API_TOKEN;         print; next }
         /^PREPUB_HMAC_SECRET=$/      { $2=PREPUB_HMAC_SECRET;       print; next }
         /^CVMFS_GATEWAY_KEY_ID=/     { $2=CVMFS_GATEWAY_KEY_ID;     print; next }
         { print }' \
        "$TESTBED_DIR/.env.example" > "$ENV_FILE"
    success "Generated secrets and wrote $ENV_FILE"
else
    warn "Reusing existing secrets from $ENV_FILE"
fi

# ── .env.s3 — direct-to-S3 ingest variant (separate from .env on purpose) ─────
# Kept out of .env so that enabling, changing or deleting the S3 variant never
# risks rotating the credentials the rest of the testbed depends on. Compose
# declares it `required: false`, so a missing file simply leaves the variant
# off; this creates it with S3_ENABLED=0 and a random MinIO password.
_ENV_S3_FILE="$TESTBED_DIR/.env.s3"
if [[ ! -f "$_ENV_S3_FILE" && -f "$TESTBED_DIR/.env.s3.example" ]]; then
    _minio_pw=$(openssl rand -hex 16)
    awk -v PW="$_minio_pw" \
        'BEGIN { FS="="; OFS="=" }
         /^MINIO_ROOT_PASSWORD=$/ { $2=PW; print; next }
         { print }' \
        "$TESTBED_DIR/.env.s3.example" > "$_ENV_S3_FILE"
    chmod 600 "$_ENV_S3_FILE"
    unset _minio_pw
    success "Wrote $(basename "$_ENV_S3_FILE") (S3_ENABLED=0 — capability off)"
else
    info "$(basename "$_ENV_S3_FILE") present — left untouched"
fi

# Re-source .env so any newly written values are available for config templates.
# shellcheck source=/dev/null
source "$ENV_FILE"

# Also pull in .env.s3.  Until now init.sh only ever WROTE that file and never
# read it, because nothing here needed the MinIO credentials — testbed.sh merges
# it into a temp env-file for compose interpolation and init was not involved.
# Writing the canonical S3 config below does need them, and without this the
# credentials are simply not in scope: STORAGE=s3 would abort claiming they are
# unset no matter how correct .env.s3 is.
# shellcheck source=/dev/null
if [[ -f "$_ENV_S3_FILE" ]]; then
    set -a; source "$_ENV_S3_FILE"; set +a
fi

# ── STORAGE — which store the repository is SERVED FROM ───────────────────────
# Deliberately a different knob from S3_ENABLED, which says only that MinIO is
# running and the per-job `direct_s3` capability exists.  Conflating the two is
# what produced a repository split across both stores: data in the bucket
# because a build asked for direct_s3, catalogs on local disk because that is
# what the gateway receiver's CVMFS_UPSTREAM_STORAGE said.  Neither store held a
# complete repository and no CVMFS_SERVER_URL could serve it.
#
#   S3_ENABLED=1  — the object store exists.
#   STORAGE=s3    — the repository is served from it.
#
# See docs/storage-topology.md.
STORAGE="${STORAGE:-local}"
case "$STORAGE" in
    s3|local) ;;
    *) error "STORAGE must be 's3' or 'local', got '${STORAGE}'."; exit 1 ;;
esac
info "Storage backend: STORAGE=${STORAGE}"

# ── Canonical <repo>.s3.conf ──────────────────────────────────────────────────
# ONE file, written here, mounted read-only wherever it is needed: the gateway
# (its receiver reads CVMFS_UPSTREAM_STORAGE=S3,...@<this file>), prepub, and
# the native publisher.  Previously the prepub entrypoint wrote its own copy,
# so three components could disagree about the bucket while each looked
# internally consistent.
#
# Written whenever credentials exist, independently of STORAGE: with STORAGE=s3
# the receiver needs it, and with STORAGE=local a build may still ask for
# direct_s3.  It is the config, not the switch.
#
# Permissions follow the same rule as every other host-side file a container
# must read (config/keys, repo-config, ...): directory 0755, file 0644.  The
# prepub container runs as an unprivileged user (uid 999) that cannot traverse a
# 0700 directory, and an unreadable S3 config fails as "config does not exist"
# deep inside a publish.  A 0750 parent has caused exactly that here before.
#
# 0644 on a file holding the MinIO secret is a deliberate widening, not an
# oversight: the same credentials are already in the prepub container's
# environment (so `docker inspect` shows them) and in .env.s3.  The testbed's
# threat model does not treat local read access as a boundary.
_S3_CONF_DIR="$TESTBED_ROOT/config/s3"
_S3_CONF="$_S3_CONF_DIR/${REPO_NAME}.s3.conf"
mkdir -p "$_S3_CONF_DIR"
# Guarded: Docker auto-creates a missing bind-mount source as root:root, and an
# unguarded chmod on a root-owned directory returns EPERM, which under
# `set -euo pipefail` aborts the whole init — a failure mode this script has
# already been bitten by and guards against elsewhere.
chmod 755 "$_S3_CONF_DIR" 2>/dev/null || true
if [[ -n "${MINIO_ROOT_USER:-}" && -n "${MINIO_ROOT_PASSWORD:-}" ]]; then
    # CVMFS parses this by SOURCING it — BashOptionsManager::ParsePath opens a
    # real shell and feeds it every line — so an unquoted value containing $,
    # backticks or # would be expanded, truncated or executed as the publishing
    # user.  Single-quote everything, escaping embedded quotes the POSIX way.
    _sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
    # umask while writing: the credentials must never exist on disk
    # world-readable, not even between create and chmod.
    ( umask 077
      cat > "$_S3_CONF" <<EOF
# Generated by init.sh — do not edit; edit .env.s3 and re-run init.
# DNS_BUCKETS=false: MinIO serves path-style (host/bucket), not bucket.host.
CVMFS_S3_HOST=$(_sq "${S3_HOST:-minio}")
CVMFS_S3_PORT=$(_sq "${S3_PORT:-9000}")
CVMFS_S3_BUCKET=$(_sq "${S3_BUCKET:-cvmfs}")
CVMFS_S3_ACCESS_KEY=$(_sq "${MINIO_ROOT_USER}")
CVMFS_S3_SECRET_KEY=$(_sq "${MINIO_ROOT_PASSWORD}")
CVMFS_S3_DNS_BUCKETS=false
CVMFS_S3_USE_HTTPS=false
CVMFS_S3_REGION=$(_sq "${S3_REGION:-us-east-1}")
CVMFS_S3_MAX_NUMBER_OF_PARALLEL_CONNECTIONS=$(_sq "${S3_PARALLEL:-16}")
EOF
    )
    chmod 644 "$_S3_CONF" 2>/dev/null || true
    unset -f _sq
    success "Canonical S3 config written: config/s3/${REPO_NAME}.s3.conf"
elif [[ "$STORAGE" == "s3" ]]; then
    error "STORAGE=s3 but MINIO_ROOT_USER/MINIO_ROOT_PASSWORD are unset." \
          "\n       The repository would be served from a bucket nothing can" \
          "\n       authenticate to.  Set them in .env.s3 (or delete .env.s3 and" \
          "\n       re-run init, which generates a random password)."
    exit 1
else
    # No credentials and STORAGE=local: nothing needs the file.  Remove a stale
    # one so withdrawing the credentials actually withdraws the capability
    # rather than leaving a config pointing at a MinIO that is not running.
    rm -f "$_S3_CONF"
    info "No MinIO credentials — S3 config not written (STORAGE=local)."
fi

# ── Mint embedded-broker TLS material (wss://) ────────────────────────────────
# Self-signed CA + server certificate for the in-process MQTT broker on
# Stratum 0. SANs cover the publisher's own localhost client and the receivers'
# DNS name (cvmfs-prepub). Idempotent: minted only when missing.
BROKER_TLS_DIR="$TESTBED_ROOT/config/broker-tls"
mkdir -p "$BROKER_TLS_DIR"
if [[ ! -s "$BROKER_TLS_DIR/server.crt" || ! -s "$BROKER_TLS_DIR/server.key" || ! -s "$BROKER_TLS_DIR/ca.crt" ]]; then
    info "Minting embedded-broker TLS CA + server certificate..."
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$BROKER_TLS_DIR/ca.key" -out "$BROKER_TLS_DIR/ca.crt" \
        -subj "/CN=cvmfs-prepub broker CA" >/dev/null 2>&1
    openssl req -newkey rsa:2048 -nodes \
        -keyout "$BROKER_TLS_DIR/server.key" -out "$BROKER_TLS_DIR/server.csr" \
        -subj "/CN=cvmfs-prepub" >/dev/null 2>&1
    openssl x509 -req -in "$BROKER_TLS_DIR/server.csr" -days 3650 \
        -CA "$BROKER_TLS_DIR/ca.crt" -CAkey "$BROKER_TLS_DIR/ca.key" -CAcreateserial \
        -extfile <(printf 'subjectAltName=DNS:cvmfs-prepub,DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth\n') \
        -out "$BROKER_TLS_DIR/server.crt" >/dev/null 2>&1
    rm -f "$BROKER_TLS_DIR/server.csr"
    chmod 644 "$BROKER_TLS_DIR"/*.crt
    chmod 600 "$BROKER_TLS_DIR/ca.key"
    # server.key is mounted into the non-root prepub container, so it must be
    # world-readable (the config files are 644 for the same reason). The CA key
    # never leaves the host and stays 600.
    chmod 644 "$BROKER_TLS_DIR/server.key"
    success "Embedded-broker TLS material written to $BROKER_TLS_DIR"
else
    warn "Reusing existing embedded-broker TLS material in $BROKER_TLS_DIR"
fi

# ── Discovery signing keypair (Ed25519) + per-node enrollment keys ────────────
# Discovery is signed asymmetrically: the publisher holds the private key; each
# receiver gets only the public key, so the master secret never reaches a
# receiver. Per-node enrollment keys = HMAC-SHA256(PREPUB_HMAC_SECRET, node) are
# provisioned to each receiver in place of the master.
DISCO_DIR="$TESTBED_ROOT/config/discovery-keys"
mkdir -p "$DISCO_DIR"
if [[ ! -s "$DISCO_DIR/discovery.key" || ! -s "$DISCO_DIR/discovery.pub" ]]; then
    info "Minting Ed25519 discovery signing keypair..."
    openssl genpkey -algorithm ed25519 -out "$DISCO_DIR/discovery.key" >/dev/null 2>&1
    openssl pkey -in "$DISCO_DIR/discovery.key" -pubout -out "$DISCO_DIR/discovery.pub" >/dev/null 2>&1
    chmod 644 "$DISCO_DIR/discovery.key"  # non-root publisher container must read it (CA/master stay off the host elsewhere)
    chmod 644 "$DISCO_DIR/discovery.pub"
    success "Discovery keypair written to $DISCO_DIR"
else
    warn "Reusing existing discovery keypair in $DISCO_DIR"
fi
_upsert_env() {
    local n="$1" v="$2"
    if grep -q "^$n=" "$ENV_FILE" 2>/dev/null; then
        sed -i "s|^$n=.*|$n=$v|" "$ENV_FILE"
    else
        echo "$n=$v" >> "$ENV_FILE"
    fi
}
for node in stratum1-a stratum1-b; do
    nk=$(printf '%s' "$node" | openssl dgst -sha256 -hmac "$PREPUB_HMAC_SECRET" | awk '{print $NF}')
    _upsert_env "PREPUB_NODE_KEY_$(echo "$node" | tr 'a-z-' 'A-Z_')" "$nk"
done
success "Per-node enrollment keys provisioned (PREPUB_NODE_KEY_*)"

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
plain_text $CVMFS_GATEWAY_KEY_ID $CVMFS_GATEWAY_SECRET
EOF
# 0644, not 0600.
#
# cvmfs_server_ingest.sh reads this file from a hardcoded
# /etc/cvmfs/keys/<name>.gw, and it now runs inside cvmfs-prepub, which runs as
# the non-root `prepub` user (uid 999).  A 0600 file owned by the invoking host
# user is unreadable there, and cvmfs_server fails at the very first step with
#   Error reading key file /etc/cvmfs/keys/<repo>.gw.
#   Impossible to start a transaction
# — before any lease, upload or catalog work, so the failure looks like a
# gateway or routing problem rather than a permission one.  The native
# publisher never hit this because it runs as root and bypasses mode bits.
#
# This is a deliberate TESTBED-ONLY relaxation and must not be copied to a
# production publisher.  It is defensible here and nowhere else: the secret is
# generated by this script, scoped to a disposable local repository, thrown
# away by `make cleanall`, and never leaves the host.  In production the same
# need is met by giving the file the service account's GROUP (0640), which
# needs a real group shared between host and container — see the
# /etc/cvmfs/keys ownership work on cvmfs-bits-01, where a 0750 PARENT
# directory made every key beneath it unreadable regardless of its own mode.
chmod 644 "$TESTBED_ROOT/config/keys/$REPO_NAME.gw"

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
          "id": "$CVMFS_GATEWAY_KEY_ID",
          "path": "/"
        }
      ]
    }
  ]
}
EOF
success "Gateway config written."

# ── Coarse-publish (ADR-0007) ingest config for cvmfs-prepub finalize ─────────
# cvmfs_swissknife ingestsql (invoked by the finalize job) reads its config from
# the -C prefix: <prefix>/<repo>/{config,gatewaykey,pubkey}. The prepub mounts
# this dir at /etc/cvmfs-prepub/gateway-client and is launched with
# --ingest-config-prefix /etc/cvmfs-prepub/gateway-client/ (see the compose file).
# All three are real files (a file bind-mount into this :ro dir cannot create its
# mountpoint). No new credentials are minted here: gatewaykey is the SAME gateway
# key as config/keys/<repo>.gw (built from CVMFS_GATEWAY_KEY_ID + CVMFS_GATEWAY_SECRET
# in .env), and pubkey is the repository public key /etc/cvmfs/keys/<repo>.pub that
# mkfs writes. mkfs runs later in this script, so on a fresh install the pubkey is
# (re)provisioned by the post-mkfs step below — a single init run suffices.
INGEST_DIR="$TESTBED_ROOT/config/cvmfs-prepub/gateway-client/$REPO_NAME"
mkdir -p "$INGEST_DIR"
cat > "$INGEST_DIR/config" <<EOF
CVMFS_GATEWAY=http://gateway:4929/api/v1
CVMFS_STRATUM0=http://stratum0/cvmfs/$REPO_NAME
CVMFS_HTTP_PROXY=DIRECT
CVMFS_UPSTREAM_STORAGE=local,/data/cas/data/txn,/data/cas
EOF
# gatewaykey: same plain_text format as the gateway .gw key (id + secret).
# 644, not 600: cvmfs_swissknife runs as the container's non-root `prepub` user,
# whose UID differs from the host owner, so a 600 file would be unreadable and
# ingestsql aborts ("gatewaykey is not readable"). Acceptable for the testbed;
# a real deployment should provision this secret with matching ownership.
printf 'plain_text %s %s\n' "$CVMFS_GATEWAY_KEY_ID" "$CVMFS_GATEWAY_SECRET" > "$INGEST_DIR/gatewaykey"
chmod 644 "$INGEST_DIR/gatewaykey"
# pubkey: the repository public key. Canonical source is /etc/cvmfs/keys/<repo>.pub
# (written by mkfs). On a re-init the repo already exists so it is present now; on a
# fresh install it does not exist until mkfs runs later — the post-mkfs step below
# then provisions it. config/keys/<repo>.pub is a fallback (our own copy).
if [[ -f "/etc/cvmfs/keys/$REPO_NAME.pub" ]]; then
    cp -f "/etc/cvmfs/keys/$REPO_NAME.pub" "$INGEST_DIR/pubkey"
    chmod 644 "$INGEST_DIR/pubkey"
elif [[ -f "$TESTBED_ROOT/config/keys/$REPO_NAME.pub" ]]; then
    cp -f "$TESTBED_ROOT/config/keys/$REPO_NAME.pub" "$INGEST_DIR/pubkey"
    chmod 644 "$INGEST_DIR/pubkey"
else
    warn "repo pubkey not present yet — it will be provisioned by the post-mkfs step in this run"
fi
success "Ingest (coarse-publish finalize) config written."

info "Writing cvmfs-prepub config..."
cat > "$TESTBED_ROOT/config/cvmfs-prepub/config.yaml" <<'EOFCONFIG'
dev: true
log_level: info
spool_root: /data/spool
# stratum0_url is used to fetch the existing root catalog for merging before
# each publish.  Must point to the Stratum 0 Apache endpoint inside the Docker
# network.  Without this the catalog merge step is skipped, which causes
# cvmfs_receiver to crash on the commit (it receives an empty new_root_hash).
stratum0_url: http://stratum0/cvmfs
cas:
  type: localfs
  root: /data/cas
server:
  listen: ":8080"
gateway:
  url: http://gateway:4929
# Stratum 1 distribution is now driven by the embedded MQTT-over-WSS pull
# broker: receivers learn of new commits over the control plane and pull the
# objects from Stratum 0 themselves. The cvmfs-prepub binary no longer reads
# any push-era distribution.* keys (stratum1_endpoints, quorum, worker/queue/
# backoff settings) — they are intentionally omitted here.
# Per-job wall-clock timeout.  Cancels any job that is stuck in pipeline,
# catalog merge, SubmitPayload, or commit for longer than this duration.
# Prevents jobs from hanging indefinitely when a remote endpoint stalls.
# 30m is generous for typical payloads; increase for very large repos.
job_timeout: 30m
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

# ── Patch server.conf CVMFS_UPSTREAM_STORAGE (unconditional) ─────────────────
# This section runs every time init.sh is invoked so that existing installations
# (where mkfs already ran in a previous init) get the correct upstream storage
# setting without having to wipe and re-init the repository.
#
# Background: LocalUploader::FinalizeStreamedUpload calls rename(scratch→data/XY/hash).
# rename() fails with EXDEV (errno 18) when scratch and data are on different bind
# mounts.  docker-compose.yml uses two separate bind mounts:
#   /var/spool/cvmfs  ← ${TESTBED_ROOT}/data/gateway-spool   (spool mount)
#   /srv/cvmfs/<repo> ← ${TESTBED_ROOT}/repos/<repo>          (CAS mount)
# Using upstream-scratch/ under /srv/cvmfs/<repo>/ keeps rename() on one filesystem.
_config_server_conf="$TESTBED_ROOT/config/repo-config/server.conf"
if [[ -f "$_config_server_conf" ]]; then
    _spool_dir_patch="/srv/cvmfs/$REPO_NAME/upstream-scratch"
    _cas_root_patch="/srv/cvmfs/$REPO_NAME"
    _new_upstream_patch="local,${_spool_dir_patch},${_cas_root_patch}"
    if grep -q "^CVMFS_UPSTREAM_STORAGE=" "$_config_server_conf"; then
        _current=$(grep "^CVMFS_UPSTREAM_STORAGE=" "$_config_server_conf")
        if [[ "$_current" != "CVMFS_UPSTREAM_STORAGE=${_new_upstream_patch}" ]]; then
            sed -i \
                "s|^CVMFS_UPSTREAM_STORAGE=.*|CVMFS_UPSTREAM_STORAGE=${_new_upstream_patch}|" \
                "$_config_server_conf"
            info "Re-patched CVMFS_UPSTREAM_STORAGE in config/repo-config/server.conf"
            info "  was: $_current"
            info "  now: CVMFS_UPSTREAM_STORAGE=${_new_upstream_patch}"
        else
            info "CVMFS_UPSTREAM_STORAGE in server.conf already correct."
        fi
    else
        echo "CVMFS_UPSTREAM_STORAGE=${_new_upstream_patch}" >> "$_config_server_conf"
        info "Added CVMFS_UPSTREAM_STORAGE to server.conf: ${_new_upstream_patch}"
    fi
    # Ensure the scratch directory exists on the host (visible inside the
    # gateway container as /srv/cvmfs/<repo>/upstream-scratch/).
    # Best-effort: the gateway container runs as root and may already own this
    # directory, and under `set -e` a failed chmod aborted the whole init --
    # silently skipping everything below it.
    mkdir -p "$TESTBED_ROOT/repos/$REPO_NAME/upstream-scratch" 2>/dev/null || true
    chmod 755 "$TESTBED_ROOT/repos/$REPO_NAME/upstream-scratch" 2>/dev/null || true

    # Receiver opt-in: create absent parents of a lease path instead of aborting
    # the commit.  The testbed wants it on, and it must survive `make clean`;
    # set by hand it silently vanished on the next init and the suite went red.
    if ! grep -q "^CVMFS_GW_MKDIR_PARENTS=" "$_config_server_conf"; then
        echo "CVMFS_GW_MKDIR_PARENTS=true" >> "$_config_server_conf"
        info "Enabled CVMFS_GW_MKDIR_PARENTS in config/repo-config/server.conf"
    fi
    success "server.conf CVMFS_UPSTREAM_STORAGE OK."

    # ── Generate native-publisher server.conf (gateway mode) ─────────────────
    # The native-publisher container runs cvmfs_server ingest which contacts the
    # gateway API directly (not via cvmfs-prepub).  It needs a server.conf where
    # CVMFS_UPSTREAM_STORAGE points to the gateway rather than local CAS storage.
    #
    # The receiver's server.conf uses "local,..." so the receiver writes objects
    # directly to disk.  The native publisher's server.conf uses "gw,..." so that
    # cvmfs_swissknife sends objects through the gateway API like a real publisher.
    #
    # The scratch dir (/var/spool/cvmfs/${REPO_NAME}/tmp) is the spool directory
    # mounted from ${TESTBED_ROOT}/data/native-ingest inside the container.
    info "Generating native-publisher/server.conf (gateway mode)..."
    _native_upstream="gw,/var/spool/cvmfs/${REPO_NAME}/tmp,http://gateway:4929/api/v1"
    # Two substitutions in one sed call:
    #  1. Point upstream storage at the gateway rather than local CAS.
    #  2. Force CVMFS_USER=root — the host username does not exist inside the
    #     container, so cvmfs_server ingest would fail with "id: '<user>': no
    #     such user" if we left the host value in place.
    sed "s|^CVMFS_UPSTREAM_STORAGE=.*|CVMFS_UPSTREAM_STORAGE=${_native_upstream}|;
         s|^CVMFS_USER=.*|CVMFS_USER=root|" \
        "$_config_server_conf" \
        > "$TESTBED_ROOT/config/native-publisher/server.conf"
    chmod 644 "$TESTBED_ROOT/config/native-publisher/server.conf"
    success "native-publisher/server.conf written (gateway mode: ${_native_upstream})."

    # ── Generate native-publisher/client.conf ─────────────────────────────────
    # cvmfs_server ingest sources client.conf from /etc/cvmfs/repositories.d/<repo>/
    # early in its startup sequence (__load_repo_config).  Without this file the
    # script aborts with "cannot open .../client.conf: No such file".
    # Prefer the authoritative file written by cvmfs_server mkfs on the host;
    # fall back to a generated minimal version if mkfs hasn't run yet.
    _host_client_conf="/etc/cvmfs/repositories.d/${REPO_NAME}/client.conf"
    _native_client_conf="$TESTBED_ROOT/config/native-publisher/client.conf"
    if [[ -f "$_host_client_conf" ]]; then
        sudo cp "$_host_client_conf" "$_native_client_conf"
        sudo chown "$USER:$(id -gn)" "$_native_client_conf"
        chmod 644 "$_native_client_conf"
        info "Copied native-publisher/client.conf from host repository config."
    else
        # Minimal client.conf: stratum0 URL and public key path as seen inside
        # the container (Docker service name + mounted key directory).
        cat > "$_native_client_conf" <<EOF
CVMFS_SERVER_URL=http://stratum0/cvmfs/${REPO_NAME}
CVMFS_PUBLIC_KEY=/etc/cvmfs/keys/${REPO_NAME}.pub
CVMFS_REPOSITORY_NAME=${REPO_NAME}
CVMFS_HTTP_PROXY=DIRECT
EOF
        chmod 644 "$_native_client_conf"
        info "Generated minimal native-publisher/client.conf (host client.conf not found yet)."
    fi
    success "native-publisher/client.conf ready."

    # ── Generate prepub-publisher/ (same repo, different CVMFS_USER) ─────────
    # cvmfs-prepub also runs `cvmfs_server ingest` (--ingest-publish), but as
    # the non-root `prepub` user rather than as root.  It therefore cannot
    # share native-publisher/server.conf, because of get_user_shell():
    #
    #   if [ x"$(whoami)" = x"$CVMFS_USER" ]; then shell_cmd="sh -c"
    #   elif is_root; then                         shell_cmd="su -m $CVMFS_USER -c"
    #   fi                    # neither -> shell_cmd stays EMPTY
    #
    # With CVMFS_USER=root and a non-root caller, neither branch is taken and
    # the empty shell_cmd makes cvmfs_server run the ENTIRE swissknife command
    # string as a single command name:
    #   cvmfs_server: eval: cvmfs_swissknife ingest -u ... : not found
    # which is a "not found" for a binary that exists, is executable, is on
    # PATH and runs fine on its own.
    #
    # Everything else is copied verbatim: same repository, same gateway, same
    # chunk settings.  Only CVMFS_USER differs, so a comparison between the two
    # publish paths stays meaningful.
    mkdir -p "$TESTBED_ROOT/config/prepub-publisher"
    sed "s|^CVMFS_USER=.*|CVMFS_USER=prepub|" \
        "$TESTBED_ROOT/config/native-publisher/server.conf" \
        > "$TESTBED_ROOT/config/prepub-publisher/server.conf"
    cp "$TESTBED_ROOT/config/native-publisher/client.conf" \
       "$TESTBED_ROOT/config/prepub-publisher/client.conf"
    chmod 644 "$TESTBED_ROOT/config/prepub-publisher/server.conf" \
              "$TESTBED_ROOT/config/prepub-publisher/client.conf"
    success "prepub-publisher/{server,client}.conf written (CVMFS_USER=prepub)."
else
    warn "config/repo-config/server.conf not found — skipping upstream-storage patch."
    warn "It will be created and patched when the repository is initialised (mkfs)."
    warn "native-publisher/server.conf will also be generated after mkfs completes."
fi

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
            # rmfs on a partial registration cleans the spool and mount point but
            # may leave /etc/cvmfs/repositories.d/<repo>/ on disk.  cvmfs_server mkfs
            # checks for that directory and refuses with "already exists" if it is
            # present.  Remove it unconditionally so mkfs can proceed cleanly.
            if [[ -d "/etc/cvmfs/repositories.d/$REPO_NAME" ]]; then
                sudo rm -rf "/etc/cvmfs/repositories.d/$REPO_NAME"
                info "Removed stale /etc/cvmfs/repositories.d/$REPO_NAME"
            fi
        fi

        # ── Run mkfs ─────────────────────────────────────────────────────────────
        # -p (do NOT configure Apache) is required here: Apache runs in the
        #   stratum0 CONTAINER and is configured by the compose stack, but mkfs
        #   runs on the HOST.  Without -p, mkfs ends with
        #     wait_for_apache "http://stratum0/cvmfs/<repo>/.cvmfswhitelist"
        #   (cvmfs_server_mkfs.sh:481) — and `stratum0` is a Docker-network
        #   hostname the host cannot resolve, so mkfs dies with
        #     "Creating Initial Repository... fail (Apache configuration)"
        #   after having already created the keys, storage and whitelist.
        #   The CVMFS_TESTBED env var below does not help: that support is not
        #   present in the CVMFS server scripts we build from.
        # CVMFS_TESTBED=true  — skips Apache vhost setup (cvmfs_server_mkfs.sh).
        # CVMFS_TESTBED_SOFTWARE_ROOT — tells cvmfs_server_{coda,util}.sh where
        #   binaries (cvmfs_publish, cvmfs_swissknife) and libraries live, so
        #   setcap runs on the real files in SOFTWARE_ROOT and LD_LIBRARY_PATH is
        #   set correctly for all child processes.
        # Nothing is copied to /usr/bin or any system directory.
        # ── Stratum0 URL: host-reachable for mkfs, container-facing afterwards ──
        # mkfs runs on the HOST and genuinely fetches over this URL: swissknife
        # `sign` is invoked with -u $CVMFS_STRATUM0 and pulls .cvmfsreflog
        # (cvmfs_server_common.sh:669+). "http://stratum0/…" only resolves
        # inside the compose network, so mkfs died with
        #   HTTP connection error 4: http://stratum0/cvmfs/<repo>/.cvmfsreflog
        #   failed loading reflog (3 - network failure) → fail! (cannot sign repo)
        # Use the published Apache port for mkfs, then rewrite CVMFS_STRATUM0 in
        # server.conf to the container-facing name (below), which is what the
        # gateway/receiver inside the network must use.  Both URLs serve the very
        # same storage directory, so the repository content is identical.
        _MKFS_STRATUM0_URL="http://localhost:8090/cvmfs/$REPO_NAME"
        _CONTAINER_STRATUM0_URL="http://stratum0/cvmfs/$REPO_NAME"
        # `make clean && make init` legitimately runs with every container down,
        # so init starts the one service mkfs depends on rather than telling the
        # user to do it: Apache must be able to serve the storage directory back
        # while mkfs signs the initial repository.  Starting stratum0 alone is
        # enough (it has no dependencies) and is idempotent when already up.
        if ! curl -sf --max-time 5 "http://localhost:8090/" >/dev/null 2>&1; then
            info "Starting the stratum0 container (Apache) — mkfs must read back what it writes ..."
            ( cd "$TESTBED_DIR" && docker compose up -d stratum0 ) >/dev/null 2>&1 \
                || ( cd "$TESTBED_DIR" && docker-compose up -d stratum0 ) >/dev/null 2>&1 \
                || warn "Could not start the stratum0 container automatically."
            for _i in $(seq 1 30); do
                curl -sf --max-time 2 "http://localhost:8090/" >/dev/null 2>&1 && break
                sleep 1
            done
        fi
        if ! curl -sf --max-time 5 "http://localhost:8090/" >/dev/null 2>&1; then
            warn "Apache (stratum0 container) is still not reachable at http://localhost:8090/."
            warn "mkfs signs the initial repository by reading .cvmfsreflog back over HTTP,"
            warn "so it cannot succeed while Apache is down — skipping mkfs."
            warn "Start the containers, then re-run init:"
            warn "  ./testbed start && ./testbed init"
            CVMFS_REPO_INIT_OK=false
        fi
    fi

    if $CVMFS_REPO_INIT_OK; then
        info "Running: sudo env CVMFS_TESTBED=true CVMFS_TESTBED_SOFTWARE_ROOT=$SOFTWARE_ROOT ... cvmfs_server mkfs"
        _mkfs_ok=false
        if sudo env \
                CVMFS_TESTBED=true \
                CVMFS_TESTBED_SOFTWARE_ROOT="$SOFTWARE_ROOT" \
                PATH="$SOFTWARE_ROOT:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
                "$CVMFS_SERVER_BIN" mkfs -I -P -p \
                -w "$_MKFS_STRATUM0_URL" \
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
                    # Docker auto-creates a DIRECTORY at a bind-mount source that
                    # does not exist yet.  If the containers were started before
                    # mkfs produced these keys, config/keys/<repo>.{crt,key,pub,
                    # masterkey} are now directories, and:
                    #   * this cp fails with "cannot overwrite directory … with
                    #     non-directory", and
                    #   * any container created in that state has a directory as
                    #     the mount point in its rootfs, so once the host path
                    #     becomes a file it refuses to start with
                    #     "not a directory: … Are you trying to mount a directory
                    #     onto a file (or vice-versa)?"
                    # Remove the bogus directory so the real key can be installed.
                    # Containers created earlier must still be RECREATED (not just
                    # restarted) — `docker compose down && ./testbed start`.
                    _keydst="$TESTBED_ROOT/config/keys/$(basename "$_keyfile")"
                    if [[ -d "$_keydst" ]]; then
                        warn "Removing directory where a key file belongs: $_keydst"
                        warn "(Docker created it; recreate containers afterwards: docker compose down)"
                        sudo rm -rf "$_keydst"
                    fi
                    sudo cp "$_keyfile" "$_keydst"
                    sudo chown "$USER:$(id -gn)" "$_keydst"
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
            # Provision the ingestsql gateway-client pubkey from the canonical repo
            # public key mkfs just wrote (single-run reliability: the gateway-client
            # block above runs before mkfs, when this key does not yet exist).
            if [[ -f "/etc/cvmfs/keys/$REPO_NAME.pub" && -d "$INGEST_DIR" ]]; then
                sudo cp -f "/etc/cvmfs/keys/$REPO_NAME.pub" "$INGEST_DIR/pubkey"
                sudo chown "$USER:$(id -gn)" "$INGEST_DIR/pubkey"
                chmod 644 "$INGEST_DIR/pubkey"
                info "Provisioned ingestsql gateway-client pubkey from /etc/cvmfs/keys/$REPO_NAME.pub"
            fi
            sudo chown -R "$USER:$(id -gn)" "$TESTBED_ROOT/repos/$REPO_NAME" 2>/dev/null || true
            # Make repo tree world-writable so container services (cvmfs-prepub,
            # gateway) running as non-root users can write to the CAS and spool.
            # SKIP upstream-scratch — the gateway owns it (root) and it may be an
            # active bind mount, so a recursive chmod there fails with EPERM and
            # aborts init. It is set to 755 separately where it is (re)created.
            find "$TESTBED_ROOT/repos/$REPO_NAME" -path '*/upstream-scratch*' -prune -o -exec chmod 777 {} + 2>/dev/null || true

            # Copy server.conf so cvmfs_receiver can read it inside the gateway
            # container.  cvmfs_receiver::GetParamsFromFile() reads:
            #   /etc/cvmfs/repositories.d/<repo>/server.conf
            # The docker-compose.yml mounts config/repo-config/ there (read-only).
            _server_conf="/etc/cvmfs/repositories.d/$REPO_NAME/server.conf"
            if [[ -f "$_server_conf" ]]; then
                sudo cp "$_server_conf" "$TESTBED_ROOT/config/repo-config/server.conf"
                sudo chown "$USER:$(id -gn)" "$TESTBED_ROOT/config/repo-config/server.conf"
                chmod 644 "$TESTBED_ROOT/config/repo-config/server.conf"
                success "server.conf copied to config/repo-config/."

                # ── Patch CVMFS_UPSTREAM_STORAGE ─────────────────────────────────────────
                # cvmfs_server mkfs may set CVMFS_UPSTREAM_STORAGE to the gateway API URL
                # (e.g. "gw,/spool/tmp,http://localhost:4929/api/v1").  Inside the gateway
                # container the receiver runs AS PART OF the gateway, so contacting
                # localhost:4929 creates a deadlock: the gateway waits for the receiver
                # while the receiver waits for the gateway — each timing out after ~60 s.
                #
                # Override it to "local" mode so the receiver writes CAS objects directly
                # to /srv/cvmfs/<repo> (which IS the repo filesystem, mounted read-write
                # inside the gateway container).
                #
                # IMPORTANT — scratch dir must be on the SAME bind-mount as the CAS data
                # directory.  docker-compose.yml mounts two different host paths:
                #   /var/spool/cvmfs        ← ${TESTBED_ROOT}/data/gateway-spool
                #   /srv/cvmfs/<repo>       ← ${TESTBED_ROOT}/repos/<repo>
                # LocalUploader::FinalizeStreamedUpload calls rename(scratch→data/XY/hash).
                # rename() across different bind mounts fails with EXDEV (errno 18).
                # Placing upstream-scratch/ under /srv/cvmfs/<repo>/ (same mount as data/)
                # keeps rename() on a single filesystem, so it succeeds.
                #
                # Format: local,<scratch_dir>,<upstream_cas_root>
                _spool_dir="/srv/cvmfs/$REPO_NAME/upstream-scratch"
                _cas_root="/srv/cvmfs/$REPO_NAME"
                _new_upstream="local,${_spool_dir},${_cas_root}"

                if grep -q "^CVMFS_UPSTREAM_STORAGE=" "$TESTBED_ROOT/config/repo-config/server.conf"; then
                    _orig=$(grep "^CVMFS_UPSTREAM_STORAGE=" "$TESTBED_ROOT/config/repo-config/server.conf")
                    sed -i \
                        "s|^CVMFS_UPSTREAM_STORAGE=.*|CVMFS_UPSTREAM_STORAGE=${_new_upstream}|" \
                        "$TESTBED_ROOT/config/repo-config/server.conf"
                    info "Patched CVMFS_UPSTREAM_STORAGE in server.conf"
                    info "  was: $_orig"
                    info "  now: CVMFS_UPSTREAM_STORAGE=${_new_upstream}"
                else
                    # Append if not present.
                    echo "CVMFS_UPSTREAM_STORAGE=${_new_upstream}" >> "$TESTBED_ROOT/config/repo-config/server.conf"
                    info "Added CVMFS_UPSTREAM_STORAGE to server.conf: ${_new_upstream}"
                fi

                # The cp above overwrites the file, discarding the gate set
                # earlier.  UPSTREAM_STORAGE survived only because it is
                # re-patched here; the gate needs the same treatment.
                if ! grep -q "^CVMFS_GW_MKDIR_PARENTS=" "$TESTBED_ROOT/config/repo-config/server.conf"; then
                    echo "CVMFS_GW_MKDIR_PARENTS=true" >> "$TESTBED_ROOT/config/repo-config/server.conf"
                    info "Enabled CVMFS_GW_MKDIR_PARENTS in server.conf (post-copy)"
                fi

                # ── Patch CVMFS_STRATUM0 back to the container-facing URL ────────
                # mkfs ran on the host and therefore used the published Apache
                # port (see _MKFS_STRATUM0_URL).  Everything that reads
                # server.conf afterwards runs INSIDE the compose network, where
                # the service name is what resolves — so store that.  Both URLs
                # serve the same storage directory.
                for _sc in "$TESTBED_ROOT/config/repo-config/server.conf" \
                           "/etc/cvmfs/repositories.d/$REPO_NAME/server.conf"; do
                    [[ -f "$_sc" ]] || continue
                    if grep -q "^CVMFS_STRATUM0=" "$_sc" 2>/dev/null; then
                        sudo sed -i \
                            "s|^CVMFS_STRATUM0=.*|CVMFS_STRATUM0=${_CONTAINER_STRATUM0_URL}|" "$_sc"
                    else
                        echo "CVMFS_STRATUM0=${_CONTAINER_STRATUM0_URL}" | sudo tee -a "$_sc" >/dev/null
                    fi
                done
                info "Patched CVMFS_STRATUM0 → ${_CONTAINER_STRATUM0_URL} (container-facing)"

                # Pre-create the per-repo spool tree on the HOST.
                #
                # data/gateway-spool is bind-mounted to /var/spool/cvmfs inside the
                # gateway container.  It must contain client.local and reflog.chksum
                # for cvmfs_receiver to function at commit time.
                # The gateway container runs privileged, so a previous run may have
                # left this tree owned by root: a plain mkdir/chmod/touch then
                # fails with EPERM and (under `set -e`) aborts init right after a
                # perfectly successful mkfs.  Take ownership first when needed.
                _gspool="$TESTBED_ROOT/data/gateway-spool/$REPO_NAME"
                if [[ -e "$_gspool" && ! -w "$_gspool" ]]; then
                    warn "Spool dir is not writable (root-owned from a previous run) — taking ownership: $_gspool"
                    sudo chown -R "$USER:$(id -gn)" "$_gspool" 2>/dev/null || true
                fi
                mkdir -p "$_gspool" 2>/dev/null \
                    || sudo mkdir -p "$_gspool"
                chmod 755 "$_gspool" 2>/dev/null \
                    || sudo chmod 755 "$_gspool"

                # client.local — just needs to exist; truncated to zero at commit.
                touch "$_gspool/client.local" 2>/dev/null \
                    || { sudo touch "$_gspool/client.local"
                         sudo chown "$USER:$(id -gn)" "$_gspool/client.local"; }

                # reflog.chksum — must contain the hash written by cvmfs_server mkfs.
                # Copy from the host spool if available; fall back to an empty stub
                # (SigningTool will return kReflogChecksumMissing / kReflogMissing on
                # commit, but at least payload submission won't be affected).
                _host_chksum="/var/spool/cvmfs/$REPO_NAME/reflog.chksum"
                if [[ -f "$_host_chksum" ]]; then
                    sudo cp "$_host_chksum" "$_gspool/reflog.chksum"
                    sudo chown "$USER:$(id -gn)" "$_gspool/reflog.chksum"
                    chmod 644 "$_gspool/reflog.chksum"
                    info "Copied reflog.chksum from $_host_chksum"
                else
                    touch "$_gspool/reflog.chksum" 2>/dev/null \
                        || { sudo touch "$_gspool/reflog.chksum"
                             sudo chown "$USER:$(id -gn)" "$_gspool/reflog.chksum"; }
                    warn "Host reflog.chksum not found at $_host_chksum"
                    warn "Commit operations may fail with kMissingReflog until it is created."
                    warn "If cvmfs_server mkfs succeeded, re-run: sudo cp $_host_chksum $_gspool/reflog.chksum"
                fi

                # upstream-scratch/ lives under the CAS root so that rename() from
                # scratch→data/XY/hash stays on the same bind-mount (EXDEV fix).
                # repos/<repo> is the same host path as /srv/cvmfs/<repo> inside the
                # gateway container, so pre-creating it here is sufficient.
                # Same story as the spool above: the gateway owns this directory
                # once it has run, so fall back to sudo instead of aborting init.
                mkdir -p "$TESTBED_ROOT/repos/$REPO_NAME/upstream-scratch" 2>/dev/null \
                    || sudo mkdir -p "$TESTBED_ROOT/repos/$REPO_NAME/upstream-scratch"
                chmod 755 "$TESTBED_ROOT/repos/$REPO_NAME/upstream-scratch" 2>/dev/null \
                    || sudo chmod 755 "$TESTBED_ROOT/repos/$REPO_NAME/upstream-scratch"

                info "Pre-created spool files in $_gspool"
                info "Pre-created upstream-scratch in $TESTBED_ROOT/repos/$REPO_NAME/upstream-scratch"

                # ── Generate native-publisher/server.conf (gateway mode) ──────────────
                # Generate it here too so the first-time init (when the unconditional
                # patch block above had no server.conf yet) also produces the file.
                _native_up="gw,/var/spool/cvmfs/${REPO_NAME}/tmp,http://gateway:4929/api/v1"
                sed "s|^CVMFS_UPSTREAM_STORAGE=.*|CVMFS_UPSTREAM_STORAGE=${_native_up}|;
                     s|^CVMFS_USER=.*|CVMFS_USER=root|" \
                    "$TESTBED_ROOT/config/repo-config/server.conf" \
                    > "$TESTBED_ROOT/config/native-publisher/server.conf"
                chmod 644 "$TESTBED_ROOT/config/native-publisher/server.conf"
                info "Generated native-publisher/server.conf (${_native_up})."

                # client.conf — sourced by cvmfs_server ingest at startup.
                # mkfs has just written it to /etc/cvmfs/repositories.d/<repo>/;
                # copy it so the native-publisher container can source it from
                # its bind-mounted config directory.
                _mkfs_client_conf="/etc/cvmfs/repositories.d/${REPO_NAME}/client.conf"
                if [[ -f "$_mkfs_client_conf" ]]; then
                    sudo cp "$_mkfs_client_conf" \
                        "$TESTBED_ROOT/config/native-publisher/client.conf"
                    sudo chown "$USER:$(id -gn)" \
                        "$TESTBED_ROOT/config/native-publisher/client.conf"
                    chmod 644 "$TESTBED_ROOT/config/native-publisher/client.conf"
                    info "Copied native-publisher/client.conf from mkfs output."
                fi
            else
                warn "server.conf not found at $_server_conf — cvmfs_receiver will fail."
                warn "Copy manually: sudo cp $_server_conf $TESTBED_ROOT/config/repo-config/server.conf"
            fi

            success "CVMFS repository initialised."
        else
            warn "cvmfs_server mkfs failed — check output above."
            warn "Once fixed, re-run: ./testbed.sh init"
            # A failed mkfs may still have created part of the repository tree,
            # owned by the cvmfs user.  That tree is bind-mounted as
            # cvmfs-prepub's CAS root, so prepub (running as the unprivileged
            # `prepub` user) then dies on its startup probe with "permission
            # denied" and the API never comes up — which is what the user
            # actually sees, several steps later, as "cvmfs-prepub API not
            # reachable" followed by "Repository not initialised" from
            # bootstrap.  Apply the same permissions the success path does, so
            # a partial tree cannot masquerade as a prepub problem.
            if [[ -d "$TESTBED_ROOT/repos/$REPO_NAME" ]]; then
                warn "Repairing permissions on the partial repository tree so the"
                warn "failure stays visible as an mkfs failure (not a prepub crash)."
                sudo chown -R "$USER:$(id -gn)" "$TESTBED_ROOT/repos/$REPO_NAME" 2>/dev/null || true
                find "$TESTBED_ROOT/repos/$REPO_NAME" -path '*/upstream-scratch*' -prune -o \
                    -exec chmod 777 {} + 2>/dev/null || true
            fi
            warn "If the tree already existed, permissions can be repaired any time with:"
            warn "  ./testbed fix-perms"
        fi
    fi
fi

# ── Print next-steps summary ──────────────────────────────────────────────────

echo ""
echo "========================================================"
echo "  CVMFS-Prepub Testbed  —  Initialisation complete"
echo "========================================================"
echo "  Testbed root:         $TESTBED_ROOT"
echo "  Software root:        $SOFTWARE_ROOT"
echo "  .env file:            $ENV_FILE"
echo "  Repository:           $REPO_NAME"
echo "  API token (prepub):   ${PREPUB_API_TOKEN:0:16}...  (see $ENV_FILE for full value)"
echo "========================================================"
