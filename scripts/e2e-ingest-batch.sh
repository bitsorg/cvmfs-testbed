#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 CERN
# SPDX-License-Identifier: Apache-2.0
#
# e2e-ingest-batch.sh — the ingest-batch publish path end to end, through prepub.
#
# Needs a prepub with ingest_publish and ingest_batch_max >= 2 (and, so that the
# packages reliably meet, ingest_batch_linger of a second or two). Submits N small
# packages at once on ingest-batch (one of them already published, which must
# end as already_published), then the same N on plain ingest, and checks:
#   1. every package published, each with its own nested catalog;
#   2. the ingest-batch records share batch ids (batch_size > 1), ingest's none;
#   3. the two runs' commits and backend time, side by side (one run each).
#
# MUTATES THE REPOSITORY: publishes under e2e/ingest-batch/<time>/ only.
set -uo pipefail
REPO="${REPO_NAME:-test.cvmfs.io}"
N="${N:-6}"
PREPUB=cvmfs-prepub
TS="$(date +%s)"
ROOT="e2e/ingest-batch/${TS}"
failed=0

say() { printf '\n=== %s ===\n' "$*"; }
dex() { docker exec "$PREPUB" "$@"; }
fail() { echo "FAIL $*"; failed=1; }
TOKEN=$(dex sh -c 'tr "\0" "\n" < /proc/1/environ | sed -n "s/^PREPUB_API_TOKEN=//p"')
api() { dex curl -s -H "Authorization: Bearer ${TOKEN}" "http://localhost:8080$1"; }
# Where cvmfs_server reads the repository (localfs stratum-0 or the S3 bucket).
S0="${STRATUM0:-$(dex sh -c "sed -n 's/^CVMFS_STRATUM0=//p' /etc/cvmfs/repositories.d/${REPO}/server.conf" | tr -d "\"'" | tail -n 1)}"

say "0. the prepub offers ingest-batch"
api /api/v1/health | grep -q '"ingest-batch"' || {
  echo "FATAL: publish_paths has no ingest-batch: run cvmfs-bits 0009 or later with"
  echo "       ingest_publish: true and ingest_batch_max: 2 or more"; exit 1; }
echo "repo=${REPO} at ${S0}, root=/${ROOT}, packages=${N}"

# One tar per package under /tmp/e2eb in the container: three small files and a marker.
dex sh -c "rm -rf /tmp/e2eb && mkdir -p /tmp/e2eb && cd /tmp/e2eb && \
  for i in \$(seq 1 ${N}); do mkdir -p p\$i/bin && head -c 8192 /dev/urandom > p\$i/bin/f && \
    echo p\$i-${TS} > p\$i/marker.txt && tar -cf p\$i.tar -C p\$i . ; done" || exit 1

jobid() { sed -n 's/.*"job_id" *: *"\([^"]*\)".*/\1/p'; }
# curl_job <publish_path> <build_id> <package> <path> [extra -F args]: the submission, as a command
curl_job() {
  local how=$1 build=$2 pkg=$3 path=$4; shift 4
  echo "curl -s -X POST http://localhost:8080/api/v1/jobs -H 'Authorization: Bearer ${TOKEN}' \
    -F repo=${REPO} -F path=${path} -F publish_path=${how} -F build_id=${build} \
    -F tar_sha256=\$(sha256sum /tmp/e2eb/${pkg}.tar | cut -c1-64) $* \
    -F 'tar=@/tmp/e2eb/${pkg}.tar;type=application/octet-stream'"
}

wait_jobs() {   # wait_jobs <job id>...: until every job is published or failed
  local j st
  for j in "$@"; do
    for _ in $(seq 1 120); do
      st=$(api "/api/v1/jobs/${j}" | sed -n 's/.*"state" *: *"\([^"]*\)".*/\1/p')
      [[ "$st" == published || "$st" == failed || "$st" == aborted ]] && break
      sleep 1
    done
    [[ "$st" == published ]] || fail "job ${j}: ${st:-no state}"
  done
}

run() {   # run <publish_path> <build_id> <sub dir>: all N packages submitted together
  local how=$1 build=$2 dir=$3 cmds="" id i jobs=()
  for i in $(seq 1 "$N"); do
    local extra=""   # p1 is published already on ingest-batch: its identity makes it skip
    [[ $i == 1 && $how == ingest-batch ]] && extra="-F identity_path=${ROOT}/${dir}/Packages/p1/1-1"
    cmds+="$(curl_job "$how" "$build" "p$i" "${ROOT}/${dir}/Packages/p$i/1-1" $extra) > /tmp/e2eb/${build}.p$i.out & "
  done
  dex sh -c "${cmds} wait" || fail "${how}: submitting"
  for i in $(seq 1 "$N"); do
    id=$(dex cat "/tmp/e2eb/${build}.p$i.out" | jobid)
    [[ -n "$id" ]] || { fail "${how} p$i: refused: $(dex cat "/tmp/e2eb/${build}.p$i.out")"; continue; }
    jobs+=("$id")
  done
  [[ ${#jobs[@]} -gt 0 ]] && wait_jobs "${jobs[@]}"
}

say "1. ingest-batch: p1 first alone (plain ingest), then p1..p${N} at once"
P1=$(dex sh -c "$(curl_job ingest "e2eb-${TS}-seed" p1 "${ROOT}/batch/Packages/p1/1-1")" | jobid)
[[ -n "$P1" ]] || { echo "FATAL: the seed submission was refused"; exit 1; }
wait_jobs "$P1"
t0=$(date +%s%N); run ingest-batch "e2eb-${TS}" batch; t1=$(date +%s%N)

say "2. ingest: p1..p${N} at once"
t2=$(date +%s%N); run ingest "e2ei-${TS}" plain; t3=$(date +%s%N)

say "3. records"
api "/api/v1/measurements/e2eb-${TS}" | docker exec -i "$PREPUB" python3 -c '
import json, sys
recs = json.load(sys.stdin)
out = {r["path"].rsplit("/", 2)[-2]: r for r in recs}
ok = len(recs) == int(sys.argv[1])
ids = {r.get("batch_id") for r in recs if r.get("batch_id")}
big = [r for r in recs if (r.get("batch_size") or 0) > 1]
print("records %d, batches %d, packages in a batch %d" % (len(recs), len(ids), len(big)))
for name in sorted(out):
    r = out[name]
    print("  %-4s %-17s %-13s batch %s x%s backend %s" % (name, r["outcome"], r["publish_path"],
          r.get("batch_id", "-"), r.get("batch_size", "-"), r.get("backend_s")))
ok = ok and out.get("p1", {}).get("outcome") == "already_published"
ok = ok and all(r["outcome"] == "published" for n, r in out.items() if n != "p1")
ok = ok and len(big) >= 2 and all(r["publish_path"] == "ingest-batch" for r in recs)
sys.exit(0 if ok else 1)' "$N" || fail "ingest-batch records (want p1 already_published, the rest published, >= 2 in a batch)"
api "/api/v1/measurements/e2ei-${TS}" | docker exec -i "$PREPUB" python3 -c '
import json, sys
recs = json.load(sys.stdin)
sys.exit(0 if len(recs) == int(sys.argv[1]) and not any(r.get("batch_id") for r in recs)
         and all(r["outcome"] == "published" for r in recs) else 1)' "$N" \
  && echo "ingest records: ${N} published, none batched" || fail "ingest records"

say "4. one nested catalog per package"
CATS=$(docker exec -i "$PREPUB" python3 - "${S0}" "/${ROOT}" <<'PY'
import sys, sqlite3, tempfile, urllib.request, zlib
base, want = sys.argv[1], sys.argv[2]
get = lambda u: urllib.request.urlopen(u, timeout=30).read()
lines = get(base + "/.cvmfspublished").split(b"--\n")[0].decode().splitlines()
def walk(h):
    with tempfile.NamedTemporaryFile(suffix=".db") as f:
        f.write(zlib.decompress(get("%s/data/%s/%sC" % (base, h[:2], h[2:]))))
        f.flush()
        rows = sqlite3.connect(f.name).execute("SELECT path, sha1 FROM nested_catalogs").fetchall()
    for path, sha in rows:
        if path.startswith(want + "/") or (want + "/").startswith(path + "/"):
            if path.startswith(want + "/"):
                print(path[len(want) + 1:])
            walk(sha)
walk(next(l[1:] for l in lines if l.startswith("C")))
PY
)
missing=0
for d in batch plain; do
  for i in $(seq 1 "$N"); do
    grep -qx "${d}/Packages/p$i/1-1" <<<"$CATS" || { fail "${d}/Packages/p$i/1-1 is not a nested catalog"; missing=1; }
  done
done
[[ $missing -eq 0 ]] && echo "PASS every package has its own catalog"

say "5. side by side (one run each, not a benchmark)"
for b in "e2eb-${TS}" "e2ei-${TS}"; do
  api "/api/v1/measurements/${b}?summary=1" | docker exec -i "$PREPUB" python3 -c '
import json, sys
s = json.load(sys.stdin); b = s.get("backend_s") or {}
print("  %-22s jobs %d, commits %d, backend sum %.2f s, window %.2f s" % (sys.argv[1],
      s.get("jobs", 0), b.get("n", 0), b.get("sum", 0), s.get("window_s", 0)))' "$b"
done
echo "  wall clock: ingest-batch $(( (t1 - t0) / 1000000 )) ms, ingest $(( (t3 - t2) / 1000000 )) ms"

echo
echo "to remove the test tree: docker exec ${PREPUB} cvmfs_server ingest -d ${ROOT} ${REPO}"
[[ $failed -eq 0 ]] && echo "ALL PASS" || echo "SOME CHECKS FAILED"
exit $failed
