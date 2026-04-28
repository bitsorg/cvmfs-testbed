#!/bin/bash
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

# Create test data
TEST_DIR=$(mktemp -d)
trap "rm -rf $TEST_DIR" EXIT

mkdir -p "$TEST_DIR/smoke/usr/share/test-pkg"
echo "hello cvmfs $(date)" > "$TEST_DIR/smoke/usr/share/test-pkg/hello.txt"

SMOKE_TAR="$TEST_DIR/smoke.tar.gz"
tar -czf "$SMOKE_TAR" -C "$TEST_DIR/smoke" .

echo "Created test tar: $SMOKE_TAR"

# Submit job
TAG_NAME="smoke-$(date +%Y%m%d-%H%M%S)"
echo "Submitting job with tag: $TAG_NAME"

RESPONSE=$(curl -s -X POST \
    -H "Authorization: Bearer ${PREPUB_API_TOKEN}" \
    -F "repo=${REPO_NAME}" \
    -F "path=test/smoke" \
    -F "tar=@${SMOKE_TAR}" \
    -F "tag_name=${TAG_NAME}" \
    "${PREPUB_URL}/api/v1/jobs")

JOB_ID=$(echo "$RESPONSE" | jq -r '.job_id // empty')

if [[ -z "$JOB_ID" ]]; then
    echo -e "${RED}Failed to submit job${NC}"
    echo "Response: $RESPONSE"
    exit 1
fi

echo "Job submitted: $JOB_ID"

# Poll for completion
MAX_ITERATIONS=60
ITERATION=0
SLEEP_INTERVAL=2

while [[ $ITERATION -lt $MAX_ITERATIONS ]]; do
    ITERATION=$((ITERATION + 1))

    JOB_STATUS=$(curl -s -X GET \
        -H "Authorization: Bearer ${PREPUB_API_TOKEN}" \
        "${PREPUB_URL}/api/v1/jobs/${JOB_ID}")

    STATE=$(echo "$JOB_STATUS" | jq -r '.state // empty')

    if [[ -z "$STATE" ]]; then
        echo "Warning: Could not parse job state, retrying..."
        sleep "$SLEEP_INTERVAL"
        continue
    fi

    echo "[$ITERATION/$MAX_ITERATIONS] Job state: $STATE"

    if [[ "$STATE" == "published" ]]; then
        echo -e "${GREEN}Job published successfully${NC}"
        echo "Final job response:"
        echo "$JOB_STATUS" | jq .
        exit 0
    elif [[ "$STATE" == "failed" ]] || [[ "$STATE" == "aborted" ]]; then
        echo -e "${RED}Job $STATE${NC}"
        echo "Final job response:"
        echo "$JOB_STATUS" | jq .
        exit 1
    fi

    sleep "$SLEEP_INTERVAL"
done

echo -e "${RED}Job timed out after ${MAX_ITERATIONS} iterations${NC}"
echo "Final job response:"
curl -s -X GET \
    -H "Authorization: Bearer ${PREPUB_API_TOKEN}" \
    "${PREPUB_URL}/api/v1/jobs/${JOB_ID}" | jq .
exit 1
