#!/usr/bin/env bash
# native-stress.sh — Stress test via sequential cvmfs_server ingest calls.
#
# Publishes NUM_JOBS packages to test/native/stress/<i>/ and reports a summary.
# Unlike the bits stress test (which is asynchronous), cvmfs_server ingest is
# synchronous: each call blocks until the gateway receiver has committed the
# transaction and signed the manifest.  Jobs therefore run sequentially.
#
# Environment:
#   REPO_NAME    — CVMFS repository FQDN (e.g. test.cvmfs.io)  [required]
#   NUM_JOBS     — Number of packages to publish (default: 5)
#   INGEST_ROOT  — Base sub-path for all packages (default: test/native/stress)
set -euo pipefail

: "${REPO_NAME:?REPO_NAME must be set}"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

NUM_JOBS="${NUM_JOBS:-5}"
INGEST_ROOT="${INGEST_ROOT:-test/native/stress}"

# Clear any stale session_token from a previously crashed ingest.
rm -f "/var/spool/cvmfs/${REPO_NAME}/session_token" \
      "/var/spool/cvmfs/${REPO_NAME}/stats.db"

echo "Starting native stress test: NUM_JOBS=${NUM_JOBS}"

# ── Build all test tars upfront ────────────────────────────────────────────────
TEST_BASE=$(mktemp -d)
trap 'rm -rf "${TEST_BASE}"' EXIT

echo "Creating ${NUM_JOBS} test packages..."
for (( i=1; i<=NUM_JOBS; i++ )); do
    PKG_DIR="${TEST_BASE}/package-${i}"
    mkdir -p "${PKG_DIR}/package-${i}/v1.0"
    echo "Package ${i} content $(date)" > "${PKG_DIR}/package-${i}/v1.0/file.txt"
    tar -cf "${TEST_BASE}/package-${i}.tar" -C "${PKG_DIR}" .
done

# ── Run ingests sequentially ───────────────────────────────────────────────────
PUBLISHED=0
FAILED=0
START_TS=$(date +%s)

for (( i=1; i<=NUM_JOBS; i++ )); do
    INGEST_PATH="${INGEST_ROOT}/${i}"
    JOB_TAR="${TEST_BASE}/package-${i}.tar"
    TAG="native-stress-${i}-$(date +%Y%m%d-%H%M%S)"

    echo "[Job ${i}/${NUM_JOBS}] Ingesting to ${REPO_NAME}:${INGEST_PATH} ..."
    if cvmfs_server ingest \
            -t "${JOB_TAR}" \
            -b "${INGEST_PATH}" \
            "${REPO_NAME}"; then
        echo -e "${GREEN}[Job ${i}/${NUM_JOBS}] Published${NC}"
        PUBLISHED=$(( PUBLISHED + 1 ))
    else
        echo -e "${RED}[Job ${i}/${NUM_JOBS}] Failed${NC}"
        FAILED=$(( FAILED + 1 ))
    fi
done

END_TS=$(date +%s)
ELAPSED=$(( END_TS - START_TS ))

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=========================================="
echo "  Native Stress Test Summary"
echo "=========================================="
printf "  Total jobs:  %d\n" "${NUM_JOBS}"
echo -e "  ${GREEN}Published:   ${PUBLISHED}${NC}"
echo -e "  ${RED}Failed:      ${FAILED}${NC}"
printf "  Elapsed:     %ds\n" "${ELAPSED}"
if (( NUM_JOBS > 0 && ELAPSED > 0 )); then
    printf "  Throughput:  %.2f jobs/min\n" "$(echo "scale=2; ${NUM_JOBS} * 60 / ${ELAPSED}" | bc)"
fi
echo "=========================================="

[[ ${FAILED} -eq 0 ]] && exit 0 || exit 1
