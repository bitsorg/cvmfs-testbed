#!/usr/bin/env bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
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
# Single-quoted trap: $TEST_BASE is expanded at trap-fire time, not at definition time.
trap 'rm -rf "${TEST_BASE}"' EXIT

echo "Creating $NUM_JOBS test packages..."
for (( i=1; i<=NUM_JOBS; i++ )); do
    PKG_DIR="$TEST_BASE/package-$i"
    mkdir -p "$PKG_DIR/package-$i/v1.0"
    echo "Package $i content $(date)" > "$PKG_DIR/package-$i/v1.0/file.txt"

    TAR_FILE="$TEST_BASE/package-$i.tar.gz"
    tar -czf "$TAR_FILE" -C "$PKG_DIR" .
done

echo "Submitting $NUM_JOBS jobs with concurrency $CONCURRENCY..."

# Function to submit a single job.
# Outputs "$job_id $tag_name $job_num" on success so callers can cut -f1/-f2/-f3.
submit_job() {
    local job_num=$1
    local tag_name="stress-job-$job_num-$(date +%Y%m%d-%H%M%S)"
    local tar_file="$TEST_BASE/package-$job_num.tar.gz"

    # Declare separately from assignment so curl's exit code isn't swallowed by `local`.
    local response
    response=$(curl -sf --max-time 60 \
        -X POST \
        -H "Authorization: Bearer ${PREPUB_API_TOKEN}" \
        -F "repo=${REPO_NAME}" \
        -F "path=test/stress/$job_num" \
        -F "tar=@${tar_file}" \
        -F "tag_name=${tag_name}" \
        "${PREPUB_URL}/api/v1/jobs") || response=""

    local job_id
    job_id=$(echo "$response" | jq -r '.job_id // empty')

    if [[ -z "$job_id" ]]; then
        echo -e "${RED}Failed to submit job $job_num${NC}" >&2
        return 1
    fi

    # Field layout: 1=job_id  2=tag_name  3=job_num
    # Callers use:  cut -d' ' -f1, -f2, -f3 respectively.
    echo "$job_id $tag_name $job_num"
    return 0
}

# Submit jobs with concurrency control
ACTIVE_JOBS=()
PUBLISHED=0
FAILED=0
JOB_COUNTER=1
# Overall deadline: 10 minutes per job, at minimum 5 minutes.
OVERALL_TIMEOUT=$(( NUM_JOBS * 600 > 300 ? NUM_JOBS * 600 : 300 ))
OVERALL_DEADLINE=$(( $(date +%s) + OVERALL_TIMEOUT ))

# Submit initial batch
for (( i=1; i<=CONCURRENCY; i++ )); do
    if [[ $JOB_COUNTER -le $NUM_JOBS ]]; then
        result=$(submit_job "$JOB_COUNTER") || result=""
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

        job_status=$(curl -sf --max-time 10 \
            -X GET \
            -H "Authorization: Bearer ${PREPUB_API_TOKEN}" \
            "${PREPUB_URL}/api/v1/jobs/${job_id}") || job_status=""

        state=$(echo "$job_status" | jq -r '.state // empty')

        if [[ "$state" == "published" ]]; then
            echo -e "${GREEN}[Completed] Job $job_num ($job_id) published${NC}"
            PUBLISHED=$((PUBLISHED + 1))
            unset 'ACTIVE_JOBS[$i]'

            # Submit next job if available
            if [[ $JOB_COUNTER -le $NUM_JOBS ]]; then
                result=$(submit_job "$JOB_COUNTER") || result=""
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
                result=$(submit_job "$JOB_COUNTER") || result=""
                if [[ -n "$result" ]]; then
                    ACTIVE_JOBS+=("$result")
                fi
                JOB_COUNTER=$((JOB_COUNTER + 1))
            fi
        fi
    done

    # Re-index array to remove gaps
    ACTIVE_JOBS=("${ACTIVE_JOBS[@]}")

    if (( $(date +%s) > OVERALL_DEADLINE )); then
        echo -e "${RED}Stress test timed out after ${OVERALL_TIMEOUT}s — ${#ACTIVE_JOBS[@]} job(s) still active${NC}" >&2
        FAILED=$(( FAILED + ${#ACTIVE_JOBS[@]} ))
        break
    fi

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
