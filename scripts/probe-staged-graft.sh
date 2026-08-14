#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 CERN
# SPDX-License-Identifier: Apache-2.0
#
# probe-staged-graft.sh — ADR-0011 Phase 0b, done properly.
#
# THE QUESTION
#
# prepub's staged path asks the gateway to graft a catalog the producer names
# (`catalog_hash`). MEASUREMENTS §18 recorded what the producer actually emits:
# "the manifest carries a new ROOT catalog computed against -b <base hash>",
# and concluded "the catalogs are a by-product prepub may discard". ADR-0011 D5
# and D6 assume instead that the producer emits a graftable SUBTREE catalog.
#
# Those cannot both be right, and the CI pipeline's whole job is to compute that
# hash. So: run the prepare, look at every catalog it produced, and try the
# graft by hand.
#
# WHAT IT DOES
#
#   phase 1 (default, read-only wrt the repository)
#     - prepare a small payload with `cvmfs_swissknife ingest -r S3,...`,
#       no gateway (no -P, no -H), into an isolated stage-<ts> alias
#     - read the manifest it wrote and report the root hash
#     - walk the catalog tree from that root over HTTP against the STAGING
#       prefix, printing each catalog's root_prefix, revision and nested count
#     - say plainly which catalog, if any, corresponds to the lease path
#
#   phase 2 (--graft, mutates the repository)
#     - server-side copy the staged objects into the repository's CAS
#     - acquire a lease on a FRESH path and POST /graft, once per candidate
#       hash, reporting exactly what the receiver says each time
#     - read the path back through the client
#
# Phase 2 is behind a flag because it commits to the repository. Phase 1 writes
# only into its own stage-<ts> prefix and never touches the repo.
#
# Re-runnable: every run uses a fresh timestamped alias and a fresh lease path,
# so nothing collides with a previous attempt.
#
# Usage:
#   scripts/probe-staged-graft.sh              # phase 1 only
#   scripts/probe-staged-graft.sh --graft      # phase 1 + phase 2
#   REPO_NAME=test.cvmfs.io scripts/probe-staged-graft.sh

set -uo pipefail

PUB=cvmfs-native-publisher
REPO="${REPO_NAME:-test.cvmfs.io}"
TS="$(date +%s)"
STAGE="stage-probe-${TS}"
LEASE_PATH="probe/staged/${TS}"
S3CONF="/etc/cvmfs/s3/${REPO}.s3.conf"
MINIO="http://minio:9000/cvmfs"
DO_GRAFT=0
[[ "${1:-}" == "--graft" ]] && DO_GRAFT=1

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf 'FATAL: %s\n' "$*" >&2; exit 1; }
dex() { docker exec "$PUB" "$@"; }

docker ps --format '{{.Names}}' | grep -qx "$PUB" || die "$PUB is not running (./scripts/testbed.sh ensure)"

say "environment"
echo "repo=${REPO}  stage alias=${STAGE}  lease path=${LEASE_PATH}"
dex sh -c "test -f ${S3CONF}" || die "no S3 config at ${S3CONF}"
BASE_ROOT=$(dex sh -c "curl -sf ${MINIO}/${REPO}/.cvmfspublished | tr -d '\\000' | sed -n 's/^C//p' | head -1")
echo "current published root: ${BASE_ROOT:-<none>}"
[[ -n "$BASE_ROOT" ]] || die "could not read the repository's current root"

# ── payload ──────────────────────────────────────────────────────────────────
# Distinct content so there are real data objects, not just catalogs (the
# lesson from §18: an all-empty payload hides whether objects were produced).
say "phase 1: build a payload"
dex sh -c "rm -rf /tmp/probe && mkdir -p /tmp/probe/sub && \
  for i in 1 2 3 4 5; do head -c 65536 /dev/urandom > /tmp/probe/sub/f\$i.bin; done && \
  echo probe-${TS} > /tmp/probe/marker.txt && \
  tar -cf /tmp/probe.tar -C /tmp/probe ." || die "payload build failed"
dex sh -c "tar -tvf /tmp/probe.tar | head -8"

# ── prepare ──────────────────────────────────────────────────────────────────
say "phase 1: prepare (no gateway: -P and -H both omitted)"
set -x
dex cvmfs_swissknife ingest \
  -u "/cvmfs/${REPO}" \
  -c "/var/spool/cvmfs/${REPO}/rdonly" \
  -t "/var/spool/cvmfs/${REPO}/tmp" \
  -b "${BASE_ROOT}" \
  -r "S3,/var/spool/cvmfs/${REPO}/tmp,${STAGE}@${S3CONF}" \
  -w "${MINIO}/${REPO}" \
  -o "/tmp/probe-manifest-${TS}" \
  -K "/etc/cvmfs/keys/${REPO}.pub" -N "${REPO}" -U 0 -G 0 \
  -T /tmp/probe.tar -B "${LEASE_PATH}" -C true
PREP_RC=$?
set +x
echo "prepare exit: ${PREP_RC}"
[[ $PREP_RC -eq 0 ]] || die "prepare failed — nothing further to probe"

say "phase 1: the manifest it wrote"
dex sh -c "cat /tmp/probe-manifest-${TS} | tr -d '\\000'"
MANIFEST_ROOT=$(dex sh -c "sed -n 's/^C//p' /tmp/probe-manifest-${TS} | tr -d '\\000' | head -1")
echo "manifest root hash: ${MANIFEST_ROOT}"

# ── what catalogs exist, and what each covers ───────────────────────────────
# Walks from the manifest root through nested_catalogs, fetching each catalog
# from the STAGING prefix. This is the question: is any of them a subtree
# catalog whose root_prefix is the lease path, or is the root the only thing
# the producer can name?
say "phase 1: catalogs in the staged prefix, by root_prefix"
dex python3 - "${MINIO}/${STAGE}" "${MANIFEST_ROOT}" "${LEASE_PATH}" <<'PY'
import sys, urllib.request, zlib, sqlite3, tempfile, os
base, root, lease = sys.argv[1], sys.argv[2], sys.argv[3]

def fetch(h):
    # CVMFS object layout: data/<first two hex>/<rest><suffix>
    url = f"{base}/data/{h[:2]}/{h[2:]}"
    with urllib.request.urlopen(url, timeout=30) as r:
        return zlib.decompress(r.read())

def props(blob):
    fd, p = tempfile.mkstemp(suffix=".db"); os.write(fd, blob); os.close(fd)
    try:
        db = sqlite3.connect(p)
        pr = dict(db.execute("select key, value from properties").fetchall())
        nested = db.execute("select path, sha1 from nested_catalogs").fetchall()
        db.close()
        return pr, nested
    finally:
        os.unlink(p)

seen, queue, rows = set(), [(root, 0)], []
while queue:
    h, depth = queue.pop(0)
    if h in seen: continue
    seen.add(h)
    try:
        blob = fetch(h)
    except Exception as e:
        rows.append((h, depth, f"<unfetchable: {e}>", "", 0)); continue
    pr, nested = props(blob)
    rows.append((h, depth, pr.get("root_prefix", "/"), pr.get("revision", "?"), len(nested)))
    for path, sha in nested:
        queue.append((sha + "C", depth + 1))

print(f"{'hash':44} {'d':>2} {'nested':>6}  root_prefix")
for h, d, rp, rev, n in rows:
    print(f"{h:44} {d:>2} {n:>6}  {rp}")

print()
want = "/" + lease.strip("/")
hits = [h for h, d, rp, rev, n in rows if rp == want]
if hits:
    print(f"VERDICT: a catalog covers the lease path {want!r}: {hits[0]}")
    print("         -> the producer CAN name a subtree catalog; ADR-0011 D5/D6 hold.")
else:
    print(f"VERDICT: NO catalog has root_prefix {want!r}.")
    print(f"         The manifest root {root} covers {rows[0][2]!r}.")
    print("         -> the prepare emits a revision, not a graftable subtree;")
    print("            MEASUREMENTS §18 is right and catalog_hash must come from")
    print("            somewhere else (or the graft is the wrong mechanism).")
PY

if [[ $DO_GRAFT -eq 0 ]]; then
  say "phase 1 complete — repository untouched"
  echo "staged prefix left in place for inspection: ${STAGE}"
  echo "re-run with --graft to attempt the graft (this WILL commit to ${REPO})"
  exit 0
fi

say "phase 2: NOT IMPLEMENTED YET"
echo "Deliberately stopped here. What phase 2 should attempt depends entirely on"
echo "phase 1's verdict above, and guessing it in advance is how the last three"
echo "days went. Report the table, then extend this script."
exit 0
