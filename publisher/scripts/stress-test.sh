#!/usr/bin/env bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# ── Configuration ──────────────────────────────────────────────────────────────
NUM_JOBS=${NUM_JOBS:-5}
CONCURRENCY=${CONCURRENCY:-2}

# Run log — when set (mounted from host), each test run is appended as a
# single JSON line so the testbed console can display run history.
RUN_LOG_FILE="${RUN_LOG_FILE:-/data/runs.ndjson}"

# Optional: directory containing pre-built payload tars (from make-stress-payload.sh).
# When set, package-N.tar files are read from this directory instead of being
# generated inline.  NUM_JOBS must not exceed the number of tars in PAYLOAD_DIR.
PAYLOAD_DIR="${PAYLOAD_DIR:-}"

# Optional: Stratum 1 data base URL for propagation timing.
# When set (e.g. http://localhost:9111), the script polls the S1's
# .cvmfspublished file after each job completes and reports the time until the
# new catalog hash appears.  Leave empty to skip S1 polling.
S1_DATA_URL="${S1_DATA_URL:-}"

# S1 polling parameters.
S1_POLL_INTERVAL="${S1_POLL_INTERVAL:-5}"   # seconds between polls
S1_POLL_TIMEOUT="${S1_POLL_TIMEOUT:-300}"   # seconds before giving up

# ── Validate environment ───────────────────────────────────────────────────────
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

# ── Run recording ─────────────────────────────────────────────────────────────
# Appends one NDJSON line to RUN_LOG_FILE describing the completed test run.
# Arguments: run_id method test_type n_req n_pub n_fail start_ts end_ts
#            avg_s min_s max_s p50_s p95_s
log_run() {
    local run_id="$1" method="$2" test_type="$3"
    local n_req="$4"  n_pub="$5"  n_fail="$6"
    local start_ts="$7" end_ts="$8"
    local avg_s="${9:-0}" min_s="${10:-0}" max_s="${11:-0}"
    local p50_s="${12:-0}" p95_s="${13:-0}"
    [[ -n "${RUN_LOG_FILE:-}" ]] || return 0
    local start_time end_time duration_s throughput
    start_time="$(date -u -d "@${start_ts}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
               || date -u -r "${start_ts}" +%Y-%m-%dT%H:%M:%SZ)"
    end_time="$(date -u -d "@${end_ts}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
             || date -u -r "${end_ts}" +%Y-%m-%dT%H:%M:%SZ)"
    duration_s=$(( end_ts - start_ts ))
    throughput="0.00"
    if (( n_pub > 0 && duration_s > 0 )); then
        throughput="$(awk "BEGIN{printf \"%.2f\", ${n_pub} * 60 / ${duration_s}}")"
    fi
    printf '{"run_id":"%s","method":"%s","test_type":"%s","n_requested":%d,"n_published":%d,"n_failed":%d,"start_time":"%s","end_time":"%s","duration_s":%d,"avg_s":%d,"min_s":%d,"max_s":%d,"p50_s":%d,"p95_s":%d,"throughput_per_min":%s}\n' \
        "$run_id" "$method" "$test_type" \
        "$n_req" "$n_pub" "$n_fail" \
        "$start_time" "$end_time" "$duration_s" \
        "$avg_s" "$min_s" "$max_s" "$p50_s" "$p95_s" \
        "$throughput" \
        >> "$RUN_LOG_FILE" 2>/dev/null || true
}

echo "Starting stress test: NUM_JOBS=$NUM_JOBS CONCURRENCY=$CONCURRENCY"
if [[ -n "$PAYLOAD_DIR" ]]; then
    echo "  Using pre-built tars from: $PAYLOAD_DIR"
fi
if [[ -n "$S1_DATA_URL" ]]; then
    echo "  S1 propagation polling: $S1_DATA_URL (every ${S1_POLL_INTERVAL}s, timeout ${S1_POLL_TIMEOUT}s)"
fi

# ── Build or locate test payloads ──────────────────────────────────────────────
TEST_BASE=""

if [[ -n "$PAYLOAD_DIR" ]]; then
    # Use pre-built tars.  Verify the expected files exist.
    for (( i=1; i<=NUM_JOBS; i++ )); do
        if [[ ! -f "${PAYLOAD_DIR}/package-${i}.tar" ]]; then
            echo "Error: ${PAYLOAD_DIR}/package-${i}.tar not found (run make-stress-payload.sh first)"
            exit 1
        fi
    done
    echo "Verified ${NUM_JOBS} pre-built package tars in ${PAYLOAD_DIR}"
else
    # Generate minimal inline test packages (tiny plaintext files).
    TEST_BASE=$(mktemp -d)
    trap 'rm -rf "${TEST_BASE}"' EXIT

    echo "Creating $NUM_JOBS test packages..."
    for (( i=1; i<=NUM_JOBS; i++ )); do
        PKG_DIR="$TEST_BASE/package-$i"
        mkdir -p "$PKG_DIR"
        echo "Package $i content $(date)" > "$PKG_DIR/file.txt"

        # The cvmfs-prepub pipeline reads tars via archive/tar directly (no gzip
        # decompression layer), so the payload must be a plain (uncompressed) tar.
        tar -cf "$TEST_BASE/package-$i.tar" -C "$PKG_DIR" .
    done
fi

# Helper: return path to tar file for job $1
tar_path_for_job() {
    local n=$1
    if [[ -n "$PAYLOAD_DIR" ]]; then
        echo "${PAYLOAD_DIR}/package-${n}.tar"
    else
        echo "${TEST_BASE}/package-${n}.tar"
    fi
}

# ── S1 propagation polling ─────────────────────────────────────────────────────
# Poll the Stratum 1 .cvmfspublished manifest until the catalog hash field (C=)
# matches the new_root_hash returned by the bits API for the given job.
# Prints elapsed seconds on success, or a warning on timeout.
#
# Arguments: job_num job_id new_root_hash
poll_s1_propagation() {
    local job_num="$1"
    local job_id="$2"
    local new_root_hash="$3"

    if [[ -z "$S1_DATA_URL" ]]; then
        return 0
    fi
    if [[ -z "$new_root_hash" ]]; then
        echo -e "  ${YELLOW}[S1] Job $job_num: new_root_hash not available — skipping S1 poll${NC}" >&2
        return 0
    fi

    local url="${S1_DATA_URL}/${REPO_NAME}/.cvmfspublished"
    local deadline=$(( $(date +%s) + S1_POLL_TIMEOUT ))
    local s1_start=$(date +%s)

    while (( $(date +%s) < deadline )); do
        local published
        published=$(curl -sf --max-time 10 "$url" 2>/dev/null || echo "")
        if [[ -n "$published" ]]; then
            local s1_hash
            s1_hash=$(echo "$published" | grep '^C=' | cut -d= -f2 | tr -d '[:space:]')
            if [[ "$s1_hash" == "$new_root_hash" ]]; then
                local s1_elapsed=$(( $(date +%s) - s1_start ))
                echo -e "  ${GREEN}[S1] Job $job_num propagated to Stratum 1 in ${s1_elapsed}s${NC}"
                return 0
            fi
        fi
        sleep "$S1_POLL_INTERVAL"
    done

    echo -e "  ${YELLOW}[S1] Job $job_num: Stratum 1 did not propagate within ${S1_POLL_TIMEOUT}s${NC}" >&2
    return 0
}

echo "Submitting $NUM_JOBS jobs with concurrency $CONCURRENCY..."

# ── submit_job ─────────────────────────────────────────────────────────────────
# Submit a single job.
# Outputs "$job_id $tag_name $job_num $submit_ts" on success.
submit_job() {
    local job_num=$1
    local tag_name="stress-job-$job_num-$(date +%Y%m%d-%H%M%S)"
    local tar_file
    tar_file=$(tar_path_for_job "$job_num")
    local submit_ts
    submit_ts=$(date +%s)

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

    # Field layout: 1=job_id  2=tag_name  3=job_num  4=submit_ts
    echo "$job_id $tag_name $job_num $submit_ts"
    return 0
}

# ── Concurrency loop ───────────────────────────────────────────────────────────
ACTIVE_JOBS=()
PUBLISHED=0
FAILED=0
JOB_COUNTER=1
START_TS=$(date +%s)
# Overall deadline: 10 minutes per job, at minimum 5 minutes.
OVERALL_TIMEOUT=$(( NUM_JOBS * 600 > 300 ? NUM_JOBS * 600 : 300 ))
OVERALL_DEADLINE=$(( START_TS + OVERALL_TIMEOUT ))

# Job-level timing: associative array mapping job_id → submit timestamp.
declare -A JOB_SUBMIT_TS

# Accumulate per-job s0 latencies for summary statistics.
S0_TIMES=()

# Submit initial batch.
for (( i=1; i<=CONCURRENCY; i++ )); do
    if [[ $JOB_COUNTER -le $NUM_JOBS ]]; then
        result=$(submit_job "$JOB_COUNTER") || result=""
        if [[ -n "$result" ]]; then
            ACTIVE_JOBS+=("$result")
            jid=$(echo "$result" | cut -d' ' -f1)
            jts=$(echo "$result" | cut -d' ' -f4)
            JOB_SUBMIT_TS["$jid"]="$jts"
        fi
        JOB_COUNTER=$((JOB_COUNTER + 1))
    fi
done

# Process remaining jobs.
while [[ $JOB_COUNTER -le $NUM_JOBS ]] || [[ ${#ACTIVE_JOBS[@]} -gt 0 ]]; do
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
            s0_elapsed=$(( $(date +%s) - ${JOB_SUBMIT_TS[$job_id]:-$(date +%s)} ))
            S0_TIMES+=("$s0_elapsed")
            echo -e "${GREEN}[Completed] Job $job_num ($job_id) published in ${s0_elapsed}s${NC}"
            PUBLISHED=$((PUBLISHED + 1))
            unset 'ACTIVE_JOBS[$i]'

            # Kick off S1 propagation polling in background so it doesn't block
            # the submission loop.
            new_root_hash=$(echo "$job_status" | jq -r '.new_root_hash // empty')
            poll_s1_propagation "$job_num" "$job_id" "$new_root_hash" &

            # Submit next job if available.
            if [[ $JOB_COUNTER -le $NUM_JOBS ]]; then
                result=$(submit_job "$JOB_COUNTER") || result=""
                if [[ -n "$result" ]]; then
                    ACTIVE_JOBS+=("$result")
                    jid=$(echo "$result" | cut -d' ' -f1)
                    jts=$(echo "$result" | cut -d' ' -f4)
                    JOB_SUBMIT_TS["$jid"]="$jts"
                fi
                JOB_COUNTER=$((JOB_COUNTER + 1))
            fi
        elif [[ "$state" == "failed" ]] || [[ "$state" == "aborted" ]]; then
            echo -e "${RED}[Failed] Job $job_num ($job_id) $state${NC}"
            FAILED=$((FAILED + 1))
            unset 'ACTIVE_JOBS[$i]'

            # Submit next job if available.
            if [[ $JOB_COUNTER -le $NUM_JOBS ]]; then
                result=$(submit_job "$JOB_COUNTER") || result=""
                if [[ -n "$result" ]]; then
                    ACTIVE_JOBS+=("$result")
                    jid=$(echo "$result" | cut -d' ' -f1)
                    jts=$(echo "$result" | cut -d' ' -f4)
                    JOB_SUBMIT_TS["$jid"]="$jts"
                fi
                JOB_COUNTER=$((JOB_COUNTER + 1))
            fi
        fi
    done

    # Re-index array to remove gaps.
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

# Wait for any background S1 polling goroutines to finish.
wait

# ── Summary ────────────────────────────────────────────────────────────────────
END_TS=$(date +%s)
ELAPSED=$(( END_TS - START_TS ))

# Compute min/max/avg/p50/p95 S0 latency across completed jobs.
S0_MIN="" S0_MAX="" S0_AVG="" S0_P50="" S0_P95=""
if (( ${#S0_TIMES[@]} > 0 )); then
    S0_SUM=0
    S0_MIN=${S0_TIMES[0]}
    S0_MAX=${S0_TIMES[0]}
    for t in "${S0_TIMES[@]}"; do
        S0_SUM=$(( S0_SUM + t ))
        (( t < S0_MIN )) && S0_MIN=$t
        (( t > S0_MAX )) && S0_MAX=$t
    done
    S0_AVG=$(awk "BEGIN { printf \"%d\", ${S0_SUM} / ${#S0_TIMES[@]} }")
    # Percentiles: sort numerically, then pick index by nearest-rank method.
    IFS=$'\n' S0_SORTED=($(sort -n <<<"${S0_TIMES[*]}"))
    _N=${#S0_SORTED[@]}
    _p50_idx=$(awk "BEGIN{printf \"%d\", int(0.50 * ($_N - 1) + 0.5)}")
    _p95_idx=$(awk "BEGIN{printf \"%d\", int(0.95 * ($_N - 1) + 0.5)}")
    S0_P50=${S0_SORTED[$_p50_idx]}
    S0_P95=${S0_SORTED[$_p95_idx]}
    unset S0_SORTED _N _p50_idx _p95_idx
fi

echo ""
echo "=========================================="
echo "  Bits Stress Test Summary"
echo "=========================================="
printf "  Total jobs:   %d\n" "${NUM_JOBS}"
printf "  Concurrency:  %d\n" "${CONCURRENCY}"
echo -e "  ${GREEN}Published:    ${PUBLISHED}${NC}"
echo -e "  ${RED}Failed:       ${FAILED}${NC}"
printf "  Elapsed:      %ds\n" "${ELAPSED}"
if (( NUM_JOBS > 0 && ELAPSED > 0 )); then
    printf "  Throughput:   %.2f jobs/min\n" \
        "$(awk "BEGIN { printf \"%.2f\", ${NUM_JOBS} * 60 / ${ELAPSED} }")"
fi
if [[ -n "$S0_MIN" ]]; then
    printf "  S0 latency:   min=%ds  avg=%ds  max=%ds  p50=%ds  p95=%ds\n" \
        "$S0_MIN" "$S0_AVG" "$S0_MAX" "$S0_P50" "$S0_P95"
fi
if [[ -n "$PAYLOAD_DIR" ]]; then
    printf "  Payload dir:  %s\n" "${PAYLOAD_DIR}"
fi
echo "=========================================="

# ── Record this run ────────────────────────────────────────────────────────────
RUN_ID="bits-stress-$(date -u -d "@${START_TS}" +%Y%m%d-%H%M%S 2>/dev/null \
    || date -u -r "${START_TS}" +%Y%m%d-%H%M%S)"
log_run "$RUN_ID" "bits" "stress" \
    "$NUM_JOBS" "$PUBLISHED" "$FAILED" \
    "$START_TS" "$END_TS" \
    "${S0_AVG:-0}" "${S0_MIN:-0}" "${S0_MAX:-0}" \
    "${S0_P50:-0}" "${S0_P95:-0}"

if [[ $FAILED -eq 0 ]]; then
    exit 0
else
    exit 1
fi
