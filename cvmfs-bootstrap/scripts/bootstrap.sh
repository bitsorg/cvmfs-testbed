#!/usr/bin/env bash
# bootstrap.sh — Seed the CVMFS repository with the nested-catalog structure
#                required by cvmfs_server ingest -b <path>.
#
# Runs inside the cvmfs-bootstrap container which shares the Docker network with
# the gateway and stratum0 containers, so "gateway" and "stratum0" resolve via
# Docker DNS.
#
# Strategy: use cvmfs_server ingest -c (create-catalog) at the nested catalog
# base path.  The -c flag passes -C true to cvmfs_swissknife ingest, which
# creates a new nested catalog at the target path in a single atomic operation.
# This avoids FUSE mounts entirely — swissknife downloads the current root
# catalog from stratum0 via HTTP and sends changes directly to the gateway
# receiver.
#
# Why NOT use .cvmfsdirtab (root-level ingest with -b ""):
#   a) cvmfs_server ingest argument parsing uses "while [ "$2" != "" ]" so an
#      empty -b "" causes the loop to exit early; the repo name ends up as "-b"
#      and the command fails with "transaction on repository -b".
#   b) Even if the root ingest worked, mountless gateway ingest explicitly
#      aborts if .cvmfsdirtab already exists in the published repo:
#      "Mountless gateway ingest does not yet support a published .cvmfsdirtab"
#      — meaning native-smoke.sh would fail on every subsequent run.
#
# What this script does:
#   1. Stages CVMFS binaries from SOFTWARE_ROOT to a writable tmpfs location.
#   2. Sets capabilities on cvmfs_publish (needed for signing even in ingest mode).
#   3. Checks idempotency via a sentinel file in the CAS root.
#   4. Creates a minimal bootstrap tar: a placeholder file under NESTED_CATALOG_PATH.
#   5. Runs: cvmfs_server ingest -c -t <tar> -b <path> <repo>
#      -c creates the nested catalog at <path>; no FUSE mount required.
#   6. Writes a sentinel file so subsequent runs skip the ingest.
#
# Environment (all have defaults; only REPO_NAME is required):
#   REPO_NAME             CVMFS repository FQDN        (e.g. test.cvmfs.io)
#   SOFT_RO               Path to CVMFS binaries inside the container
#                         (default: /opt/cvmfs-software, mounted ro from SOFTWARE_ROOT)
#   NESTED_CATALOG_PATH   Sub-path to create as a nested catalog
#                         (default: test/native/smoke)
#
# Volume expectations (set in docker-compose.yml):
#   /opt/cvmfs-software          ← ${SOFTWARE_ROOT}          (ro)
#   /etc/cvmfs/keys              ← config/keys               (ro)
#   /etc/cvmfs/repositories.d/${REPO_NAME}
#                                ← config/native-publisher   (ro)
#   /srv/cvmfs/${REPO_NAME}      ← repos/${REPO_NAME}        (rw)
#   /var/spool/cvmfs             ← data/bootstrap-spool      (rw)
#
# The script is idempotent: a sentinel file written on success prevents
# re-running the ingest on subsequent container invocations.

set -euo pipefail

: "${REPO_NAME:?REPO_NAME must be set}"
SOFT_RO="${SOFT_RO:-/opt/cvmfs-software}"
NESTED_CATALOG_PATH="${NESTED_CATALOG_PATH:-test/native/smoke}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERR ]${NC}  $*" >&2; exit 1; }

# ── 1. Stage binaries to a writable tmpfs ─────────────────────────────────────
# SOFTWARE_ROOT is mounted read-only; setcap requires write access.
# Copy just the needed binaries to /run/cvmfs-bin (tmpfs inside the container).
SOFT_BIN=/run/cvmfs-bin
mkdir -p "$SOFT_BIN"

info "Staging CVMFS binaries from $SOFT_RO → $SOFT_BIN ..."
for bin in cvmfs_server cvmfs_publish cvmfs_publish_debug cvmfs_swissknife cvmfs_suid_helper cvmfs2; do
    src="$SOFT_RO/$bin"
    if [[ -f "$src" ]]; then
        cp -a "$src" "$SOFT_BIN/$bin"
        info "  staged $bin"
    else
        warn "  $bin not found in $SOFT_RO — skipping"
    fi
done

# cvmfs_server in CVMFS_TESTBED mode constructs the binary path as
# $CVMFS_TESTBED_SOFTWARE_ROOT/cvmfs_publish_debug.  Release builds don't
# include it; provide a fallback symlink so the script doesn't abort.
if [[ ! -f "$SOFT_BIN/cvmfs_publish_debug" ]]; then
    ln -sf "$SOFT_BIN/cvmfs_publish" "$SOFT_BIN/cvmfs_publish_debug"
    info "  symlinked cvmfs_publish_debug → cvmfs_publish (release build)"
fi

# Shared libraries: copy to a writable location so the dynamic linker finds them.
info "Staging shared libraries ..."
find "$SOFT_RO" -maxdepth 1 \( -name "libcvmfs_*.so*" -o -name "libfuse3.so*" \) \
    -exec cp -a {} "$SOFT_BIN/" \;

export PATH="$SOFT_BIN:$PATH"
export LD_LIBRARY_PATH="$SOFT_BIN:${LD_LIBRARY_PATH:-}"
export CVMFS_TESTBED=true
export CVMFS_TESTBED_SOFTWARE_ROOT="$SOFT_BIN"

# ── 2. Set capabilities on staged binaries ────────────────────────────────────
# cvmfs_publish needs cap_sys_admin for the manifest signing step.
# In gateway-mode ingest the FUSE overlay is not used, but signing still runs.
info "Setting capabilities on staged binaries ..."
setcap cap_sys_admin+ep  "$SOFT_BIN/cvmfs_publish"      2>/dev/null || warn "setcap cvmfs_publish skipped"
setcap cap_sys_admin+ep  "$SOFT_BIN/cvmfs_publish_debug" 2>/dev/null || true
setcap cap_sys_admin+ep  "$SOFT_BIN/cvmfs2"              2>/dev/null || warn "setcap cvmfs2 skipped"
chmod u+s                "$SOFT_BIN/cvmfs_suid_helper"   2>/dev/null || warn "chmod u+s cvmfs_suid_helper skipped"

# ── 3. Idempotency check ──────────────────────────────────────────────────────
# A sentinel file written by a successful previous run signals "already done".
# The sentinel lives in the CAS root (mounted rw from repos/<repo>/) so it
# survives snapshots and restores alongside the repository data.
SENTINEL="/srv/cvmfs/${REPO_NAME}/.bootstrap_complete"
if [[ -f "$SENTINEL" ]]; then
    success "Bootstrap sentinel found — nested catalog /${NESTED_CATALOG_PATH} already created."
    exit 0
fi

info "No bootstrap sentinel found — running bootstrap ingest."

# ── 4. Create bootstrap tar ───────────────────────────────────────────────────
# The tar contains a placeholder file under NESTED_CATALOG_PATH.
# The -c flag (--catalog) tells cvmfs_swissknife ingest to create a new nested
# catalog at the base path, so no pre-existing catalog structure is required.
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

info "Building bootstrap tar ..."
mkdir -p "$WORK_DIR/${NESTED_CATALOG_PATH}"
echo "bootstrap placeholder — safe to overwrite" \
    > "$WORK_DIR/${NESTED_CATALOG_PATH}/.cvmfs_nested_placeholder"

CATALOG_TAR="$WORK_DIR/catalog_setup.tar"
tar -C "$WORK_DIR" -cf "$CATALOG_TAR" "${NESTED_CATALOG_PATH}"
info "  tar size: $(du -sh "$CATALOG_TAR" | cut -f1)"

# ── 5. Ingest with -c to create nested catalog ────────────────────────────────
# cvmfs_server ingest -c passes -C true to cvmfs_swissknife ingest, which
# calls CreateNestedCatalog at the base path.  This is a single atomic
# gateway transaction — no FUSE mount required.
#
# Note: the argument parsing in cvmfs_server_ingest.sh uses a
#   "while [ "$2" != "" ]" loop, so -b "" (empty string) would terminate
#   the loop early and leave the repo name unresolved.  Always pass a
#   non-empty base path.
info "Running: cvmfs_server ingest -c -b ${NESTED_CATALOG_PATH} -t $CATALOG_TAR $REPO_NAME"
if cvmfs_server ingest \
        -c \
        -t "$CATALOG_TAR" \
        -b "${NESTED_CATALOG_PATH}" \
        "$REPO_NAME"; then
    success "Ingest with catalog creation complete."
    success "Nested catalog /${NESTED_CATALOG_PATH} created in repository ${REPO_NAME}."
    # Write sentinel so subsequent container runs skip the ingest.
    touch "$SENTINEL"
    success "Bootstrap complete.  Repository ${REPO_NAME} is ready for cvmfs_server ingest."
else
    die "cvmfs_server ingest failed — see output above."
fi
