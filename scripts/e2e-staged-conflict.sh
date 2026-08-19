#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 CERN
# SPDX-License-Identifier: Apache-2.0
#
# e2e-staged-conflict.sh — staged replace_on_conflict, end to end THROUGH prepub.
#
# probe-staged-conflict.py proved the remediation by driving the gateway by hand
# (MEASUREMENTS §29). This proves the SAME thing through prepub's real
# replaceOnConflict: two staged publishes into one path, the second replacing
# the first, driven by nothing but a normal job submission.
#
#   1. publish A into a fresh path P          -> expect job "published"
#   2. publish B into the SAME occupied P     -> expect job "published" (replaced)
#      the producer prepare uses -D P -f so it can extract over the occupied
#      path; prepub's graft is refused (merge_error), then replaceOnConflict
#      releases the lease, ingest -f deletes the subtree, re-acquires and
#      re-grafts B — all inside prepub.
#   3. the client reads B, not A.
#
# Requires prepub started with --replace-on-conflict AND --ingest-publish. The
# catalog walk is inlined (staging-first, repository fallback, C-suffixed), so
# nothing depends on a /tmp/bits deployment.
#
# MUTATES THE REPOSITORY. Fresh per-run path; reset (make clean / redeploy)
# between comparison runs.
#
# Usage: scripts/e2e-staged-conflict.sh   [REPO_NAME=test.cvmfs.io]

set -uo pipefail

REPO="${REPO_NAME:-test.cvmfs.io}"
PUB=cvmfs-native-publisher
TS="$(date +%s)"
P="conflict/e2e/${TS}"                 # fresh path; A and B both target it
MINIO="http://minio:9000/cvmfs"        # network DNS inside the compose net
S3CONF="/etc/cvmfs/s3/${REPO}.s3.conf"

say()  { printf '\n=== %s ===\n' "$*"; }
die()  { printf 'FATAL: %s\n' "$*" >&2; exit 1; }
dex()  { docker exec "$PUB" "$@"; }

for c in "$PUB" cvmfs-prepub cvmfs-gateway cvmfs-client cvmfs-minio; do
  docker ps --format '{{.Names}}' | grep -qx "$c" || die "$c is not running (make ensure)"
done

say "0. preflight"
CMDLINE=$(docker exec cvmfs-prepub sh -c 'tr "\0" " " < /proc/1/cmdline')
echo "$CMDLINE" | grep -q -- '--replace-on-conflict' \
  || die "prepub is NOT running with --replace-on-conflict (set REPLACE_ON_CONFLICT=true in .env, then: make redeploy-prepub)"
echo "$CMDLINE" | grep -q -- '--ingest-publish' \
  || die "prepub is NOT running with --ingest-publish — the staged delete borrows cvmfs_server from it"
echo "replace_on_conflict + ingest-publish: ON"
TOKEN=$(docker exec cvmfs-prepub sh -c 'tr "\0" "\n" < /proc/1/environ | sed -n "s/^PREPUB_API_TOKEN=//p"')
[[ -n "$TOKEN" ]] || die "could not read PREPUB_API_TOKEN from the prepub container"

# Inlined subtree-catalog walk (port of bits_helpers/cvmfs_stage.find_subtree_
# catalog + http_fetcher): staging prefix first, repository as fallback,
# catalogs are <host>/data/<2><rest>C. Runs inside PUB (minio: resolves there).
read -r -d '' WALK_PY <<'PY'
import sys, os, zlib, sqlite3, tempfile, urllib.request
stage_url, repo_url, root, want = sys.argv[1:5]
def data_url(host, h):
    h = h.strip()
    return "%s/data/%s/%sC" % (host.rstrip("/"), h[:2], h[2:])
def fetch_one(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent":"e2c"}), timeout=30) as r:
        blob = r.read()
    for wb in (zlib.MAX_WBITS, -zlib.MAX_WBITS):
        try: return zlib.decompressobj(wb).decompress(blob)
        except zlib.error: continue
    raise RuntimeError("decompress failed")
def fetch(h):
    try: return fetch_one(data_url(stage_url, h))
    except Exception: return fetch_one(data_url(repo_url, h))
def read_cat(blob):
    fd,p = tempfile.mkstemp(suffix=".db"); os.write(fd,blob); os.close(fd)
    try:
        db=sqlite3.connect(p)
        pr=dict(db.execute("select key,value from properties").fetchall())
        nested=db.execute("select path,sha1 from nested_catalogs").fetchall()
        db.close(); return pr,nested
    finally: os.unlink(p)
seen,queue,visited=set(),[root],[]
while queue:
    h=queue.pop(0)
    if h in seen: continue
    seen.add(h)
    try: pr,nested=read_cat(fetch(h))
    except Exception as e:
        visited.append((h,"<unreachable: %s>"%e)); continue
    prefix=pr.get("root_prefix","/"); visited.append((h,prefix))
    if prefix==want:
        print(h); sys.exit(0)
    for npath,sha in nested:
        if not sha or sha in seen: continue
        np="/"+(npath or "").strip("/")
        if want==np or want.startswith(np.rstrip("/")+"/"): queue.append(sha)
sys.stderr.write("no catalog with root_prefix %r; visited:\n"%want)
for h,pfx in visited: sys.stderr.write("  %s  %s\n"%(h,pfx))
sys.exit(1)
PY

# publish_staged <stage-alias> <tag> <delete>  -> echoes the final job state
# delete=1 adds -D <P> -f so the producer prepare can extract over an occupied P.
publish_staged() {
  local stage="$1" tag="$2" delete="$3"
  local base mroot cat resp job st manifest
  manifest="/tmp/e2c-manifest-${tag}"          # slash-free (tag has no slashes)
  base=$(dex sh -c "curl -sf ${MINIO}/${REPO}/.cvmfspublished | tr -d '\\000' | sed -n 's/^C//p' | head -1")
  [[ -n "$base" ]] || { echo "FATAL: no published root before ${tag}" >&2; return 1; }

  dex sh -c "rm -rf /tmp/e2c && mkdir -p /tmp/e2c/sub && \
    for i in 1 2 3; do head -c 32768 /dev/urandom > /tmp/e2c/sub/f\$i.bin; done && \
    echo ${tag} > /tmp/e2c/marker.txt && tar -cf /tmp/e2c.tar -C /tmp/e2c ." \
    || { echo "FATAL: payload build failed for ${tag}" >&2; return 1; }

  local args=(cvmfs_swissknife ingest
    -u "/cvmfs/${REPO}" -c "/var/spool/cvmfs/${REPO}/rdonly"
    -t "/var/spool/cvmfs/${REPO}/tmp" -b "${base}"
    -r "S3,/var/spool/cvmfs/${REPO}/tmp,${stage}@${S3CONF}"
    -w "${MINIO}/${REPO}" -o "${manifest}"
    -K "/etc/cvmfs/keys/${REPO}.pub" -N "${REPO}" -U 0 -G 0
    -T /tmp/e2c.tar -B "${P}" -C true)
  [[ "$delete" == "1" ]] && args+=(-D "${P}" -f)
  dex "${args[@]}" 2>&1 | tail -2 >&2
  mroot=$(dex sh -c "sed -n 's/^C//p' ${manifest} 2>/dev/null | tr -d '\\000' | head -1")
  [[ -n "$mroot" ]] || { echo "FATAL: no manifest root for ${tag} (prepare failed)" >&2; return 1; }

  cat=$(docker exec -i "$PUB" python3 -c "$WALK_PY" \
        "${MINIO}/${stage}" "${MINIO}/${REPO}" "$mroot" "/${P}")
  [[ -n "$cat" && "$cat" != "$mroot" ]] || { echo "FATAL: walk failed for ${tag} (got '${cat}')" >&2; return 1; }

  resp=$(docker exec cvmfs-prepub sh -c "curl -s -w '\n%{http_code}' -X POST http://localhost:8080/api/v1/jobs \
    -H 'Authorization: Bearer ${TOKEN}' \
    -F repo=${REPO} -F path=${P} -F publish_path=staged \
    -F staging_prefix=${stage} -F catalog_hash=${cat}C")
  job=$(echo "$resp" | head -1 | sed -n 's/.*"job_id":"\([^"]*\)".*/\1/p')
  [[ -n "$job" ]] || { echo "FATAL: prepub refused ${tag}: ${resp}" >&2; return 1; }

  for _ in $(seq 1 60); do
    st=$(docker exec cvmfs-prepub sh -c "curl -s -H 'Authorization: Bearer ${TOKEN}' \
         http://localhost:8080/api/v1/jobs/${job}" | sed -n 's/.*"state":"\([^"]*\)".*/\1/p')
    [[ "$st" == "published" || "$st" == "failed" ]] && break
    sleep 2
  done
  echo "  ${tag}: job ${job} -> ${st}" >&2
  docker logs cvmfs-prepub 2>&1 | grep -F "$job" | grep -iE "replace_on_conflict|deleting|replaced" | tail -4 >&2
  echo "$st"
}

say "1. publish A into a fresh path P=${P}"
STA=$(publish_staged "staging/e2c/${TS}/a" "E2C-A-${TS}" 0)
[[ "$STA" == "published" ]] || die "publish A did not publish (state=${STA})"

say "2. publish B into the SAME occupied P (expect replace_on_conflict to replace)"
STB=$(publish_staged "staging/e2c/${TS}/b" "E2C-B-${TS}" 1)

say "3. verify"
docker exec cvmfs-client cvmfs_talk -i "${REPO}" remount sync >/dev/null 2>&1
sleep 2
MARK=$(docker exec cvmfs-client sh -c "cat /cvmfs/${REPO}/${P}/marker.txt 2>&1 | head -1")
echo "job B state : ${STB}   (want: published)"
echo "client marker: ${MARK}   (want: E2C-B-${TS})"

if [[ "$STB" == "published" && "$MARK" == "E2C-B-${TS}" ]]; then
  echo; echo "PASS: prepub replaced the occupied staged path end to end."
  exit 0
fi
echo; echo "FAIL: B state=${STB}, marker=${MARK}. Check the prepub log lines above —"
echo "a 'failed' B with replace_on_conflict ON is the finding to record, not to hide."
exit 1
