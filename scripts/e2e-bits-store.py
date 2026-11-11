#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 CERN
# SPDX-License-Identifier: Apache-2.0
"""e2e-bits-store.py — the testbed's bits-store, end to end (make test-bits-store).

Signs short-lived store tokens with the key init.sh made (config/bits-store/
token.key, its public half in config.json), uploads a file through bits-store,
downloads it and checks every refusal. Needs python3 and cryptography.
"""
import argparse, base64, hashlib, json, os, secrets, sys, time
import urllib.error, urllib.request

try:
    from cryptography.hazmat.primitives.serialization import load_pem_private_key
except ImportError:
    sys.exit("needs the Python module cryptography (pip install --user cryptography)")

KEY = CFG = None


def b64(b): return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def token(grp, caps, life=600, now=None, sub="alice"):
    now = int(time.time()) if now is None else now
    kid = next(iter(CFG["keys"]))
    hdr = {"alg": "EdDSA", "typ": "bits-store+jwt", "kid": kid}
    pl = {"iss": CFG["issuer"], "aud": CFG["audience"], "sub": sub, "grp": grp, "iat": now,
          "exp": now + life, "jti": secrets.token_urlsafe(12),
          "cap": [{"m": m, "p": p} for m, p in caps]}
    si = b64(json.dumps(hdr, separators=(",", ":")).encode()) + "." + \
        b64(json.dumps(pl, separators=(",", ":")).encode())
    return si + "." + b64(KEY.sign(si.encode()))


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a): return None


OPEN = urllib.request.build_opener(NoRedirect).open


def call(method, url, tok=None, body=None, headers=None):
    """(status, headers, body bytes); redirects are answers, not followed."""
    h = dict(headers or {})
    if tok:
        h["Authorization"] = "Bearer " + tok
    if isinstance(body, dict):
        body, h["Content-Type"] = json.dumps(body).encode(), "application/json"
    req = urllib.request.Request(url, data=body, method=method, headers=h)
    try:
        with OPEN(req, timeout=60) as r:
            return r.status, r.headers, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.headers, e.read()
    except urllib.error.URLError as e:          # not reachable: a status of 0
        return 0, {}, str(e.reason).encode()


def roundtrip(a):
    base, g = a.url.rstrip("/"), a.group
    ok = token(g, [("GET", "/store/%s/**" % g), ("PUT", "/store/%s/**" % g)])
    name = "/store/%s/x86_64-test/rt/%s" % (g, secrets.token_hex(8))
    data = os.urandom(200000) + b"bits-store round trip\n"
    meta = {"size": len(data), "md5": base64.b64encode(hashlib.md5(data).digest()).decode(),
            "sha256": hashlib.sha256(data).hexdigest()}
    fails = []

    def check(what, got, want):
        print("%-48s %s" % (what, "ok" if got == want else "FAIL: got %r, want %r" % (got, want)))
        if got != want:
            fails.append(what)

    check("health", call("GET", base + "/health")[0], 200)
    check("no token: 401", call("GET", base + name)[0], 401)
    s, _, b = call("POST", base + name + "?uploads", ok, meta)
    check("start upload: 201", s, 201)
    if s == 201:
        up = json.loads(b)
        s, _, _ = call(up["method"], up["url"], body=data, headers=up["headers"])
        check("PUT to the staging URL: 200", s, 200)
        check("complete: 201", call("POST", "%s%s?complete=%s" % (base, name, up["id"]), ok)[0], 201)
    s, h, _ = call("GET", base + name, ok)
    check("GET: 302 to the volume", s, 302)
    if s == 302:
        s2, _, got = call("GET", h["Location"])       # no Authorization to the volume
        check("download: same bytes", (s2, hashlib.sha256(got).hexdigest()),
              (200, meta["sha256"]))
    check("same name again: 409", call("POST", base + name + "?uploads", ok, meta)[0], 409)
    other = token("lhcb", [("GET", "/store/lhcb/**")])
    check("another group's token: 403", call("GET", base + name, other)[0], 403)
    old = token(g, [("GET", "/store/%s/**" % g)], life=600, now=int(time.time()) - 3600)
    check("expired token: 401", call("GET", base + name, old)[0], 401)
    check("tampered token: 401", call("GET", base + name, ok[:-4] + "AAAA")[0], 401)
    # wrong bytes for the signed MD5: the volume refuses them, complete finds nothing
    name2 = name + "-bad"
    s, _, b = call("POST", base + name2 + "?uploads", ok, meta)
    if s == 201:
        up = json.loads(b)
        s, _, _ = call(up["method"], up["url"], body=b"x" + data[1:], headers=up["headers"])
        check("wrong bytes refused by the volume", s != 200, True)
        check("complete after refused bytes: 409",
              call("POST", "%s%s?complete=%s" % (base, name2, up["id"]), ok)[0], 409)
    print("\n%s; objects left in bits-store's bucket under TARS/%s/x86_64-test/rt/"
          % ("ALL PASS" if not fails else "%d FAILED" % len(fails), g))
    return 1 if fails else 0


def main():
    global KEY, CFG
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dir", required=True, help="config/bits-store under TESTBED_ROOT")
    ap.add_argument("--url", default="http://127.0.0.1:8099")
    ap.add_argument("--group", default="testbed")
    a = ap.parse_args()
    with open(os.path.join(a.dir, "config.json")) as fh:
        CFG = json.load(fh)
    with open(os.path.join(a.dir, "token.key"), "rb") as fh:
        KEY = load_pem_private_key(fh.read(), None)
    return roundtrip(a)


if __name__ == "__main__":
    sys.exit(main())
