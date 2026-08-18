#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 CERN
# SPDX-License-Identifier: Apache-2.0
"""probe-staged-conflict.py — ADR-0011 step 2: staged delete-then-graft, by hand.

MEASUREMENTS §25 proved `ingest -f <path>` + re-ingest on the INGEST path,
standalone, with no competing gateway lease. That is not the case the staged
replace_on_conflict path faces. This probe proves the remaining case:

    a staged commit that CONFLICTS on an occupied path, remediated while the
    job's own gateway lease is still in the picture.

It reproduces, by hand, the sequence orchestrator.go:2318-2337 says is correct
and the two failure modes that comment predicts:

    release the lease -> delete (ingest -f) -> re-read the manifest root
        -> re-acquire -> retry the graft

  NEGATIVE CONTROL A: run `ingest -f` while the conflicting lease is STILL open
                      -> must fail path_busy (the dead job still holds the lease)
  NEGATIVE CONTROL B: retry the graft with the STALE pre-delete root hash
                      -> must be rejected (the delete advanced the root)

Only if BOTH controls fail as predicted, and the correct sequence then lands, is
the ordering proven necessary rather than incidental.

MUTATES THE REPOSITORY. It commits several real revisions and deletes a subtree.
Everything happens under one per-run timestamped path, so it never touches an
unrelated path, but the repository root moves and a subtree is destroyed and
recreated. Run against the testbed only. Reset afterwards with `make clean` /
redeploy if you want a pristine tree.

Auth (cvmfs-bits internal/lease/auth.go): `<key_id> <base64(hex(HMAC-SHA1(...)))>`
— over the request body for acquire, over the token for graft and release.

Usage:
  scripts/probe-staged-conflict.py                 # full run (MUTATES repo)
  scripts/probe-staged-conflict.py --dry-run       # stop before the first graft
  scripts/probe-staged-conflict.py --lease-path conflict/staged/fixed
"""
import argparse
import base64
import hashlib
import hmac
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.request

BUCKET = "cvmfs"
REPO = os.environ.get("REPO_NAME", "test.cvmfs.io")
PUB = "cvmfs-native-publisher"
GW_URL = "http://localhost:4929"
MINIO_INTERNAL = f"http://minio:9000/{BUCKET}"          # as seen inside the compose net
S3CONF = f"/etc/cvmfs/s3/{REPO}.s3.conf"

# One row per phase: what we expected, what we saw. Printed as the verdict.
LEDGER = []


def record(phase, expected, observed, ok):
    LEDGER.append((phase, expected, observed, ok))
    mark = "OK  " if ok else "FAIL"
    print(f"\n[{mark}] {phase}\n       expected: {expected}\n       observed: {observed}")


def dex(container, *cmd):
    # errors="replace": .cvmfspublished carries a binary signature after the
    # text fields; strict decoding dies on it before the C line is read.
    return subprocess.run(["docker", "exec", container, *cmd],
                          capture_output=True, text=True, errors="replace").stdout


def dex_rc(container, *cmd):
    """Like dex() but returns (rc, stdout+stderr) so we can inspect failures."""
    p = subprocess.run(["docker", "exec", container, *cmd],
                       capture_output=True, text=True, errors="replace")
    return p.returncode, (p.stdout + p.stderr)


def die(msg):
    print(f"\nFATAL: {msg}", file=sys.stderr)
    sys.exit(1)


# ── S3 (host side, via the published MinIO port) ─────────────────────────────
def s3_client():
    import boto3
    conf = dex(PUB, "cat", S3CONF)
    kv = {}
    for line in conf.splitlines():
        if "=" in line and not line.startswith("#"):
            k, _, v = line.partition("=")
            kv[k.strip()] = v.strip().strip("'\"")
    if "CVMFS_S3_ACCESS_KEY" not in kv:
        die(f"could not read S3 credentials from {S3CONF} in {PUB}")
    return boto3.client(
        "s3", endpoint_url="http://localhost:9000",
        aws_access_key_id=kv["CVMFS_S3_ACCESS_KEY"],
        aws_secret_access_key=kv["CVMFS_S3_SECRET_KEY"],
        region_name=kv.get("CVMFS_S3_REGION", "us-east-1"))


def promote(s3, stage, dry=False):
    """cas.PromoteFrom by hand: server-side copy stage/data/** -> <repo>/data/**,
    skip what already exists. Content addressing makes repeats safe."""
    src_prefix = f"{stage}/data/"
    copied = skipped = 0
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=BUCKET, Prefix=src_prefix):
        for obj in page.get("Contents", []):
            rel = obj["Key"][len(src_prefix):]
            dst = f"{REPO}/data/{rel}"
            try:
                s3.head_object(Bucket=BUCKET, Key=dst)
                skipped += 1
                continue
            except Exception:
                pass
            if not dry:
                s3.copy_object(Bucket=BUCKET, Key=dst,
                               CopySource={"Bucket": BUCKET, "Key": obj["Key"]})
            copied += 1
    return copied, skipped


# ── gateway ──────────────────────────────────────────────────────────────────
class Gateway:
    def __init__(self, url, key_id, secret):
        self.url, self.key_id, self.secret = url, key_id, secret

    def _sig(self, data: bytes) -> str:
        mac = hmac.new(self.secret.encode(), data, hashlib.sha1).hexdigest()
        return base64.b64encode(mac.encode()).decode()

    def _req(self, method, path, body, sig_input):
        req = urllib.request.Request(self.url + path, data=body, method=method)
        req.add_header("Content-Type", "application/json")
        req.add_header("Authorization", f"{self.key_id} {self._sig(sig_input)}")
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                return r.status, r.read().decode()
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode()

    def acquire(self, path):
        body = json.dumps({"path": path, "api_version": "3"}).encode()
        code, txt = self._req("POST", "/api/v1/leases", body, body)
        token = ""
        try:
            token = json.loads(txt).get("session_token", "")
        except Exception:
            pass
        return code, txt, token

    def graft(self, token, old_root, new_root, tag=""):
        body = json.dumps({
            "old_root_hash": old_root, "new_root_hash": new_root,
            "tag_name": tag, "tag_description": "",
        }).encode()
        return self._req("POST", f"/api/v1/leases/{token}/graft", body, token.encode())

    def release(self, token):
        # DELETE /api/v1/leases/<token>, HMAC over the token (lease.go Release).
        return self._req("DELETE", f"/api/v1/leases/{token}", None, token.encode())


def gateway():
    parts = dex("cvmfs-gateway", "cat", f"/etc/cvmfs/keys/{REPO}.gw").split()
    if len(parts) < 3:
        die(f"could not read gateway key /etc/cvmfs/keys/{REPO}.gw (got {parts!r})")
    return Gateway(GW_URL, parts[1], parts[2])


def published_root():
    out = dex(PUB, "sh", "-c",
              f"curl -sf {MINIO_INTERNAL}/{REPO}/.cvmfspublished | tr -d '\\000'")
    for line in out.splitlines():
        if line.startswith("C"):
            return line[1:].strip()
    return ""


# ── producer prepare (no gateway) + subtree-catalog discovery ────────────────
def prepare(stage, lease_path, tag, delete_path=None):
    """Run `cvmfs_swissknife ingest` in prepare mode (no -P/-H) into an isolated
    staging alias, exactly as probe-staged-graft.sh does. `delete_path`, when
    set, adds `-D <path>` so the prepare can extract over an already-published
    path (the cvmfs-stage --replace fix). Returns (rc, manifest_root)."""
    base_root = published_root()
    if not base_root:
        die("could not read the current published root before prepare")
    # Distinct random content per publish so a read-back can tell A from B.
    build = (f"rm -rf /tmp/pc && mkdir -p /tmp/pc/sub && "
             f"for i in 1 2 3; do head -c 65536 /dev/urandom > /tmp/pc/sub/f$i.bin; done && "
             f"echo {tag} > /tmp/pc/marker.txt && "
             f"tar -cf /tmp/pc.tar -C /tmp/pc .")
    rc, out = dex_rc(PUB, "sh", "-c", build)
    if rc != 0:
        die(f"payload build failed for {tag}: {out}")
    manifest = f"/tmp/pc-manifest-{stage}"
    args = ["cvmfs_swissknife", "ingest",
            "-u", f"/cvmfs/{REPO}",
            "-c", f"/var/spool/cvmfs/{REPO}/rdonly",
            "-t", f"/var/spool/cvmfs/{REPO}/tmp",
            "-b", base_root,
            "-r", f"S3,/var/spool/cvmfs/{REPO}/tmp,{stage}@{S3CONF}",
            "-w", f"{MINIO_INTERNAL}/{REPO}",
            "-o", manifest,
            "-K", f"/etc/cvmfs/keys/{REPO}.pub", "-N", REPO, "-U", "0", "-G", "0",
            "-T", "/tmp/pc.tar", "-B", lease_path, "-C", "true"]
    if delete_path:
        # -f must travel WITH -D. -D alone classifies the entry through the
        # read-only union view a mountless prepare lacks, so the delete is
        # refused ("cannot be deleted. Unrecognized file type.") and the prepare
        # PANICs on the very UNIQUE constraint -D was passed to avoid. -f is the
        # fork-local catalog-based fast delete (bits 6a67f9e, measured
        # 2026-08-16); a stock swissknife rejects it.
        args += ["-D", delete_path, "-f"]
    print(f"  prepare {tag}: swissknife ingest -B {lease_path}"
          + (f" -D {delete_path} -f" if delete_path else ""))
    rc, out = dex_rc(PUB, *args)
    print("  " + "\n  ".join(out.splitlines()[-6:]) if out.strip() else "  (no output)")
    if rc != 0:
        return rc, ""
    root = dex(PUB, "sh", "-c",
               f"sed -n 's/^C//p' {manifest} | tr -d '\\000' | head -1").strip()
    return 0, root


def subtree_catalog(stage, manifest_root, lease_path):
    """Return the unsuffixed hash of the SUBTREE catalog whose root_prefix is
    the lease path — the graftable catalog prepub sends. Faithful port of
    bits_helpers/cvmfs_stage.find_subtree_catalog + http_fetcher:

      - catalog objects are <host>/data/<2>/<rest>C  (the trailing C matters —
        fetching the root without it is why the first draft found nothing),
      - fetch tries the STAGING prefix, then falls back to the REPOSITORY prefix
        (the prepare does not re-stage catalogs it did not change),
      - descend only into nested branches that could contain the target.

    Runs inside PUB because the minio: hostname only resolves on the compose
    network. On no match it prints the visited table to stderr for diagnosis."""
    script = r'''
import sys, re, os, zlib, sqlite3, tempfile, urllib.request
stage_url, repo_url, root, want = sys.argv[1:5]
def data_url(host, h):
    h = h.strip()
    return "%s/data/%s/%sC" % (host.rstrip("/"), h[:2], h[2:])
def fetch_one(url):
    req = urllib.request.Request(url, headers={"User-Agent": "probe"})
    with urllib.request.urlopen(req, timeout=30) as r:
        blob = r.read()
    for wb in (zlib.MAX_WBITS, -zlib.MAX_WBITS):
        try: return zlib.decompressobj(wb).decompress(blob)
        except zlib.error: continue
    raise RuntimeError("decompress failed")
def fetch(h):
    try: return fetch_one(data_url(stage_url, h))
    except Exception: return fetch_one(data_url(repo_url, h))
def read_cat(blob):
    fd, p = tempfile.mkstemp(suffix=".db"); os.write(fd, blob); os.close(fd)
    try:
        db = sqlite3.connect(p)
        pr = dict(db.execute("select key, value from properties").fetchall())
        nested = db.execute("select path, sha1 from nested_catalogs").fetchall()
        db.close(); return pr, nested
    finally: os.unlink(p)
seen, queue, visited = set(), [root], []
while queue:
    h = queue.pop(0)
    if h in seen: continue
    seen.add(h)
    try: pr, nested = read_cat(fetch(h))
    except Exception as e:
        visited.append((h, "<unreachable: %s>" % e)); continue
    prefix = pr.get("root_prefix", "/")
    visited.append((h, prefix))
    if prefix == want:
        print(h); sys.exit(0)
    for npath, sha in nested:
        if not sha or sha in seen: continue
        np = "/" + (npath or "").strip("/")
        if want == np or want.startswith(np.rstrip("/") + "/"):
            queue.append(sha)
sys.stderr.write("no catalog with root_prefix %r; visited:\n" % want)
for h, p in visited: sys.stderr.write("  %s  %s\n" % (h, p))
sys.exit(1)
'''
    p = subprocess.run(
        ["docker", "exec", PUB, "python3", "-c", script,
         f"{MINIO_INTERNAL}/{stage}", f"{MINIO_INTERNAL}/{REPO}",
         manifest_root, "/" + lease_path.strip("/")],
        capture_output=True, text=True, errors="replace")
    if p.returncode != 0:
        print(p.stderr.rstrip())
        return None
    return p.stdout.strip() or None


# ── the proof ────────────────────────────────────────────────────────────────
def gw_ok(body):
    """The gateway signals graft OUTCOME in the JSON body, not the HTTP status:
    a refused graft is HTTP 200 with {"status":"error","reason":"merge_error"}.
    merge_error is exactly the conflict signal replaceOnConflict keys on."""
    try:
        return json.loads(body).get("status") == "ok"
    except Exception:
        return False


def readback(lease_path):
    dex("cvmfs-client", "cvmfs_talk", "-i", REPO, "remount", "sync")
    time.sleep(2)
    return dex("cvmfs-client", "sh", "-c",
               f"cat /cvmfs/{REPO}/{lease_path}/marker.txt 2>&1 | head -1").strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lease-path", default=f"conflict/staged/{int(time.time())}",
                    help="path both publishes target (default: a fresh per-run path)")
    ap.add_argument("--dry-run", action="store_true",
                    help="prepare + promote only; stop before the first graft")
    a = ap.parse_args()
    P = a.lease_path.strip("/")
    ts = int(time.time())
    stage_a, stage_b = f"stage-ca-{ts}", f"stage-cb-{ts}"

    running = subprocess.run(
        ["docker", "ps", "--format", "{{.Names}}"], capture_output=True, text=True).stdout
    for c in (PUB, "cvmfs-gateway", "cvmfs-client", "minio"):
        if c not in running:
            die(f"{c} is not running (./scripts/testbed.sh ensure)")

    print(f"repo={REPO}  conflict path={P}  stages={stage_a},{stage_b}")
    s3 = s3_client()
    gw = gateway()
    r0 = published_root()
    print(f"published root (R0): {r0}")

    # ── Phase 1: publish #1 into P (must succeed — P is new) ─────────────────
    print("\n########## Phase 1: staged publish #1 into a fresh P ##########")
    rc, mroot_a = prepare(stage_a, P, f"PUBLISH-A-{ts}")
    if rc != 0:
        die("prepare A failed — nothing to build on")
    promote(s3, stage_a, a.dry_run)
    cat_a = subtree_catalog(stage_a, mroot_a, P)
    if not cat_a:
        die(f"no subtree catalog with root_prefix /{P} in {stage_a}")
    print(f"  subtree catalog A: {cat_a}")
    if a.dry_run:
        print("\n=== --dry-run: stopping before any graft ===")
        return 0
    code, body, la = gw.acquire(f"{REPO}/{P}")
    if not la:
        die(f"acquire for publish #1 failed: {code} {body[:200]}")
    code, body = gw.graft(la, r0, cat_a + "C")
    ok1 = code == 200 and gw_ok(body)
    record("Phase 1: publish #1 grafts into fresh P",
           "HTTP 200, root moves", f"HTTP {code} {body[:160]}", ok1)
    if not ok1:
        die("publish #1 did not land — cannot manufacture a conflict")
    time.sleep(3)
    r1 = published_root()
    print(f"  read-back A: {readback(P)!r}   published root (R1): {r1}")

    # ── Phase 2: publish #2 into the SAME P -> graft must be refused ─────────
    print("\n########## Phase 2: staged publish #2 into the occupied P ##########")
    # -D P lets the PREPARE extract over the occupied path (the --replace fix);
    # the graft is expected to refuse regardless (ADR-0011 D17).
    rc, mroot_b = prepare(stage_b, P, f"PUBLISH-B-{ts}", delete_path=P)
    if rc != 0:
        die("prepare B failed (even with -D) — cannot proceed to the graft refusal")
    promote(s3, stage_b, False)
    cat_b = subtree_catalog(stage_b, mroot_b, P)
    if not cat_b:
        die(f"no subtree catalog with root_prefix /{P} in {stage_b}")
    print(f"  subtree catalog B: {cat_b}")
    code, body, lb = gw.acquire(f"{REPO}/{P}")
    if not lb:
        die(f"acquire for publish #2 failed: {code} {body[:200]}")
    code, body = gw.graft(lb, r1, cat_b + "C")
    refused = not gw_ok(body)
    record("Phase 2: graft #2 onto occupied P is refused (D17)",
           "status:error (merge_error) — the graft-into-existing-directory refusal",
           f"HTTP {code} {body[:200]}", refused)
    # lb is intentionally LEFT OPEN for the negative control.

    # ── Phase 3 (NEGATIVE CONTROL A): ingest -f with lb still open ──────────
    print("\n########## Phase 3 (neg control A): delete while lease #2 is open ##########")
    rc, out = dex_rc(PUB, "cvmfs_server", "ingest", "-f", P, REPO)
    low = out.lower()
    busy = rc != 0 and ("path_busy" in low or "impossible to start a transaction" in low
                        or "in use" in low or "busy" in low)
    record("Phase 3: `ingest -f` blocked while the conflicting lease is open",
           "fails: the still-open lease #2 stops the transaction from starting",
           f"rc={rc}  " + " ".join(out.split())[:200], busy)

    # ── Phase 4: correct order — release lease, delete, re-read root ────────
    print("\n########## Phase 4: release lease #2, then delete the subtree ##########")
    code, body = gw.release(lb)
    print(f"  release lease #2: HTTP {code} {body[:120]}")
    time.sleep(1)
    rc, out = dex_rc(PUB, "cvmfs_server", "ingest", "-f", P, REPO)
    deleted = rc == 0
    record("Phase 4: `ingest -f` deletes the subtree once the lease is gone",
           "rc=0, subtree removed, root advances",
           f"rc={rc}  " + " ".join(out.split())[:160], deleted)
    if not deleted:
        die("delete failed even after releasing the lease — check the mountless "
            "fast-delete fix (MEASUREMENTS §25, cvmfs fork 5d3ccdda3) is deployed")
    time.sleep(3)
    r2 = published_root()
    print(f"  published root after delete (R2): {r2}   (moved from R1: {r2 != r1})")
    print(f"  read-back A after delete: {readback(P)!r}   (expect empty/absent)")

    # ── Phase 5: re-graft B after the delete, PROBING old_root enforcement ──
    # The handover feared the retry reuses a stale old_root_hash (the delete
    # advanced the root). Send the STALE pre-delete root r1 on purpose: if the
    # graft still lands, old_root_hash is NOT enforced and the orchestrator's
    # "re-read the root" step is unnecessary; if it is rejected, re-graft with
    # the current root r2. Either way B ends up published. This records a
    # FINDING (always ok in the ledger) rather than asserting an outcome.
    print("\n########## Phase 5: re-graft B (probe old_root_hash enforcement) ##########")
    code, body, lc = gw.acquire(f"{REPO}/{P}")
    if not lc:
        die(f"acquire for the retry failed: {code} {body[:200]}")
    code, body = gw.graft(lc, r1, cat_b + "C")   # r1 deliberately stale (real root is r2)
    stale_ok = gw_ok(body)
    record("Phase 5: re-graft B with a STALE old_root_hash (finding)",
           "FINDING: accepted -> old_root_hash not enforced, no re-read needed; "
           "rejected -> the orchestrator must re-read the root before retrying",
           f"stale-root graft -> HTTP {code} {body[:140]}  accepted={stale_ok}", True)
    if not stale_ok:
        print("  stale root rejected — re-grafting with the current root R2")
        code, body, lc = gw.acquire(f"{REPO}/{P}")
        code, body = gw.graft(lc, r2, cat_b + "C")
        print(f"  current-root graft -> HTTP {code} {body[:140]}")
    landed = gw_ok(body)
    record("Phase 5: B lands after release -> delete -> re-acquire -> re-graft",
           "status:ok — the remediation sequence completes",
           f"HTTP {code} {body[:140]}", landed)

    # ── Phase 6: the client reads B, not A ──────────────────────────────────
    print("\n########## Phase 6: client sees B's content ##########")
    if landed:
        time.sleep(3)
        mark = readback(P)
        record("Phase 6: client reads B's content, not A's",
               f"marker == PUBLISH-B-{ts}", repr(mark), mark == f"PUBLISH-B-{ts}")

    # ── verdict ─────────────────────────────────────────────────────────────
    print("\n================= VERDICT =================")
    for phase, exp, obs, ok in LEDGER:
        print(f"  [{'OK  ' if ok else 'FAIL'}] {phase}")
    all_ok = all(ok for *_, ok in LEDGER)
    print("\nProven: release -> delete -> re-acquire -> retry lands B. The lease\n"
          "release is NECESSARY (an open lease blocks the delete, Phase 3); the\n"
          "root re-read is NOT (a stale old_root_hash still grafts, Phase 5)."
          if all_ok else
          "\nNOT fully proven: at least one phase diverged. Read the ledger above;\n"
          "a divergence is itself a finding — record it, do not paper over it.")
    print(f"\nLeft in place for inspection: stages {stage_a}, {stage_b}; path {P}\n"
          "Reset with `make clean` / redeploy before the next comparison run.")
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
