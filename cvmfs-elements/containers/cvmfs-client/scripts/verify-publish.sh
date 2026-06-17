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
# Uses bash $EPOCHREALTIME (bash >= 5.0, available in Ubuntu 22.04+).
# Falls back to date +%s%3N if EPOCHREALTIME is unavailable.
now_ms() {
    if [[ -n "${EPOCHREALTIME:-}" ]]; then
        # Avoid bc (not always present in minimal images).
        # EPOCHREALTIME looks like "1234567890.123456"; remove the decimal point
        # and divide by 1000 (dropping sub-ms precision) to get milliseconds.
        local raw="${EPOCHREALTIME//./}"   # e.g. "1234567890123456"
        printf '%d' "$(( raw / 1000 ))"
    else
        date +%s%3N
    fi
}

# ── Fetch job metadata to establish t0 ───────────────────────────────────────
echo "[verify] Fetching job metadata for ${JOB_ID}..."
JOB_JSON=""
JOB_JSON=$(curl -sf --max-time 10 \
    -H "${AUTH_HEADER}" \
    "${PREPUB_URL}/api/v1/jobs/${JOB_ID}") || true

if [[ -z "${JOB_JSON}" ]]; then
    echo "[verify] ERROR: could not fetch job ${JOB_ID} from ${PREPUB_URL}" >&2
    exit 1
fi

# created_at is an RFC 3339 timestamp; convert to ms-since-epoch via date.
CREATED_AT=""
CREATED_AT=$(echo "${JOB_JSON}" | jq -r '.created_at // empty')
if [[ -n "${CREATED_AT}" ]]; then
    T0_MS=$(date -d "${CREATED_AT}" +%s%3N 2>/dev/null || now_ms)
else
    T0_MS=$(now_ms)
fi

echo "[verify] Job created_at: ${CREATED_AT:-unknown}, t0=${T0_MS}ms"

# ── Terminal-state detection ──────────────────────────────────────────────────
TERMINAL_STATES=(published failed aborted)

is_terminal() {
    local state="$1"
    local t
    for t in "${TERMINAL_STATES[@]}"; do
        [[ "${state}" == "${t}" ]] && return 0
    done
    return 1
}

# ── Stage timing storage ──────────────────────────────────────────────────────
declare -A STAGE_TS
declare -a STAGE_ORDER

record_stage() {
    local name="$1" ts="$2"
    # Ignore duplicate states (SSE may replay the current state on reconnect).
    if [[ -z "${STAGE_TS[${name}]:-}" ]]; then
        STAGE_TS["${name}"]="${ts}"
        STAGE_ORDER+=("${name}")
    fi
}

record_stage "queued" "${T0_MS}"

# ── Subscribe to SSE event stream ────────────────────────────────────────────
SSE_URL="${PREPUB_URL}/api/v1/jobs/${JOB_ID}/events"
echo "[verify] Subscribing to SSE: ${SSE_URL}"

SSE_FIFO=$(mktemp -u /tmp/sse.XXXXXX)
# Set trap BEFORE mkfifo so a SIGINT between mkfifo and the trap definition
# cannot leave the FIFO behind.
trap 'rm -f "${SSE_FIFO}"; kill "${CURL_PID:-}" 2>/dev/null || true' EXIT INT TERM
mkfifo "${SSE_FIFO}"

curl -sN --no-buffer \
    --max-time 300 \
    -H "${AUTH_HEADER}" \
    "${SSE_URL}" > "${SSE_FIFO}" &
CURL_PID=$!

FINAL_STATE=""
SSE_TIMEOUT=300
DEADLINE=$(( $(date +%s) + SSE_TIMEOUT ))

while IFS= read -r -t 5 line; do
    if [[ "${line}" == data:* ]]; then
        json="${line#data: }"
        state=""
        state=$(echo "${json}" | jq -r '.state // empty' 2>/dev/null) || true
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
    if (( $(date +%s) > DEADLINE )); then
        echo "[verify] ERROR: timed out waiting for terminal state after ${SSE_TIMEOUT}s" >&2
        exit 2
    fi
done < "${SSE_FIFO}" || true   # read returns non-zero on EOF/timeout — not an error

# If SSE closed without a terminal state, fall back to polling.
if [[ -z "${FINAL_STATE}" ]]; then
    echo "[verify] SSE stream closed without terminal state — polling job status..."
    _poll=0
    while (( _poll < 30 )); do
        _poll=$(( _poll + 1 ))
        job=""
        job=$(curl -sf --max-time 10 \
            -H "${AUTH_HEADER}" \
            "${PREPUB_URL}/api/v1/jobs/${JOB_ID}") || true
        if [[ -z "$job" ]]; then sleep 2; continue; fi

        state=""
        state=$(echo "${job}" | jq -r '.state // empty') || true
        if [[ -z "$state" ]]; then sleep 2; continue; fi

        ts=$(now_ms)
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
    echo "[verify] Remounting CVMFS repository to pick up new catalog..."
    REMOUNT_TS=$(now_ms)
    /usr/local/bin/cvmfs_talk -i "${REPO_NAME}" remount sync 2>/dev/null || true
    record_stage "client remount" "${REMOUNT_TS}"

    if [[ -n "${EXPECTED_FILE}" ]]; then
        FILE_PATH="${MOUNT_POINT}/${EXPECTED_FILE}"
        echo "[verify] Polling for ${FILE_PATH} (max 60 s)..."
        POLL_DEADLINE=$(( $(date +%s) + 60 ))
        NEXT_REMOUNT=$(( $(date +%s) + 5 ))

        while true; do
            if [[ -e "${FILE_PATH}" ]]; then
                FILE_VISIBLE_TS=$(now_ms)
                record_stage "file visible" "${FILE_VISIBLE_TS}"
                echo "[verify] File visible: ${FILE_PATH}"

                # Additionally attempt a content read for regular files.
                # -e alone misses CVMFS quarantine failures (EIO): the file
                # shows up in stat/readdir but cat returns EIO because the
                # client quarantined the CAS object after a failed integrity
                # check.  Reading the first byte catches this class of failure.
                if [[ -f "${FILE_PATH}" && ! -L "${FILE_PATH}" ]]; then
                    _read_err=""
                    if ! _read_err=$(cat "${FILE_PATH}" 2>&1 >/dev/null); then
                        echo "[verify] ERROR: file stat OK but content read failed (EIO/quarantine?): ${_read_err}" >&2
                        FILE_VISIBLE_TS=""   # mark as not actually readable
                    fi
                fi
                break
            fi
            if (( $(date +%s) > POLL_DEADLINE )); then
                echo "[verify] ERROR: file not visible after 60 s: ${FILE_PATH}" >&2
                break
            fi
            if (( $(date +%s) >= NEXT_REMOUNT )); then
                /usr/local/bin/cvmfs_talk -i "${REPO_NAME}" remount sync 2>/dev/null || true
                NEXT_REMOUNT=$(( $(date +%s) + 5 ))
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
printf "%s-+-%s-+-%s\n" "$(printf '%0.s-' {1..26})" "$(printf '%0.s-' {1..12})" "$(printf '%0.s-' {1..10})"

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
            exit 3
        fi
        exit 0 ;;
    failed|aborted) exit 1 ;;
    *)              exit 2 ;;
esac
