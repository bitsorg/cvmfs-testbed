#!/bin/bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Configuration
NUM_JOBS=${NUM_JOBS:-5}
CONCURRENCY=${CONCURRENCY:-2}

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

echo "Starting stress test: NUM_JOBS=$NUM_JOBS CONCURRENCY=$CONCURRENCY"

# Create temp directory for test data
TEST_BASE=$(mktemp -d)
trap "rm -rf $TEST_BASE" EXIT

# Create test tars
declare -a JOB_IDS
declare -a JOB_TAGS

echo "Creating $NUM_JOBS test packages..."
for i in $(seq 1 "$NUM_JOBS"); do
    PKG_DIR="$TEST_BASE/package-$i"
    mkdir -p "$PKG_DIR/package-$i/v1.0"
    echo "Package $i content $(date)" > "$PKG_DIR/package-$i/v1.0/file.txt"

    TAR_FILE="$TEST_BASE/package-$i.tar.gz"
    tar -czf "$TAR_FILE" -C "$PKG_DIR" .
done

echo "Submitting $NUM_JOBS jobs with concurrency $CONCURRENCY..."

# Function to submit a single job
submit_job() {
    local job_num=$1
    local tag_name="stress-job-$job_num-$(date +%Y%m%d-%H%M%S)"
    local tar_file="$TEST_BASE/package-$job_num.tar.gz"

    local response=$(curl -s -X POST \
        -H "Authorization: Bearer ${PREPUB_API_TOKEN}" \
        -F "repo=${REPO_NAME}" \
        -F "path=test/stress/$job_num" \
        -F "tar=@${tar_file}" \
        -F "tag_name=${tag_name}" \
        "${PREPUB_URL}/api/v1/jobs")

    local job_id=$(echo "$response" | jq -r '.job_id // empty')

    if [[ -z "$job_id" ]]; then
        echo -e "${RED}Failed to submit job $job_num${NC}"
        return 1
    fi

    echo "$job_id $tag_name"
    return 0
}

# Function to wait for a job to complete
wait_for_job() {
    local job_id=$1
    local job_num=$2
    local max_iterations=120
    local iteration=0

    while [[ $iteration -lt $max_iterations ]]; do
        iteration=$((iteration + 1))

        local job_status=$(curl -s -X GET \
            -H "Authorization: Bearer ${PREPUB_API_TOKEN}" \
            "${PREPUB_URL}/api/v1/jobs/${job_id}")

        local state=$(echo "$job_status" | jq -r '.state // empty')

        if [[ -z "$state" ]]; then
            sleep 1
            continue
        fi

        if [[ "$state" == "published" ]]; then
            echo -e "${GREEN}Job $job_num ($job_id) published${NC}"
            return 0
        elif [[ "$state" == "failed" ]] || [[ "$state" == "aborted" ]]; then
            echo -e "${RED}Job $job_num ($job_id) $state${NC}"
            return 1
        fi

        sleep 1
    done

    echo -e "${RED}Job $job_num ($job_id) timed out${NC}"
    return 1
}

# Submit jobs with concurrency control
ACTIVE_JOBS=()
PUBLISHED=0
FAILED=0
JOB_COUNTER=1

# Submit initial batch
for i in $(seq 1 "$CONCURRENCY"); do
    if [[ $JOB_COUNTER -le $NUM_JOBS ]]; then
        result=$(submit_job "$JOB_COUNTER" 2>/dev/null) || result=""
        if [[ -n "$result" ]]; then
            ACTIVE_JOBS+=("$result")
        fi
        JOB_COUNTER=$((JOB_COUNTER + 1))
    fi
done

# Process remaining jobs
while [[ $JOB_COUNTER -le $NUM_JOBS ]] || [[ ${#ACTIVE_JOBS[@]} -gt 0 ]]; do
    # Check completed jobs
    for i in "${!ACTIVE_JOBS[@]}"; do
        job_data="${ACTIVE_JOBS[$i]}"
        job_id=$(echo "$job_data" | cut -d' ' -f1)
        job_num=$(echo "$job_data" | cut -d' ' -f3)

        job_status=$(curl -s -X GET \
            -H "Authorization: Bearer ${PREPUB_API_TOKEN}" \
            "${PREPUB_URL}/api/v1/jobs/${job_id}")

        state=$(echo "$job_status" | jq -r '.state // empty')

        if [[ "$state" == "published" ]]; then
            echo -e "${GREEN}[Completed] Job $job_num ($job_id) published${NC}"
            PUBLISHED=$((PUBLISHED + 1))
            unset 'ACTIVE_JOBS[$i]'

            # Submit next job if available
            if [[ $JOB_COUNTER -le $NUM_JOBS ]]; then
                result=$(submit_job "$JOB_COUNTER" 2>/dev/null) || result=""
                if [[ -n "$result" ]]; then
                    ACTIVE_JOBS+=("$result")
                fi
                JOB_COUNTER=$((JOB_COUNTER + 1))
            fi
        elif [[ "$state" == "failed" ]] || [[ "$state" == "aborted" ]]; then
            echo -e "${RED}[Failed] Job $job_num ($job_id) $state${NC}"
            FAILED=$((FAILED + 1))
            unset 'ACTIVE_JOBS[$i]'

            # Submit next job if available
            if [[ $JOB_COUNTER -le $NUM_JOBS ]]; then
                result=$(submit_job "$JOB_COUNTER" 2>/dev/null) || result=""
                if [[ -n "$result" ]]; then
                    ACTIVE_JOBS+=("$result")
                fi
                JOB_COUNTER=$((JOB_COUNTER + 1))
            fi
        fi
    done

    # Re-index array to remove gaps
    ACTIVE_JOBS=("${ACTIVE_JOBS[@]}")

    if [[ ${#ACTIVE_JOBS[@]} -gt 0 ]]; then
        sleep 2
    fi
done

# Print summary
echo ""
echo "=========================================="
echo "Stress Test Summary"
echo "=========================================="
echo "Total jobs submitted: $NUM_JOBS"
echo -e "${GREEN}Published: $PUBLISHED${NC}"
echo -e "${RED}Failed: $FAILED${NC}"
echo "=========================================="

if [[ $FAILED -eq 0 ]]; then
    exit 0
else
    exit 1
fi
