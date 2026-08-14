#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 CERN
# SPDX-License-Identifier: Apache-2.0
#
# e2e-staged-publish.sh — the staged path end to end, through prepub.
#
# Everything so far has been proven in halves: the Go side against fakes
# (cvmfs-bits f2eb51e, six commits), the producer side against a live testbed
# (MEASUREMENTS §21), and the graft by hand. This runs them together, which is
# the only thing that shows the two halves agree.
#
#   1. prepare      — bits' cvmfs_swissknife invocation, no gateway
#   2. walk         — bits' cvmfs_stage finds the SUBTREE catalog
#   3. submit       — POST staging_prefix + catalog_hash to prepub, no tar
#   4. prepub       — promotes the objects, grafts the catalog
#   5. verify       — read the file back through the client
#
# The staging prefix is the D11 shape, staging/<host>/<user>/<job>, which the
# spooler was only recently shown to accept.
#
# MUTATES THE REPOSITORY: prepub publishes a real revision under a fresh
# timestamped path.

set -uo pipefail

REPO="${REPO_NAME:-test.cvmfs.io}"
PUB=cvmfs-native-publisher
TS="$(date +%s)"
STAGE="staging/e2ehost/e2euser/${TS}"
LEASE="e2e/staged/${TS}"
MINIO="http://minio:9000/cvmfs"
S3CONF="/etc/cvmfs/s3/${REPO}.s3.conf"

say() { printf '\n=== %s ===\n' "$*"; }
dex() { docker exec "$PUB" "$@"; }

say "0. state before"
BASE=$(dex sh -c "curl -sf ${MINIO}/${REPO}/.cvmfspublished | tr -d '\\000' | sed -n 's/^C//p' | head -1")
echo "repo=${REPO}  base root=${BASE}"
echo "stage=${STAGE}"
echo "lease=${LEASE}"
[[ -n "$BASE" ]] || { echo "FATAL: no published root"; exit 1; }

say "1. prepare (producer side; no gateway)"
dex sh -c "rm -rf /tmp/e2e && mkdir -p /tmp/e2e/sub && \
  for i in 1 2 3; do head -c 32768 /dev/urandom > /tmp/e2e/sub/f\$i.bin; done && \
  echo e2e-${TS} > /tmp/e2e/marker.txt && tar -cf /tmp/e2e.tar -C /tmp/e2e ." || exit 1
dex cvmfs_swissknife ingest \
  -u "/cvmfs/${REPO}" -c "/var/spool/cvmfs/${REPO}/rdonly" \
  -t "/var/spool/cvmfs/${REPO}/tmp" -b "${BASE}" \
  -r "S3,/var/spool/cvmfs/${REPO}/tmp,${STAGE}@${S3CONF}" \
  -w "${MINIO}/${REPO}" -o "/tmp/e2e-manifest" \
  -K "/etc/cvmfs/keys/${REPO}.pub" -N "${REPO}" -U 0 -G 0 \
  -T /tmp/e2e.tar -B "${LEASE}" -C true 2>&1 | tail -3
MROOT=$(dex sh -c "sed -n 's/^C//p' /tmp/e2e-manifest | tr -d '\\000' | head -1")
echo "manifest root (NOT what we send): ${MROOT}"

say "2. walk to the subtree catalog (bits_helpers/cvmfs_stage)"
CAT=$(docker exec -i "$PUB" python3 - "${MINIO}/${STAGE}" "${MINIO}/${REPO}" "$MROOT" "$LEASE" <<'PY'
import sys
sys.path.insert(0, "/tmp/bits")
from cvmfs_stage import find_subtree_catalog, http_fetcher
stage, repo, root, lease = sys.argv[1:5]
print(find_subtree_catalog(root, lease, http_fetcher(stage, repo)))
PY
)
echo "catalog_hash to send: ${CAT}"
[[ -n "$CAT" && "$CAT" != "$MROOT" ]] || { echo "FATAL: walk failed or returned the root"; exit 1; }

say "3. submit to prepub (no tar)"
TOKEN=$(docker exec cvmfs-prepub sh -c 'tr "\0" "\n" < /proc/1/environ | sed -n "s/^PREPUB_API_TOKEN=//p"')
RESP=$(docker exec cvmfs-prepub sh -c "curl -s -w '\n%{http_code}' -X POST http://localhost:8080/api/v1/jobs \
  -H 'Authorization: Bearer ${TOKEN}' \
  -F repo=${REPO} -F path=${LEASE} -F publish_path=staged \
  -F staging_prefix=${STAGE} -F catalog_hash=${CAT}C")
echo "$RESP"
JOB=$(echo "$RESP" | head -1 | sed -n 's/.*"job_id":"\([^"]*\)".*/\1/p')
[[ -n "$JOB" ]] || { echo "FATAL: no job id — prepub refused the submission"; exit 1; }

say "4. wait for prepub to promote and graft"
for i in $(seq 1 30); do
  ST=$(docker exec cvmfs-prepub sh -c "curl -s -H 'Authorization: Bearer ${TOKEN}' \
       http://localhost:8080/api/v1/jobs/${JOB}" | sed -n 's/.*"state":"\([^"]*\)".*/\1/p')
  echo "  state=${ST}"
  [[ "$ST" == "published" || "$ST" == "failed" ]] && break
  sleep 2
done
echo "--- prepub log for this job ---"
docker logs cvmfs-prepub 2>&1 | grep -F "$JOB" | tail -12

say "5. verify"
AFTER=$(dex sh -c "curl -sf ${MINIO}/${REPO}/.cvmfspublished | tr -d '\\000' | sed -n 's/^C//p' | head -1")
echo "root: ${BASE} -> ${AFTER}   moved=$([[ "$BASE" != "$AFTER" ]] && echo yes || echo NO)"
docker exec cvmfs-client cvmfs_talk -i "${REPO}" remount sync >/dev/null 2>&1
sleep 2
docker exec cvmfs-client sh -c \
  "ls /cvmfs/${REPO}/${LEASE}/ 2>&1 | head -5; cat /cvmfs/${REPO}/${LEASE}/marker.txt 2>&1 | head -1"
