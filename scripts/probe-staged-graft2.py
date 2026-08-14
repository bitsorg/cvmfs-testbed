#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 CERN
# SPDX-License-Identifier: Apache-2.0
"""probe-staged-graft2.py — ADR-0011 Phase 0b, part 2: graft by hand.

Phase 1 (probe-staged-graft.sh) established that `cvmfs_swissknife ingest`
writes a subtree catalog for the lease path into the staging prefix, and that
the manifest names only the ROOT catalog (MEASUREMENTS §21). This part answers
the remaining question: does the gateway accept that producer-built subtree
catalog as a graft, and can a client read the result?

It does by hand exactly what prepub's staged path does in code (cvmfs-bits
f2eb51e), so a failure here is a design problem and not an implementation bug:

  1. server-side copy the staged objects into the repository prefix
  2. acquire a lease on the lease path
  3. POST /api/v1/leases/<token>/graft with the SUBTREE catalog hash
  4. read the file back through the client

MUTATES THE REPOSITORY. It commits a real revision. Everything it publishes
lives under a fresh timestamped path, so it adds rather than replaces, but the
repository root does move.

Auth is `<key_id> <base64(hex(HMAC-SHA1(input, secret)))>` — over the request
body for acquire, over the token for graft (cvmfs-bits internal/lease/auth.go).

Usage:
  probe-staged-graft2.py --stage stage-probe-<ts> --catalog <hash> \\
      --lease-path probe/staged/<ts> [--dry-run]
"""
import argparse, base64, hashlib, hmac, json, subprocess, sys, time, urllib.request

BUCKET = "cvmfs"
REPO = "test.cvmfs.io"


def dex(container, *cmd):
    # errors="replace": .cvmfspublished carries a binary signature after the
    # text fields, and strict decoding dies on it before the C line is read.
    return subprocess.run(["docker", "exec", container, *cmd],
                          capture_output=True, text=True,
                          errors="replace").stdout


def s3_client():
    import boto3
    conf = dex("cvmfs-native-publisher", "cat", f"/etc/cvmfs/s3/{REPO}.s3.conf")
    kv = {}
    for line in conf.splitlines():
        if "=" in line and not line.startswith("#"):
            k, _, v = line.partition("=")
            kv[k.strip()] = v.strip().strip("'\"")
    # MinIO is reachable from the host on the published port; inside the compose
    # network it is minio:9000. Try the published port first.
    return boto3.client(
        "s3", endpoint_url="http://localhost:9000",
        aws_access_key_id=kv["CVMFS_S3_ACCESS_KEY"],
        aws_secret_access_key=kv["CVMFS_S3_SECRET_KEY"],
        region_name=kv.get("CVMFS_S3_REGION", "us-east-1"))


def promote(s3, stage, dry):
    """Server-side copy stage/data/** -> <repo>/data/**, skipping what exists.

    This is cas.PromoteFrom by hand: same keys, same server-side CopyObject,
    same skip-if-present. Content addressing is what makes it safe to repeat.
    """
    src_prefix = f"{stage}/data/"
    copied = skipped = 0
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=BUCKET, Prefix=src_prefix):
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


class Gateway:
    def __init__(self, url, key_id, secret):
        self.url, self.key_id, self.secret = url, key_id, secret

    def _sig(self, data: bytes) -> str:
        mac = hmac.new(self.secret.encode(), data, hashlib.sha1).hexdigest()
        return base64.b64encode(mac.encode()).decode()

    def _post(self, path, body: bytes, sig_input: bytes):
        req = urllib.request.Request(self.url + path, data=body, method="POST")
        req.add_header("Content-Type", "application/json")
        req.add_header("Authorization", f"{self.key_id} {self._sig(sig_input)}")
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                return r.status, r.read().decode()
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode()

    def acquire(self, path):
        body = json.dumps({"path": path, "api_version": "3"}).encode()
        return self._post("/api/v1/leases", body, body)

    def graft(self, token, old_root, new_root, tag=""):
        body = json.dumps({
            "old_root_hash": old_root, "new_root_hash": new_root,
            "tag_name": tag, "tag_description": "",
        }).encode()
        # HMAC over the TOKEN for token-bearing endpoints.
        return self._post(f"/api/v1/leases/{token}/graft", body, token.encode())


def published_root():
    out = dex("cvmfs-native-publisher", "sh", "-c",
              f"curl -sf http://minio:9000/cvmfs/{REPO}/.cvmfspublished | tr -d '\\000'")
    for line in out.splitlines():
        if line.startswith("C"):
            return line[1:].strip()
    return ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stage", required=True)
    ap.add_argument("--catalog", required=True, help="SUBTREE catalog hash (no suffix)")
    ap.add_argument("--lease-path", required=True)
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    print("=== before ===")
    before = published_root()
    print(f"published root: {before}")

    print("\n=== 1. promote (server-side copy) ===")
    s3 = s3_client()
    t0 = time.time()
    copied, skipped = promote(s3, a.stage, a.dry_run)
    print(f"copied={copied} skipped={skipped} in {time.time()-t0:.3f}s"
          + ("  [DRY RUN — nothing written]" if a.dry_run else ""))

    # Confirm the catalog we intend to graft is actually in the CAS now.
    key = f"{REPO}/data/{a.catalog[:2]}/{a.catalog[2:]}C"
    try:
        s3.head_object(Bucket=BUCKET, Key=key)
        print(f"catalog present in CAS: {key}")
    except Exception as e:
        print(f"FATAL: catalog NOT in CAS after promotion: {key} ({e})")
        return 1

    if a.dry_run:
        print("\n=== stopping before the graft (--dry-run) ===")
        return 0

    print("\n=== 2. acquire lease ===")
    gwkey = dex("cvmfs-gateway", "cat", f"/etc/cvmfs/keys/{REPO}.gw").split()
    gw = Gateway("http://localhost:4929", gwkey[1], gwkey[2])
    path = f"{REPO}/{a.lease_path.strip('/')}"
    code, body = gw.acquire(path)
    print(f"POST /api/v1/leases {path} -> {code} {body[:300]}")
    try:
        token = json.loads(body)["session_token"]
    except Exception:
        print("FATAL: no session token — cannot graft")
        return 1

    print("\n=== 3. graft the PRODUCER's subtree catalog ===")
    print(f"old_root={before}\nnew_root={a.catalog}C")
    code, body = gw.graft(token, before, a.catalog + "C")
    print(f"POST .../graft -> {code} {body[:600]}")

    print("\n=== after ===")
    time.sleep(3)
    after = published_root()
    print(f"published root: {after}  (moved: {after != before})")

    print("\n=== 4. read it back through the client ===")
    dex("cvmfs-client", "cvmfs_talk", "-i", REPO, "remount", "sync")
    time.sleep(2)
    out = dex("cvmfs-client", "sh", "-c",
              f"ls -la /cvmfs/{REPO}/{a.lease_path}/ 2>&1 | head -10; "
              f"cat /cvmfs/{REPO}/{a.lease_path}/marker.txt 2>&1 | head -2")
    print(out or "(no output)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
