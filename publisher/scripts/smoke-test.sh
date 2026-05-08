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
#   INGEST_PATH      — sub-path within the repo (default: test/smoke)
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

INGEST_PATH="${INGEST_PATH:-test/smoke}"

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

echo "Building comprehensive test payload..."
bash /scripts/make-test-payload.sh "$WORK_DIR"

SMOKE_TAR="$WORK_DIR/payload.tar"

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

# Stream state changes via SSE instead of polling.
# The endpoint emits "data: {\"state\":\"...\"}" lines whenever the job
# transitions.  curl -N streams indefinitely; we break on the first terminal
# state.  --max-time 300 is a hard safety cap (5 min) in case the server
# closes the stream without sending a terminal event.
SSE_URL="${PREPUB_URL}/api/v1/jobs/${JOB_ID}/events"
echo "Watching SSE stream: $SSE_URL"

FINAL_STATE=""
while IFS= read -r line; do
    # SSE lines look like:  data: {"job_id":"...","state":"leased",...}
    [[ "$line" == data:* ]] || continue
    json="${line#data: }"
    state=$(echo "$json" | jq -r '.state // empty' 2>/dev/null) || continue
    [[ -n "$state" ]] || continue

    echo "  → $state"

    case "$state" in
        published)
            FINAL_STATE="published"
            break ;;
        failed|aborted)
            FINAL_STATE="$state"
            break ;;
    esac
done < <(curl -sN --no-buffer --max-time 300 \
             -H "Authorization: Bearer ${PREPUB_API_TOKEN}" \
             "$SSE_URL")

# If SSE closed without a terminal state (e.g. server restarted mid-flight),
# fall back to a single status fetch so we don't misreport.
if [[ -z "$FINAL_STATE" ]]; then
    echo "SSE stream closed without terminal state — fetching current status..."
    JOB_STATUS=$(curl -sf --max-time 10 \
        -H "Authorization: Bearer ${PREPUB_API_TOKEN}" \
        "${PREPUB_URL}/api/v1/jobs/${JOB_ID}") || JOB_STATUS=""
    FINAL_STATE=$(echo "$JOB_STATUS" | jq -r '.state // empty')
fi

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
