#!/usr/bin/env bash
# verify-publish.sh — Poll a cvmfs-prepub job's SSE event stream and measure
# how long each pipeline stage takes, then verify the published files are
# visible through the CVMFS client.
#
# Usage:
#   verify-publish.sh <job_id> [expected_file_path]
#
# Arguments:
#   job_id             – UUID returned by POST /api/v1/jobs
#   expected_file_path – Optional relative path to poll for after publish, e.g.
#                        "usr/share/test/hello.txt". If omitted the script only
#                        measures pipeline stage timing.
#
# Required environment variables (set in docker-compose.yml):
#   PREPUB_URL       – cvmfs-prepub API base, e.g. http://cvmfs-prepub:8080
#   PREPUB_API_TOKEN – Bearer token
#   REPO_NAME        – CVMFS repository domain, e.g. test.cvmfs.io
#
# Output: a table printed to stdout:
#
#   Stage                  | Elapsed (ms) | Delta (ms)
#   -----------------------+--------------+-----------
#   queued                 |            0 |          0
#   processing             |          342 |        342
#   distributing           |          891 |        549
#   leased                 |          953 |         62
#   committing             |         1012 |         59
#   published              |         1287 |        275
#   client remount         |         1543 |        256
#   file visible           |         2104 |        561
#
# Exit codes:
#   0 – job reached "published" and file is visible (or no file was specified)
#   1 – job failed or aborted
#   2 – timeout waiting for terminal state
#   3 – file not visible within 60 s after publish
set -euo pipefail

# ── Argument handling ─────────────────────────────────────────────────────────
JOB_ID="${1:?Usage: verify-publish.sh <job_id> [expected_file_path]}"
EXPECTED_FILE="${2:-}"

# ── Environment checks ────────────────────────────────────────────────────────
: "${PREPUB_URL:?PREPUB_URL must be set}"
: "${PREPUB_API_TOKEN:?PREPUB_API_TOKEN must be set}"
: "${REPO_NAME:?REPO_NAME must be set}"

MOUNT_POINT="/cvmfs/${REPO_NAME}"

AUTH_HEADER="Authorization: Bearer ${PREPUB_API_TOKEN}"

# ── Timing helpers ────────────────────────────────────────────────────────────
# now_ms() returns the current time in milliseconds since epoch.
# We use /proc/uptime to stay portable without requiring date --nanoseconds.
now_ms() {
    # bash $EPOCHREALTIME is available in bash >= 5.0 (Ubuntu 22.04 ships 5.1).
    printf '%.0f' "$(echo "${EPOCHREALTIME} * 1000" | bc)"
}

# ── Fetch job metadata to establish t0 ───────────────────────────────────────
echo "[verify] Fetching job metadata for ${JOB_ID}..."
JOB_JSON=$(curl -s -f \
    -H "${AUTH_HEADER}" \
    "${PREPUB_URL}/api/v1/jobs/${JOB_ID}")

if [[ -z "${JOB_JSON}" ]]; then
    echo "[verify] ERROR: could not fetch job ${JOB_ID} from ${PREPUB_URL}" >&2
    exit 1
fi

# created_at is an RFC 3339 timestamp; convert to ms-since-epoch via date.
CREATED_AT=$(echo "${JOB_JSON}" | jq -r '.created_at // empty')
if [[ -n "${CREATED_AT}" ]]; then
    T0_MS=$(date -d "${CREATED_AT}" +%s%3N 2>/dev/null || echo "$(now_ms)")
else
    T0_MS=$(now_ms)
fi

echo "[verify] Job created_at: ${CREATED_AT:-unknown}, t0=${T0_MS}ms"

# ── Terminal-state detection ──────────────────────────────────────────────────
# Ordered list of FSM states we expect to see; terminal states end the loop.
TERMINAL_STATES=(published failed aborted)

is_terminal() {
    local state="$1"
    for t in "${TERMINAL_STATES[@]}"; do
        [[ "${state}" == "${t}" ]] && return 0
    done
    return 1
}

# ── Stage timing storage ──────────────────────────────────────────────────────
# Associative array: state_name → timestamp_ms
declare -A STAGE_TS
declare -a STAGE_ORDER

record_stage() {
    local name="$1"
    local ts="$2"
    STAGE_TS["${name}"]="${ts}"
    STAGE_ORDER+=("${name}")
}

# Record the "queued" stage using the job's creation time as t0.
record_stage "queued" "${T0_MS}"

# ── Subscribe to SSE event stream ────────────────────────────────────────────
# GET /api/v1/jobs/{id}/events streams server-sent events.  Each event is
# "data: <json>" where JSON contains {"state": "..."}.
#
# We run curl in background and read its output line-by-line to avoid
# blocking this script while also capturing the exact wall-clock time each
# event arrives.
SSE_URL="${PREPUB_URL}/api/v1/jobs/${JOB_ID}/events"
echo "[verify] Subscribing to SSE: ${SSE_URL}"

# Temporary FIFO for SSE data.
SSE_FIFO=$(mktemp -u /tmp/sse.XXXXXX)
mkfifo "${SSE_FIFO}"
trap 'rm -f "${SSE_FIFO}"; kill "${CURL_PID}" 2>/dev/null || true' EXIT

# curl --no-buffer keeps the connection open for SSE; --max-time caps overall
# wait at 300 s to avoid hanging forever if the job stalls.
curl -s -N --no-buffer \
    --max-time 300 \
    -H "${AUTH_HEADER}" \
    "${SSE_URL}" > "${SSE_FIFO}" &
CURL_PID=$!

FINAL_STATE=""
SSE_TIMEOUT=300  # seconds
DEADLINE=$(( $(date +%s) + SSE_TIMEOUT ))

# Read lines from the FIFO; each SSE event has the form:
#   event: state_change
#   data: {"state":"processing","job_id":"..."}
#   (blank line)
while IFS= read -r -t 5 line; do
    # SSE data lines start with "data: "
    if [[ "${line}" == data:* ]]; then
        json="${line#data: }"
        state=$(echo "${json}" | jq -r '.state // empty' 2>/dev/null)
        if [[ -n "${state}" ]]; then
            ts=$(now_ms)
            echo "[verify] State: ${state} at +$(( ts - T0_MS ))ms"
            record_stage "${state}" "${ts}"
            if is_terminal "${state}"; then
                FINAL_STATE="${state}"
                break
            fi
        fi
    fi

    # Check overall timeout.
    if (( $(date +%s) > DEADLINE )); then
        echo "[verify] ERROR: timed out waiting for terminal state after ${SSE_TIMEOUT}s" >&2
        exit 2
    fi
done < "${SSE_FIFO}"

# If the curl process ended before we read a terminal state, fall back to
# polling (handles the case where the job was already terminal when we subscribed).
if [[ -z "${FINAL_STATE}" ]]; then
    echo "[verify] SSE stream closed without terminal state — polling job status..."
    for _ in $(seq 1 30); do
        job=$(curl -s -f -H "${AUTH_HEADER}" "${PREPUB_URL}/api/v1/jobs/${JOB_ID}")
        state=$(echo "${job}" | jq -r '.state // empty')
        ts=$(now_ms)
        if [[ -n "${state}" ]] && ! is_terminal "${state}"; then
            sleep 2
            continue
        fi
        if is_terminal "${state}"; then
            record_stage "${state}" "${ts}"
            FINAL_STATE="${state}"
            break
        fi
        sleep 2
    done
fi

if [[ -z "${FINAL_STATE}" ]]; then
    echo "[verify] ERROR: job never reached a terminal state" >&2
    exit 2
fi

# ── File visibility check ─────────────────────────────────────────────────────
FILE_VISIBLE_TS=""

if [[ "${FINAL_STATE}" == "published" ]]; then
    # Force the CVMFS client to pick up the new catalog.
    echo "[verify] Remounting CVMFS repository to pick up new catalog..."
    REMOUNT_TS=$(now_ms)
    /usr/local/bin/cvmfs_talk -i "${REPO_NAME}" remount sync 2>/dev/null || true
    record_stage "client remount" "${REMOUNT_TS}"

    if [[ -n "${EXPECTED_FILE}" ]]; then
        FILE_PATH="${MOUNT_POINT}/${EXPECTED_FILE}"
        echo "[verify] Polling for ${FILE_PATH} (max 60 s)..."
        POLL_DEADLINE=$(( $(date +%s) + 60 ))
        REMOUNT_INTERVAL=5
        NEXT_REMOUNT=$(( $(date +%s) + REMOUNT_INTERVAL ))

        while true; do
            if [[ -e "${FILE_PATH}" ]]; then
                FILE_VISIBLE_TS=$(now_ms)
                record_stage "file visible" "${FILE_VISIBLE_TS}"
                echo "[verify] File visible: ${FILE_PATH}"
                break
            fi
            if (( $(date +%s) > POLL_DEADLINE )); then
                echo "[verify] ERROR: file not visible after 60 s: ${FILE_PATH}" >&2
                break
            fi
            # Periodically retry remount in case the first one didn't pick up
            # the new catalog yet.
            if (( $(date +%s) >= NEXT_REMOUNT )); then
                /usr/local/bin/cvmfs_talk -i "${REPO_NAME}" remount sync 2>/dev/null || true
                NEXT_REMOUNT=$(( $(date +%s) + REMOUNT_INTERVAL ))
            fi
            sleep 0.2
        done
    fi
elif [[ "${FINAL_STATE}" == "failed" ]]; then
    echo "[verify] Job FAILED." >&2
elif [[ "${FINAL_STATE}" == "aborted" ]]; then
    echo "[verify] Job ABORTED." >&2
fi

# ── Print timing table ────────────────────────────────────────────────────────
echo ""
printf "%-26s | %12s | %10s\n" "Stage" "Elapsed (ms)" "Delta (ms)"
printf "%-26s-+-%12s-+-%10s\n" "--------------------------" "------------" "----------"

PREV_MS="${T0_MS}"
for stage in "${STAGE_ORDER[@]}"; do
    ts="${STAGE_TS[${stage}]}"
    elapsed=$(( ts - T0_MS ))
    delta=$(( ts - PREV_MS ))
    printf "%-26s | %12d | %10d\n" "${stage}" "${elapsed}" "${delta}"
    PREV_MS="${ts}"
done

echo ""

# ── Exit code ─────────────────────────────────────────────────────────────────
case "${FINAL_STATE}" in
    published)
        if [[ -n "${EXPECTED_FILE}" && -z "${FILE_VISIBLE_TS}" ]]; then
            exit 3  # published but file not visible
        fi
        exit 0
        ;;
    failed)   exit 1 ;;
    aborted)  exit 1 ;;
    *)        exit 2 ;;
esac
