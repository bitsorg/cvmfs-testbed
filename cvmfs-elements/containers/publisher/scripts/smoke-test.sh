#!/usr/bin/env bash
# smoke-test.sh — Comprehensive smoke test via the cvmfs-prepub REST API.
#
# Publishes a rich test payload to test/smoke using the cvmfs-bits publishing
# path (cvmfs-prepub REST API → gateway → cvmfs_receiver → signed manifest).
#
# The payload (built by make-test-payload.sh) exercises catalog corner cases:
#   directory hierarchy, hard links, symlinks, large file (chunking), unusual
#   file names (spaces, unicode, special chars), permission modes, empty dirs.
#
# Compare against cvmfs-native-publisher/scripts/native-smoke.sh which uses
# cvmfs_server ingest — both scripts use the same payload for a fair comparison.
#
# Environment:
#   PREPUB_API_TOKEN — bearer token for the cvmfs-prepub API  [required]
#   PREPUB_URL       — base URL of the cvmfs-prepub service    [required]
#   REPO_NAME        — CVMFS repository FQDN                   [required]
#   INGEST_PATH      — sub-path within the repo (default: test/smoke.<n>, fresh per run)
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Validate environment
if [[ -z "${PREPUB_API_TOKEN:-}" ]]; then
    echo "Error: PREPUB_API_TOKEN not set"
    exit 1
fi

if [[ -z "${PREPUB_URL:-}" ]]; then
    echo "Error: PREPUB_URL not set"
    exit 1
fi

if [[ -z "${REPO_NAME:-}" ]]; then
    echo "Error: REPO_NAME not set"
    exit 1
fi

# Publish to a FRESH path each run (test/smoke.<n>) so re-runs never collide.
# Re-publishing the same path grafts a second nested catalog onto an existing
# directory, which makes the gateway commit panic ("invalid attempt to graft
# nested catalog into existing directory '/test/smoke'"). The index comes from
# the host-persisted run log: it advances on every run (success and failure
# both append a line) and resets together with the repo on `make clean`.
if [[ -z "${INGEST_PATH:-}" ]]; then
    _smoke_seq=0
    if [[ -r "${RUN_LOG_FILE:-/data/runs.ndjson}" ]]; then
        _smoke_seq=$(grep -c '' "${RUN_LOG_FILE:-/data/runs.ndjson}" 2>/dev/null || echo 0)
    fi
    [[ "$_smoke_seq" =~ ^[0-9]+$ ]] || _smoke_seq=0
    INGEST_PATH="test/smoke.${_smoke_seq}"
fi

# Run log — when set (mounted from host), the completed test run is appended
# as a single JSON line so the testbed console can display run history.
RUN_LOG_FILE="${RUN_LOG_FILE:-/data/runs.ndjson}"

# ── Run recording helper ───────────────────────────────────────────────────────
log_run() {
    local run_id="$1" method="$2" test_type="$3"
    local n_req="$4"  n_pub="$5"  n_fail="$6"
    local start_ts="$7" end_ts="$8" elapsed_s="$9"
    [[ -n "${RUN_LOG_FILE:-}" ]] || return 0
    local start_time end_time
    start_time="$(date -u -d "@${start_ts}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
               || date -u -r "${start_ts}" +%Y-%m-%dT%H:%M:%SZ)"
    end_time="$(date -u -d "@${end_ts}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
             || date -u -r "${end_ts}" +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"run_id":"%s","method":"%s","test_type":"%s","n_requested":%d,"n_published":%d,"n_failed":%d,"start_time":"%s","end_time":"%s","duration_s":%d,"avg_s":%d,"min_s":%d,"max_s":%d,"p50_s":%d,"p95_s":%d,"throughput_per_min":0}\n' \
        "$run_id" "$method" "$test_type" \
        "$n_req" "$n_pub" "$n_fail" \
        "$start_time" "$end_time" \
        "$elapsed_s" "$elapsed_s" "$elapsed_s" "$elapsed_s" "$elapsed_s" "$elapsed_s" \
        >> "$RUN_LOG_FILE" 2>/dev/null || true
}

# ── Build comprehensive test payload ───────────────────────────────────────────
WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT

# ADR-0001: prefer the shared canonical payload (generated once host-side) so
# the bits and native-ingest paths ingest byte-identical input. The bits
# container lacks openssl and cannot regenerate; it requires the shared tar.
SHARED_PAYLOAD="${SHARED_PAYLOAD:-/data/payload/payload.tar}"
if [[ -f "$SHARED_PAYLOAD" ]]; then
    echo "Using shared canonical payload: $SHARED_PAYLOAD"
    SMOKE_TAR="$SHARED_PAYLOAD"
else
    echo "Building comprehensive test payload (shared tar absent)..."
    bash /scripts/make-test-payload.sh "$WORK_DIR"
    SMOKE_TAR="$WORK_DIR/payload.tar"
fi

echo ""
echo "Created test tar: $SMOKE_TAR  ($(du -sh "$SMOKE_TAR" | cut -f1))"

# Submit job
START_TS=$(date +%s)
TAG_NAME="smoke-$(date +%Y%m%d-%H%M%S)"
echo "Submitting job: repo=${REPO_NAME} path=${INGEST_PATH} tag=${TAG_NAME}"

RESPONSE=$(curl -sf --max-time 120 \
    -X POST \
    -H "Authorization: Bearer ${PREPUB_API_TOKEN}" \
    -F "repo=${REPO_NAME}" \
    -F "path=${INGEST_PATH}" \
    -F "tar=@${SMOKE_TAR}" \
    -F "tag_name=${TAG_NAME}" \
    "${PREPUB_URL}/api/v1/jobs") || RESPONSE=""

JOB_ID=$(echo "$RESPONSE" | jq -r '.job_id // empty')

if [[ -z "$JOB_ID" ]]; then
    echo -e "${RED}Failed to submit job${NC}"
    echo "Response: $RESPONSE"
    exit 1
fi

echo "Job submitted: $JOB_ID"

# Poll the job state until terminal or timeout. Polling is race-free; the SSE
# event stream could miss a fast publish's "published" event (fired before the
# watch connects), which left the curl blocked for its full --max-time (hang).
echo "Polling job state: ${PREPUB_URL}/api/v1/jobs/${JOB_ID}"
FINAL_STATE=""
_deadline=$(( $(date +%s) + 120 ))
while [[ $(date +%s) -lt $_deadline ]]; do
    _st=$(curl -sf --max-time 10 -H "Authorization: Bearer ${PREPUB_API_TOKEN}" "${PREPUB_URL}/api/v1/jobs/${JOB_ID}" | jq -r '.state // empty' 2>/dev/null)
    case "$_st" in
        published)      FINAL_STATE="published"; echo "  -> published"; break ;;
        failed|aborted) FINAL_STATE="$_st"; echo "  -> $_st"; break ;;
    esac
    sleep 1
done

JOB_STATUS=$(curl -sf --max-time 10 \
    -H "Authorization: Bearer ${PREPUB_API_TOKEN}" \
    "${PREPUB_URL}/api/v1/jobs/${JOB_ID}") || JOB_STATUS=""

END_TS=$(date +%s)
ELAPSED=$(( END_TS - START_TS ))
RUN_ID="bits-smoke-${TAG_NAME#smoke-}"

case "$FINAL_STATE" in
    published)
        echo -e "${GREEN}Job published successfully${NC}"
        echo "$JOB_STATUS" | jq .
        log_run "$RUN_ID" "bits" "smoke" 1 1 0 "$START_TS" "$END_TS" "$ELAPSED"
        echo ""
        echo "Expected paths (sample):"
        echo "  /cvmfs/${REPO_NAME}/${INGEST_PATH}/simple/hello.txt"
        echo "  /cvmfs/${REPO_NAME}/${INGEST_PATH}/large/large-20m.bin"
        echo "  /cvmfs/${REPO_NAME}/${INGEST_PATH}/links/hardlink.txt"
        echo "  /cvmfs/${REPO_NAME}/${INGEST_PATH}/unusual-names/unicode-日本語.txt"
        exit 0 ;;
    failed|aborted)
        echo -e "${RED}Job ${FINAL_STATE}${NC}"
        echo "$JOB_STATUS" | jq .
        log_run "$RUN_ID" "bits" "smoke" 1 0 1 "$START_TS" "$END_TS" "$ELAPSED"
        exit 1 ;;
    *)
        echo -e "${RED}Job timed out or stream ended without terminal state (last: ${FINAL_STATE:-unknown})${NC}"
        echo "$JOB_STATUS" | jq .
        log_run "$RUN_ID" "bits" "smoke" 1 0 1 "$START_TS" "$END_TS" "$ELAPSED"
        exit 1 ;;
esac
