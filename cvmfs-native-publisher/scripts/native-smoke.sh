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
