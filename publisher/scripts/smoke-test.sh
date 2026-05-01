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

# ── Build comprehensive test payload ───────────────────────────────────────────
WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT

echo "Building comprehensive test payload..."
bash /scripts/make-test-payload.sh "$WORK_DIR"

SMOKE_TAR="$WORK_DIR/payload.tar"

echo ""
echo "Created test tar: $SMOKE_TAR  ($(du -sh "$SMOKE_TAR" | cut -f1))"

# Submit job
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

case "$FINAL_STATE" in
    published)
        echo -e "${GREEN}Job published successfully${NC}"
        echo "$JOB_STATUS" | jq .
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
        exit 1 ;;
    *)
        echo -e "${RED}Job timed out or stream ended without terminal state (last: ${FINAL_STATE:-unknown})${NC}"
        echo "$JOB_STATUS" | jq .
        exit 1 ;;
esac
