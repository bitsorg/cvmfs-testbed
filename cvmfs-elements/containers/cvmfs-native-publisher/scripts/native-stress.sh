#!/usr/bin/env bash
# native-stress.sh — Stress test via sequential cvmfs_server ingest calls.
#
# Publishes NUM_JOBS packages and reports a summary.  Unlike the bits stress
# test (which is asynchronous), cvmfs_server ingest is synchronous: each call
# blocks until the gateway receiver commits the transaction and signs the
# manifest.  Jobs therefore run sequentially.
#
# After each successful ingest, if MQTT_BROKER_HOST is set the script publishes
# a commit notification to the broker so that Stratum 1 receivers can pull the
# new root catalog from Stratum 0.
#
# Path layout:
#   Each job is published to:  test/native/stress-<RUN_TS>-<i>/
#   (directly under the guaranteed-to-exist test/native/ parent)
#
#   Using a per-run timestamp suffix makes the ingest base always NEW on every
#   run, which avoids two interacting constraints of mountless gateway ingest:
#
#   (a) Duplicate-INSERT assert: if a directory already exists in the catalog,
#       calling AddDirectory on it again hits the UNIQUE PRIMARY KEY constraint
#       in SQLite and causes WritableCatalog::AddEntry to assert(retval) →
#       SIGABRT.
#
#   (b) FindCatalog panic: if a directory was incorrectly treated as pre-existing
#       (via an rdonly stub) when it actually has no entry in any loaded catalog,
#       AddDirectory for any child path calls FindCatalog(parent) → returns false
#       → PANIC in catalog_mgr_rw.cc.
#
#   By making the leaf path always unique, neither constraint fires.
#
# Tar content is flat (no subdirectories).  This avoids any FindCatalog calls
# inside the ingest base: files land directly in the leaf directory, so only
# the leaf path itself is processed by CreateDirectories.
#
# rdonly stubs:
#   Only stub directories that are GUARANTEED to exist in the catalog from a
#   prior smoke test (test/ and test/native/).  Stubbing them suppresses the
#   duplicate-INSERT assert for those paths.  The new per-run leaf path has no
#   stub so the swissknife creates its nested catalog entry normally.
#
# Environment:
#   REPO_NAME          — CVMFS repository FQDN (e.g. test.cvmfs.io)  [required]
#   NUM_JOBS           — Number of packages to publish (default: 5)
#   MQTT_BROKER_HOST   — Hostname of the Mosquitto broker for commit notifications
#                        (default: empty = MQTT notifications disabled)
#   MQTT_BROKER_PORT   — Broker port (default: 1883)
#   STRATUM0_URL       — Stratum 0 base URL for reading .cvmfspublished
#                        (default: http://stratum0)
set -euo pipefail

: "${REPO_NAME:?REPO_NAME must be set}"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

NUM_JOBS="${NUM_JOBS:-5}"
MQTT_BROKER_HOST="${MQTT_BROKER_HOST:-}"
MQTT_BROKER_PORT="${MQTT_BROKER_PORT:-1883}"
STRATUM0_URL="${STRATUM0_URL:-http://stratum0}"
RUN_TS="$(date +%Y%m%d-%H%M%S)"

# ── Job logging ────────────────────────────────────────────────────────────────
# When JOB_LOG_FILE is set (mounted from host by docker-compose), each completed
# job is appended as a single JSON line so the testbed web console can display
# ingest jobs alongside bits jobs on the Monitoring tab.
JOB_LOG_FILE="${JOB_LOG_FILE:-/data/ingest-jobs.ndjson}"

# Run log — when set (mounted from host), the completed test run is appended as
# a single JSON line for run history / comparison in the testbed console.
RUN_LOG_FILE="${RUN_LOG_FILE:-/data/runs.ndjson}"

# log_ingest_job  job_id  state  repo  path  created_at_epoch  updated_at_epoch
log_ingest_job() {
    local job_id="$1" state="$2" repo="$3" path="$4"
    local created_epoch="$5" updated_epoch="$6"
    [[ -n "$JOB_LOG_FILE" ]] || return 0
    # ISO-8601 UTC timestamps
    local created_at updated_at
    created_at="$(date -u -d "@${created_epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
               || date -u -r "${created_epoch}" +%Y-%m-%dT%H:%M:%SZ)"
    updated_at="$(date -u -d "@${updated_epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
               || date -u -r "${updated_epoch}" +%Y-%m-%dT%H:%M:%SZ)"
    local duration_s=$(( updated_epoch - created_epoch ))
    printf '{"job_id":"%s","state":"%s","method":"ingest","repo":"%s","path":"%s","created_at":"%s","updated_at":"%s","duration_s":%d}\n' \
        "$job_id" "$state" "$repo" "$path" "$created_at" "$updated_at" "$duration_s" \
        >> "$JOB_LOG_FILE" 2>/dev/null || true
}

# ── Run recording helper ───────────────────────────────────────────────────────
# Appends one NDJSON line to RUN_LOG_FILE describing the completed test run.
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

# ── MQTT notification helper ──────────────────────────────────────────────────
# publish_commit_notification repo new_root_hash
#   Publishes a PublishedMessage JSON to cvmfs/repos/{repo}/published so that
#   Stratum 1 receivers subscribed to the MQTT broker can pull the new root
#   catalog from Stratum 0.
#
#   No-op when MQTT_BROKER_HOST is empty (MQTT not configured).
publish_commit_notification() {
    local repo="$1"
    local new_root_hash="$2"

    if [[ -z "${MQTT_BROKER_HOST}" ]]; then
        return 0
    fi

    # Build ISO-8601 UTC timestamp for PublishedAt.
    local published_at
    published_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # Construct the JSON payload.  Hashes are intentionally omitted: S1
    # receivers use NewRootHash to fetch only the root catalog from S0.
    local payload
    payload=$(printf '{"repo":"%s","new_root_hash":"%s","published_at":"%s"}' \
        "${repo}" "${new_root_hash}" "${published_at}")

    local topic="cvmfs/repos/${repo}/published"

    if mosquitto_pub \
            -h "${MQTT_BROKER_HOST}" \
            -p "${MQTT_BROKER_PORT}" \
            -t "${topic}" \
            -m "${payload}" \
            -q 1 \
            2>/dev/null; then
        echo "  [mqtt] commit notification published: root=${new_root_hash}"
    else
        echo "  [mqtt] WARNING: commit notification failed (broker unreachable?)" >&2
    fi
}

# ── Root-hash helper ──────────────────────────────────────────────────────────
# get_root_hash repo
#   Fetches .cvmfspublished from Stratum 0 and extracts the C= (root hash) line.
#   Outputs the hash on stdout, or empty string on failure.
get_root_hash() {
    local repo="$1"
    local url="${STRATUM0_URL}/cvmfs/${repo}/.cvmfspublished"

    curl -sS --max-time 10 "${url}" 2>/dev/null \
        | grep -m1 '^C=' \
        | cut -c3-
}

# Clear any stale session_token from a previously crashed ingest.
_SPOOL="/var/spool/cvmfs/${REPO_NAME}"
rm -f "${_SPOOL}/session_token" "${_SPOOL}/stats.db"

# ── Stub rdonly for KNOWN pre-existing catalog ancestors ──────────────────────
# In mountless gateway ingest mode the rdonly filesystem (${_SPOOL}/rdonly) is
# an empty directory — no FUSE overlay is mounted.  SyncItemNative::GetRdOnlyFiletype()
# stats ${_SPOOL}/rdonly/<path> to decide IsNew().  For directories that already
# exist in the catalog, IsNew() must return false so CreateDirectories() skips
# the duplicate AddDirectory call — otherwise the SQL INSERT on the existing
# (md5path_1, md5path_2) PRIMARY KEY fails and assert(retval) fires → SIGABRT.
#
# We only stub the two directories that the smoke test always publishes before
# any stress test run (test/ and test/native/).  The per-run leaf paths
# (test/native/stress-<RUN_TS>-<i>/) are new by design and must NOT be stubbed —
# the swissknife needs to create their nested catalog entries.
_rdonly="${_SPOOL}/rdonly"
mkdir -p "${_rdonly}/test"
mkdir -p "${_rdonly}/test/native"
unset _rdonly

echo "Starting native stress test: NUM_JOBS=${NUM_JOBS} RUN_TS=${RUN_TS}"

# ── Build all test tars upfront (flat content — no subdirectories) ────────────
TEST_BASE=$(mktemp -d)
trap 'rm -rf "${TEST_BASE}"' EXIT

echo "Creating ${NUM_JOBS} test packages..."
for (( i=1; i<=NUM_JOBS; i++ )); do
    PKG_DIR="${TEST_BASE}/package-${i}"
    mkdir -p "${PKG_DIR}"
    echo "Package ${i} content ${RUN_TS}" > "${PKG_DIR}/file.txt"
    tar -cf "${TEST_BASE}/package-${i}.tar" -C "${PKG_DIR}" .
done

# ── Run ingests sequentially ───────────────────────────────────────────────────
PUBLISHED=0
FAILED=0
START_TS=$(date +%s)
# Per-job latencies (seconds) — collected for summary statistics.
S0_TIMES=()

for (( i=1; i<=NUM_JOBS; i++ )); do
    # Unique per run: test/native/stress-<RUN_TS>-<i>/
    INGEST_PATH="test/native/stress-${RUN_TS}-${i}"
    JOB_TAR="${TEST_BASE}/package-${i}.tar"
    JOB_ID="ingest-${RUN_TS}-$(printf '%03d' "$i")"
    JOB_START_TS=$(date +%s)

    echo "[Job ${i}/${NUM_JOBS}] Ingesting to ${REPO_NAME}:${INGEST_PATH} ..."
    if cvmfs_server ingest \
            -t "${JOB_TAR}" \
            -b "${INGEST_PATH}" \
            "${REPO_NAME}"; then
        JOB_END_TS=$(date +%s)
        echo -e "${GREEN}[Job ${i}/${NUM_JOBS}] Published${NC}"
        PUBLISHED=$(( PUBLISHED + 1 ))
        S0_TIMES+=( $(( JOB_END_TS - JOB_START_TS )) )
        log_ingest_job "$JOB_ID" "published" "$REPO_NAME" "$INGEST_PATH" "$JOB_START_TS" "$JOB_END_TS"

        # Publish MQTT commit notification so S1 receivers can pull the new
        # root catalog from Stratum 0.  Fetch the updated root hash from S0
        # (.cvmfspublished is updated synchronously by cvmfs_server ingest).
        if [[ -n "${MQTT_BROKER_HOST}" ]]; then
            ROOT_HASH="$(get_root_hash "${REPO_NAME}")"
            if [[ -n "${ROOT_HASH}" ]]; then
                publish_commit_notification "${REPO_NAME}" "${ROOT_HASH}"
            else
                echo "  [mqtt] WARNING: could not read root hash from S0 — notification skipped" >&2
            fi
        fi
    else
        JOB_END_TS=$(date +%s)
        echo -e "${RED}[Job ${i}/${NUM_JOBS}] Failed${NC}"
        FAILED=$(( FAILED + 1 ))
        log_ingest_job "$JOB_ID" "failed" "$REPO_NAME" "$INGEST_PATH" "$JOB_START_TS" "$JOB_END_TS"
    fi
done

END_TS=$(date +%s)
ELAPSED=$(( END_TS - START_TS ))

# Compute min/max/avg/p50/p95 latency.
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
    IFS=$'\n' S0_SORTED=($(sort -n <<<"${S0_TIMES[*]}"))
    _N=${#S0_SORTED[@]}
    _p50_idx=$(awk "BEGIN{printf \"%d\", int(0.50 * ($_N - 1) + 0.5)}")
    _p95_idx=$(awk "BEGIN{printf \"%d\", int(0.95 * ($_N - 1) + 0.5)}")
    S0_P50=${S0_SORTED[$_p50_idx]}
    S0_P95=${S0_SORTED[$_p95_idx]}
    unset S0_SORTED _N _p50_idx _p95_idx
fi

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
    printf "  Throughput:  %.2f jobs/min\n" \
        "$(awk "BEGIN { printf \"%.2f\", ${NUM_JOBS} * 60 / ${ELAPSED} }")"
fi
if [[ -n "$S0_MIN" ]]; then
    printf "  Latency:     min=%ds  avg=%ds  max=%ds  p50=%ds  p95=%ds\n" \
        "$S0_MIN" "$S0_AVG" "$S0_MAX" "$S0_P50" "$S0_P95"
fi
echo "=========================================="

# ── Record this run ────────────────────────────────────────────────────────────
RUN_ID="ingest-stress-${RUN_TS}"
log_run "$RUN_ID" "ingest" "stress" \
    "$NUM_JOBS" "$PUBLISHED" "$FAILED" \
    "$START_TS" "$END_TS" \
    "${S0_AVG:-0}" "${S0_MIN:-0}" "${S0_MAX:-0}" \
    "${S0_P50:-0}" "${S0_P95:-0}"

[[ ${FAILED} -eq 0 ]] && exit 0 || exit 1
