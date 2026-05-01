#!/usr/bin/env bash
# bootstrap.sh — Seed the CVMFS repository with the nested-catalog structure
#                required by cvmfs_server ingest -b <path>.
#
# Runs inside a privileged Docker container (cvmfs-bootstrap) that is on the
# same Docker network as the gateway and stratum0 containers, so Docker DNS
# resolves "gateway" and "stratum0" correctly.  The container has SYS_ADMIN
# capability (via --privileged) for the OverlayFS + FUSE mount that
# cvmfs_server transaction sets up at /cvmfs/<repo>.
#
# What this script does:
#   1. Stages CVMFS binaries to a writable tmpfs location and sets capabilities
#      (setcap / chmod u+s) so cvmfs_server works without altering SOFTWARE_ROOT.
#   2. Opens a cvmfs_server transaction.
#   3. Writes .cvmfsdirtab registering NESTED_CATALOG_PATH as a nested catalog.
#   4. Creates a placeholder file inside that path so the directory gets a
#      catalog entry (required by the gateway receiver).
#   5. Publishes the transaction — the receiver grafts the nested catalog into
#      the manifest, making the path usable as an ingest lease target.
#
# Environment (all have defaults; only REPO_NAME is required):
#   REPO_NAME             CVMFS repository FQDN        (e.g. test.cvmfs.io)
#   SOFTWARE_ROOT         Host path to CVMFS binaries, mounted RO into the
#                         container at /opt/cvmfs-software  (default: that path)
#   NESTED_CATALOG_PATH   Sub-path to register          (default: test/native/smoke)
#
# Volume expectations (set in docker-compose.yml):
#   /opt/cvmfs-software          ← ${SOFTWARE_ROOT}          (ro)
#   /etc/cvmfs/keys              ← config/keys               (ro)
#   /etc/cvmfs/repositories.d/${REPO_NAME}
#                                ← config/native-publisher   (ro)
#   /srv/cvmfs/${REPO_NAME}      ← repos/${REPO_NAME}        (rw)
#   /var/spool/cvmfs             ← data/bootstrap-spool      (rw)
#
# The script is idempotent: if the nested catalog path already appears in
# .cvmfsdirtab it skips the transaction and exits 0.

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
# SOFTWARE_ROOT is mounted read-only; setcap and chmod u+s require write access.
# Copy just the needed binaries to /run/cvmfs-bin (backed by tmpfs inside the
# container — no changes are made to the host's SOFTWARE_ROOT).
SOFT_BIN=/run/cvmfs-bin
mkdir -p "$SOFT_BIN"

info "Staging CVMFS binaries from $SOFT_RO → $SOFT_BIN ..."
for bin in cvmfs_server cvmfs_publish cvmfs_swissknife cvmfs_suid_helper cvmfs2; do
    src="$SOFT_RO/$bin"
    if [[ -f "$src" ]]; then
        cp "$src" "$SOFT_BIN/$bin"
        info "  staged $bin"
    else
        warn "  $bin not found in $SOFT_RO — skipping"
    fi
done

# Shared libraries: copy to a writable location so the dynamic linker finds them.
info "Staging shared libraries ..."
find "$SOFT_RO" -maxdepth 1 \( -name "libcvmfs_*.so*" -o -name "libfuse3.so*" \) \
    -exec cp -a {} "$SOFT_BIN/" \;

export PATH="$SOFT_BIN:$PATH"
export LD_LIBRARY_PATH="$SOFT_BIN:${LD_LIBRARY_PATH:-}"
export CVMFS_TESTBED=true
export CVMFS_TESTBED_SOFTWARE_ROOT="$SOFT_BIN"

# ── 2. Set capabilities on staged binaries ────────────────────────────────────
# cvmfs_publish needs cap_sys_admin for the atomic rename into the CAS.
# cvmfs_suid_helper needs setuid root so non-root processes can use the FUSE
# client (not needed when running as root but harmless to set).
# With --privileged these are largely no-ops, but cvmfs_server checks for them.
info "Setting capabilities on staged binaries ..."
setcap cap_sys_admin+ep  "$SOFT_BIN/cvmfs_publish"      2>/dev/null || warn "setcap cvmfs_publish skipped"
setcap cap_sys_admin+ep  "$SOFT_BIN/cvmfs2"             2>/dev/null || warn "setcap cvmfs2 skipped"
chmod u+s                "$SOFT_BIN/cvmfs_suid_helper"  2>/dev/null || warn "chmod u+s cvmfs_suid_helper skipped"

# ── 3. Idempotency check ──────────────────────────────────────────────────────
# Read the current .cvmfsdirtab directly from the CAS (the live filesystem at
# /srv/cvmfs/<repo> which is read-only from the bootstrap's perspective until
# a transaction opens it).
DIRTAB_HINT="/srv/cvmfs/${REPO_NAME}/.cvmfsdirtab"
if [[ -f "$DIRTAB_HINT" ]] && grep -qxF "/${NESTED_CATALOG_PATH}" "$DIRTAB_HINT" 2>/dev/null; then
    success "Nested catalog /${NESTED_CATALOG_PATH} already registered — nothing to do."
    exit 0
fi

info "No existing nested catalog at /${NESTED_CATALOG_PATH} — running bootstrap transaction."

# ── 4. Open transaction ───────────────────────────────────────────────────────
info "Opening transaction on ${REPO_NAME} ..."
cvmfs_server transaction "${REPO_NAME}"

# /cvmfs/${REPO_NAME} is now an OverlayFS read-write mount.
CVMFS_MOUNT="/cvmfs/${REPO_NAME}"

# ── 5. Write .cvmfsdirtab and placeholder ─────────────────────────────────────
info "Registering /${NESTED_CATALOG_PATH} in .cvmfsdirtab ..."
DIRTAB="${CVMFS_MOUNT}/.cvmfsdirtab"
if ! grep -qxF "/${NESTED_CATALOG_PATH}" "$DIRTAB" 2>/dev/null; then
    echo "/${NESTED_CATALOG_PATH}" >> "$DIRTAB"
fi

mkdir -p "${CVMFS_MOUNT}/${NESTED_CATALOG_PATH}"
# A placeholder file ensures the directory has a catalog entry.
# cvmfs_server ingest will overwrite this path on the first real ingest.
echo "bootstrap placeholder — safe to overwrite" \
    > "${CVMFS_MOUNT}/${NESTED_CATALOG_PATH}/.cvmfs_nested_placeholder"

# ── 6. Publish ────────────────────────────────────────────────────────────────
info "Publishing transaction ..."
cvmfs_server publish -a "bootstrap-nested-catalog" "${REPO_NAME}"

success "Nested catalog /${NESTED_CATALOG_PATH} created and published."
success "Bootstrap complete.  Repository ${REPO_NAME} is ready for cvmfs_server ingest."
