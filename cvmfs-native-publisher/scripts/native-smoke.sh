#!/usr/bin/env bash
# native-smoke.sh — Comprehensive smoke test via cvmfs_server ingest.
#
# Publishes a rich test payload to test/native/smoke using the native CVMFS
# gateway workflow (cvmfs_server ingest → cvmfs_swissknife → gateway API →
# cvmfs_receiver → signed manifest).
#
# The payload (built by make-test-payload.sh) exercises catalog corner cases:
#   directory hierarchy, symlinks, large file (chunking), unusual file names
#   (spaces, unicode, special chars), permission modes, empty dirs.
#
# Compare against publisher/scripts/smoke-test.sh which uses the cvmfs-bits
# (cvmfs-prepub) REST API path — both use the same payload for a fair comparison.
#
# Environment:
#   REPO_NAME    — CVMFS repository FQDN (e.g. test.cvmfs.io)  [required]
#   INGEST_BASE  — Base path within the repo (default: test/native/smoke)
#
# Pre-condition:
#   INGEST_BASE must already be a nested catalog root in the repository.
#   This is seeded once by the cvmfs-bootstrap container (./testbed.sh bootstrap)
#   and captured in repo-seed.tar.gz.  cmd_start auto-restores the snapshot, so
#   by the time this script runs the nested catalog already exists.
#   Without that pre-setup the gateway receiver panics on commit:
#   "catalog for directory '/<path>' cannot be found".
set -euo pipefail

: "${REPO_NAME:?REPO_NAME must be set}"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

INGEST_BASE="${INGEST_BASE:-test/native/smoke}"

# ── Clear stale transaction state ─────────────────────────────────────────────
# A session_token left by a previously crashed ingest causes the gateway to reject
# the next payload upload ("broken pipe").  Remove it unconditionally before each run.
_SPOOL="/var/spool/cvmfs/${REPO_NAME}"
rm -f "${_SPOOL}/session_token" "${_SPOOL}/stats.db"

# ── Stub rdonly for pre-existing catalog path components ─────────────────────
# In mountless gateway ingest mode the rdonly filesystem (${_SPOOL}/rdonly) is
# an empty directory — no FUSE overlay is mounted.  SyncItemNative::GetRdOnlyFiletype()
# stats this path to decide whether a directory is "new".  If it doesn't exist
# in rdonly, IsNew() returns true and CreateDirectories() calls AddDirectory for
# every ancestor of INGEST_BASE, including those already committed to the CVMFS
# catalog by a prior bootstrap ingest.  WritableCatalog::AddEntry then asserts
# because the SQL INSERT finds a duplicate path.
#
# Stub directories at each path component make GetRdOnlyFiletype() return
# kItemDir → IsNew() = false → CreateDirectories skips the duplicate AddDirectory.
# These stubs must cover every component of INGEST_BASE (inclusive), because
# CreateDirectories recurses all the way to the root for each tar entry.
_rdonly="${_SPOOL}/rdonly"
_path=""
IFS='/' read -ra _components <<< "${INGEST_BASE}"
for _c in "${_components[@]}"; do
    _path="${_path:+${_path}/}${_c}"
    mkdir -p "${_rdonly}/${_path}"
done
unset _rdonly _path _components _c

# ── Build comprehensive test payload ───────────────────────────────────────────
WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT

echo "Building comprehensive test payload..."
bash /scripts/make-test-payload.sh "$WORK_DIR"

PAYLOAD_TAR="$WORK_DIR/payload.tar"

echo ""
echo "Ingesting to ${REPO_NAME}:${INGEST_BASE} ..."
echo "  Tar size: $(du -sh "$PAYLOAD_TAR" | cut -f1)"

# ── Run native ingest ──────────────────────────────────────────────────────────
# cvmfs_server ingest is synchronous: acquires a gateway lease, builds the
# catalog via cvmfs_swissknife, commits via the gateway receiver, returns
# when the repository manifest has been updated and signed.
#
# Flags:
#   -t <tar>   tar file to publish
#   -b <base>  destination sub-path within the repository (nested catalog root)
if cvmfs_server ingest \
        -t "${PAYLOAD_TAR}" \
        -b "${INGEST_BASE}" \
        "${REPO_NAME}"; then
    echo ""
    echo -e "${GREEN}Native ingest complete${NC}"
    echo ""
    echo "Expected paths (sample):"
    echo "  /cvmfs/${REPO_NAME}/${INGEST_BASE}/simple/hello.txt"
    echo "  /cvmfs/${REPO_NAME}/${INGEST_BASE}/large/large-8m.bin"
    echo "  /cvmfs/${REPO_NAME}/${INGEST_BASE}/links/rel-symlink-to-hello"
    echo "  /cvmfs/${REPO_NAME}/${INGEST_BASE}/unusual-names/unicode-日本語.txt"
    exit 0
else
    echo ""
    echo -e "${RED}Native ingest failed${NC}"
    exit 1
fi
