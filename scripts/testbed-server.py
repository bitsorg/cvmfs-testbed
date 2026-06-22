#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 CERN
# SPDX-License-Identifier: Apache-2.0

"""
testbed-server.py — Backend server for the CVMFS Testbed Console.

Usage:
    python3 testbed-server.py [--port 8888] [--bind 0.0.0.0]
    # Or via the testbed.sh wrapper (preferred):
    ./testbed server [port]

What it does:
  1. Serves testbed-console.html and any static assets from this directory
     over HTTPS (self-signed certificate generated on first run).
  2. Prints a one-time secret token to stdout; all /api/* requests must carry
     it in the X-Testbed-Token header (or ?token= query-param on first load).
  3. Proxies HTTP requests to all internal testbed services so the console
     works from a remote host (solves the "can't reach localhost:3000" problem).
  4. Runs ./testbed.sh commands on request and streams their output back to
     the browser via Server-Sent Events (SSE) — one line per event.

API endpoints:
  GET  /                              → testbed-console.html (no auth)
  GET  /api/health                    → {"ok":true, "services":{...}}
  GET  /api/proxy/<service>/<path>    → reverse-proxy to internal service
  POST /api/proxy/<service>/<path>    → forward POST (e.g. prepub job submit)
  POST /api/run                       → run testbed.sh command; SSE response
       body: {"cmd":"test","flags":["--mqtt"],"args":["--method","bits"]}
       SSE events: data:<line>  event:done data:{"exit_code":N}

Authentication:
  Every /api/* request must supply the token printed at startup, either as:
    - Header:      X-Testbed-Token: <token>
    - Query param: ?token=<token>  (convenient for the first page load URL)
    - Cookie:      testbed-session=<token>  (set automatically on first page load)
  When the browser opens /?token=<token>, the server validates the token and sets
  an HttpOnly session cookie.  Subsequent API calls and page refreshes are then
  authenticated automatically via that cookie — no JS involvement required.
  Use --no-auth to disable token checking (trusted networks only).

TLS:
  A self-signed certificate is generated at first run (stored next to this
  script as testbed-console-cert.pem / testbed-console-key.pem).
  Supply --cert / --key to use your own certificate.
  Use --no-tls for plain HTTP (not recommended over untrusted networks).

Proxy service names → default URLs (override with CLI flags):
  prepub          http://localhost:8080
  gateway         http://localhost:4929
  stratum0        http://localhost:8090
  s1a             http://localhost:9101
  s1b             http://localhost:9102
  victoriametrics http://localhost:8428  (metrics, usually internal-only)
  victoriametrics http://localhost:8428  (usually internal-only)

No external pip dependencies — pure Python 3.8+ stdlib.
"""

import argparse
import hashlib
import json
import os
import re
import secrets
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

# ── Globals ───────────────────────────────────────────────────────────────────
SCRIPT_DIR  = Path(__file__).parent.resolve()
TESTBED_DIR = SCRIPT_DIR.parent   # root of cvmfs-testbed checkout
ANSI_RE = re.compile(r'\x1b\[[0-9;]*[mKHABCDGJ]')

# Commands allowed via /api/run (security whitelist — no shell metacharacters).
ALLOWED_COMMANDS = frozenset({
    'status', 'info', 'logs', 'test', 'suite', 'stresstest', 'unittest',
    'pulltest', 'pullstatus',
    'start', 'stop', 'restart', 'bootstrap', 'snapshot', 'restore',
    'catdump', 'catdiff', 'verify', 'clean', 'reset', 'help',
    'upload-filelist',
})

# Regex for safe CLI argument tokens (no shell metacharacters allowed).
SAFE_ARG_RE = re.compile(r'^[\w\-\./=:@,]+$')

# Headers stripped from ALL proxied responses.
# x-frame-options / content-security-policy: allow the Grafana iframe to embed.
# content-encoding: urllib may decompress the body automatically; forwarding the
#   original Content-Encoding with the now-decompressed body causes the browser to
#   try to decompress again and produce garbled output.
# content-length: we always set this to the ACTUAL bytes we have after reading
#   (in case the upstream value reflected a compressed payload).
# transfer-encoding: we write a plain response, not chunked.
PROXY_SKIP_HEADERS = frozenset({
    'transfer-encoding', 'connection', 'content-encoding', 'keep-alive',
    'content-length',
    'x-frame-options', 'content-security-policy',
})

# ── TLS certificate helpers ───────────────────────────────────────────────────
def generate_cert(cert_path: Path, key_path: Path):
    """Generate a self-signed RSA certificate via openssl subprocess."""
    cert_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        subprocess.check_call(
            [
                'openssl', 'req', '-x509', '-newkey', 'rsa:2048',
                '-keyout', str(key_path),
                '-out',    str(cert_path),
                '-days',   '3650',
                '-nodes',
                '-subj',   '/CN=cvmfs-testbed',
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except FileNotFoundError:
        print('[ERROR] openssl not found — cannot generate TLS certificate.', file=sys.stderr)
        print('        Install openssl, supply --cert/--key, or use --no-tls.', file=sys.stderr)
        sys.exit(1)
    except subprocess.CalledProcessError as ex:
        print(f'[ERROR] openssl certificate generation failed: {ex}', file=sys.stderr)
        sys.exit(1)


def cert_fingerprint(cert_path: Path) -> str:
    """Return the SHA-256 fingerprint of a PEM certificate (colon-hex form)."""
    try:
        result = subprocess.run(
            ['openssl', 'x509', '-fingerprint', '-sha256', '-noout', '-in', str(cert_path)],
            capture_output=True, text=True, check=True,
        )
        line = result.stdout.strip()
        return line.split('=', 1)[-1].strip()
    except Exception:
        return '(unavailable)'


# ── Argument parser ───────────────────────────────────────────────────────────
def parse_args():
    p = argparse.ArgumentParser(description='CVMFS Testbed Console backend server')
    p.add_argument('--port',          type=int,   default=8888,
                   help='TCP port to listen on (default: 8888)')
    p.add_argument('--bind',          default='0.0.0.0',
                   help='Bind address (default: 0.0.0.0 = all interfaces)')
    p.add_argument('--testbed-root',
                   default=os.environ.get('TESTBED_ROOT', str(Path.home() / 'cvmfs-testbed')),
                   help='TESTBED_ROOT path (default: ~/cvmfs-testbed)')
    p.add_argument('--script',        default=str(SCRIPT_DIR / 'testbed.sh'),
                   help='Path to testbed.sh (default: ./testbed.sh)')
    # Service endpoints
    p.add_argument('--prepub',        default='http://localhost:8080')
    p.add_argument('--gateway',       default='http://localhost:4929')
    p.add_argument('--stratum0',      default='http://localhost:8090')
    p.add_argument('--s1a',           default='http://localhost:9101')
    p.add_argument('--s1b',           default='http://localhost:9102')
    p.add_argument('--victoriametrics', default='http://localhost:8428')
    # Overlay flags
    p.add_argument('--bits',  action='store_true', help='--bits overlay active')
    p.add_argument('--mqtt',  action='store_true', help='--mqtt overlay active')
    p.add_argument('--wss',   action='store_true', help='--wss (embedded broker) overlay active')
    # CAS stats
    p.add_argument('--cas-container', default='cvmfs-prepub',
                   help='Docker container that hosts the prepub CAS (default: cvmfs-prepub)')
    p.add_argument('--cas-data-path', default='/data/cas/data',
                   help='Path to the CAS data directory INSIDE the container (default: /data/cas/data)')
    # TLS
    p.add_argument('--no-tls', action='store_true',
                   help='Serve plain HTTP instead of HTTPS')
    p.add_argument('--cert', default=None,
                   help='Path to TLS certificate PEM file (auto-generated if absent)')
    p.add_argument('--key',  default=None,
                   help='Path to TLS private key PEM file (auto-generated if absent)')
    # Auth
    p.add_argument('--no-auth', action='store_true',
                   help='Disable token authentication (use only on trusted networks)')
    p.add_argument('--token', default=None,
                   help='Use a specific auth token instead of a random one')
    p.add_argument('--prepub-token', default=os.environ.get('PREPUB_API_TOKEN', ''),
                   help='Prepub API token; included in startup URL and /api/health '
                        '(default: $PREPUB_API_TOKEN env var)')
    # Misc
    p.add_argument('--verbose', action='store_true',
                   help='Print every HTTP request to stdout')
    return p.parse_args()


# ── HTTP handler ──────────────────────────────────────────────────────────────
class Handler(BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):
        if getattr(self.server, 'verbose', False):
            print(f'[{self.address_string()}] {fmt % args}', flush=True)

    # ── Auth check ────────────────────────────────────────────────────────────
    def _check_auth(self) -> bool:
        """Return True if the request carries the correct server token."""
        token = getattr(self.server, 'auth_token', None)
        if not token:
            return True  # auth disabled

        # 1. Custom header (used by the JS console for all API calls)
        if self.headers.get('X-Testbed-Token', '') == token:
            return True

        # 2. Standard Bearer token (alternative)
        auth = self.headers.get('Authorization', '')
        if auth == f'Bearer {token}':
            return True

        # 3. ?token= query param (convenient for the one-click startup URL)
        qs = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        if qs.get('token', [None])[0] == token:
            return True

        # 4. Session cookie — set automatically when the page is loaded with ?token=
        cookie_hdr = self.headers.get('Cookie', '')
        for part in cookie_hdr.split(';'):
            name, _, val = part.strip().partition('=')
            if name.strip() == 'testbed-session' and val.strip() == token:
                return True

        self._json({'error': 'Unauthorized — open the startup URL with ?token= to authenticate, '
                             'or supply X-Testbed-Token header'}, 401)
        return False

    # ── Session cookie ────────────────────────────────────────────────────────
    def _set_session_cookie(self, token: str):
        """Emit a Set-Cookie header that persists the auth token for this browser."""
        secure = '; Secure' if self.server.use_tls else ''
        self.send_header(
            'Set-Cookie',
            f'testbed-session={token}; HttpOnly{secure}; SameSite=Strict; Path=/',
        )

    # ── CORS / common response helpers ────────────────────────────────────────
    def _cors(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS')
        self.send_header('Access-Control-Allow-Headers',
                         'Authorization, Content-Type, Accept, X-Testbed-Token')

    def _json(self, obj, status=200):
        body = json.dumps(obj, default=str).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self._cors()
        self.end_headers()
        self.wfile.write(body)

    def _sse_headers(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Cache-Control', 'no-cache')
        self.send_header('Connection', 'keep-alive')
        self.send_header('X-Accel-Buffering', 'no')
        self._cors()
        self.end_headers()

    def _sse(self, data, event=None):
        """Write one SSE frame. Returns False if connection was closed."""
        msg = ''
        if event:
            msg += f'event: {event}\n'
        for line in str(data).split('\n'):
            msg += f'data: {line}\n'
        msg += '\n'
        try:
            self.wfile.write(msg.encode('utf-8', errors='replace'))
            self.wfile.flush()
            return True
        except (BrokenPipeError, ConnectionResetError, OSError):
            return False

    # ── OPTIONS (preflight) ───────────────────────────────────────────────────
    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.end_headers()

    # ── GET routing ───────────────────────────────────────────────────────────
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path

        # Static HTML page — served without auth so the user can load the page
        # and supply the token via the ?token= URL parameter.
        # If ?token= is present and valid, set a session cookie so all subsequent
        # API calls are authenticated automatically (even if JS fails to read the
        # URL param, or the URL is copy-pasted without the query string later).
        if path in ('/', '/testbed-console.html'):
            auth_token = getattr(self.server, 'auth_token', None)
            if auth_token:
                qs = urllib.parse.parse_qs(parsed.query)
                url_token = qs.get('token', [None])[0]
                if url_token == auth_token:
                    # Valid token in URL — serve HTML and set a session cookie so
                    # that all subsequent API requests are authenticated automatically
                    # via the cookie, even without the token in later URLs.
                    try:
                        data = (TESTBED_DIR / 'testbed-console.html').read_bytes()
                    except FileNotFoundError:
                        self.send_response(404)
                        self._cors()
                        self.end_headers()
                        return
                    self.send_response(200)
                    self.send_header('Content-Type', 'text/html; charset=utf-8')
                    self.send_header('Content-Length', str(len(data)))
                    self.send_header('Cache-Control', 'no-store, must-revalidate')
                    self._cors()
                    self._set_session_cookie(auth_token)
                    self.end_headers()
                    self.wfile.write(data)
                    return
            self._serve_static(TESTBED_DIR / 'testbed-console.html',
                               'text/html; charset=utf-8')
            return

        # All other /api/* routes require authentication
        if path.startswith('/api/'):
            if not self._check_auth():
                return

            if path == '/api/health':
                self._json({
                    'ok': True,
                    'server': 'testbed-console',
                    'testbed_root': str(self.server.testbed_root),
                    'services': self.server.services,
                    'flags': {'bits': self.server.use_bits, 'mqtt': self.server.use_mqtt},
                    'tls': self.server.use_tls,
                    'auth': bool(self.server.auth_token),
                    'prepub_token': self.server.prepub_token,
                })
                return

            if path == '/api/ingest-jobs':
                self._ingest_jobs()
                return

            if path == '/api/runs':
                self._runs()
                return

            if path == '/api/test-results':
                self._test_results(parsed.query)
                return

            if path == '/api/test-status':
                self._test_status()
                return

            if path == '/api/testbed-config':
                self._testbed_config()
                return

            if path == '/api/measurements':
                self._measurements()
                return

            if path == '/api/manifest':
                self._manifest()
                return

            if path == '/api/host-metrics':
                self._host_metrics()
                return

            if path == '/api/cas-stats':
                self._cas_stats()
                return

            if path == '/api/push-status':
                err = self.server._push_error
                self._json({'ok': err is None, 'error': err})
                return

            if path == '/api/services':
                self._json(self.server.services)
                return

            if path == '/api/filelist':
                self._filelist()
                return

            if path == '/api/scan-dir':
                self._scan_dir(parsed.query)
                return

            if path == '/api/list-dir':
                self._list_dir(parsed.query)
                return

            if path == '/api/probe':
                self._probe(parsed.query)
                return

            if path.startswith('/api/proxy/'):
                self._proxy(path[len('/api/proxy/'):], parsed.query, method='GET')
                return

            self.send_response(404)
            self._cors()
            self.end_headers()
            return

        # Static assets (JS, CSS, images, …)
        fpath = TESTBED_DIR / path.lstrip('/')
        if fpath.is_file() and fpath.is_relative_to(TESTBED_DIR):
            self._serve_static(fpath, _mime(fpath.suffix))
        else:
            self.send_response(404)
            self._cors()
            self.end_headers()

    # ── POST routing ──────────────────────────────────────────────────────────
    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path

        if not self._check_auth():
            return

        if path == '/api/run':
            self._run_command()
        elif path == '/api/test-run':
            self._test_run()
        elif path == '/api/exec-container':
            self._exec_container()
        elif path.startswith('/api/proxy/'):
            self._proxy(path[len('/api/proxy/'):], parsed.query, method='POST')
        else:
            self.send_response(404)
            self._cors()
            self.end_headers()

    # ── Static file serving ───────────────────────────────────────────────────
    def _serve_static(self, fpath, mime):
        try:
            data = Path(fpath).read_bytes()
        except FileNotFoundError:
            self.send_response(404)
            self._cors()
            self.end_headers()
            return
        self.send_response(200)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(data)))
        # Never let the browser reuse a stale console/asset — the file is read
        # fresh from disk on every request, so any edit must reach the browser
        # immediately (no heuristic caching).
        self.send_header('Cache-Control', 'no-store, must-revalidate')
        self._cors()
        self.end_headers()
        self.wfile.write(data)

    # ── Filelist ──────────────────────────────────────────────────────────────
    def _filelist(self):
        """
        GET /api/filelist
        Looks for filelist.txt in:
          1. TESTBED_ROOT/data/filelist.txt
          2. TESTBED_DIR/filelist.txt  (testbed root directory)
        Returns:
          {
            "exists": true|false,
            "path": "<abs path>",
            "files": [
              {"name": "foo.tar.gz", "path": "/abs/path/foo.tar.gz",
               "size_bytes": 123456, "size_human": "120 KB",
               "exists": true|false}
            ]
          }
        """
        candidates = [
            self.server.testbed_root / 'data' / 'filelist.txt',
            TESTBED_DIR / 'filelist.txt',
        ]
        filelist_path = None
        for c in candidates:
            if c.is_file():
                filelist_path = c
                break

        if filelist_path is None:
            self._json({'exists': False, 'path': None, 'files': []})
            return

        filelist_dir = filelist_path.parent
        files = []
        try:
            for raw in filelist_path.read_text(encoding='utf-8').splitlines():
                line = raw.strip()
                if not line or line.startswith('#'):
                    continue
                p = Path(line) if Path(line).is_absolute() else filelist_dir / line
                sz = 0
                ex = p.is_file()
                if ex:
                    try:
                        sz = p.stat().st_size
                    except OSError:
                        pass
                # human-readable size
                if sz < 1024:
                    sz_h = f'{sz} B'
                elif sz < 1024 * 1024:
                    sz_h = f'{sz // 1024} KB'
                elif sz < 1024 ** 3:
                    sz_h = f'{sz / (1024**2):.1f} MB'
                else:
                    sz_h = f'{sz / (1024**3):.2f} GB'
                files.append({
                    'name': p.name,
                    'path': str(p),
                    'size_bytes': sz,
                    'size_human': sz_h,
                    'exists': ex,
                })
        except Exception as exc:
            self._json({'exists': True, 'path': str(filelist_path),
                        'files': [], 'error': str(exc)})
            return

        self._json({
            'exists': True,
            'path': str(filelist_path),
            'files': files,
        })

    # ── Directory scanner ─────────────────────────────────────────────────────
    def _scan_dir(self, query_string: str):
        """
        GET /api/scan-dir?path=<dir>[&recursive=1]
        Scans the given directory for *.tar.gz files and returns metadata.
        Response: {path, exists, files: [{name, path, size_bytes, size_human}]}
        """
        params = urllib.parse.parse_qs(query_string or '')
        scan_path = (params.get('path', [''])[0]).strip()
        if not scan_path:
            self._json({'path': '', 'exists': False, 'files': [],
                        'error': 'path parameter required'})
            return
        recursive = params.get('recursive', ['1'])[0] not in ('0', 'false', 'no')

        d = Path(scan_path)
        if not d.exists():
            self._json({'path': scan_path, 'exists': False, 'files': []})
            return
        if not d.is_dir():
            self._json({'path': scan_path, 'exists': False,
                        'files': [], 'error': 'not a directory'})
            return

        files = []
        try:
            pattern = '**/*.tar.gz' if recursive else '*.tar.gz'
            for p in sorted(d.glob(pattern)):
                if not p.is_file():
                    continue
                try:
                    sz = p.stat().st_size
                except OSError:
                    sz = 0
                if sz < 1024:
                    sz_h = f'{sz} B'
                elif sz < 1024 * 1024:
                    sz_h = f'{sz // 1024} KB'
                elif sz < 1024 ** 3:
                    sz_h = f'{sz / (1024 ** 2):.1f} MB'
                else:
                    sz_h = f'{sz / (1024 ** 3):.2f} GB'
                files.append({
                    'name': p.name,
                    'path': str(p),
                    'size_bytes': sz,
                    'size_human': sz_h,
                })
        except Exception as exc:
            self._json({'path': scan_path, 'exists': True,
                        'files': [], 'error': str(exc)})
            return

        self._json({'path': scan_path, 'exists': True, 'files': files})

    # ── Directory browser ─────────────────────────────────────────────────────
    def _list_dir(self, query_string: str):
        """
        GET /api/list-dir?path=<dir>
        Lists subdirectories under the given path for the browser-side directory
        picker.  Hidden directories (name starting with '.') are excluded.
        Response: {path, parent, exists, dirs: [{name, path}]}
          parent is null when path is the filesystem root.
        """
        params = urllib.parse.parse_qs(query_string or '')
        raw_path = (params.get('path', ['/'])[0]).strip() or '/'
        try:
            d = Path(raw_path).resolve()
        except Exception:
            self._json({'path': raw_path, 'parent': None, 'exists': False, 'dirs': []})
            return

        if not d.exists() or not d.is_dir():
            # Return the parent so the caller can navigate up automatically.
            parent = str(d.parent) if d != d.parent else None
            self._json({'path': str(d), 'parent': parent, 'exists': False, 'dirs': []})
            return

        parent = str(d.parent) if d != d.parent else None
        dirs = []
        try:
            for child in sorted(d.iterdir()):
                try:
                    if child.is_dir() and not child.name.startswith('.'):
                        dirs.append({'name': child.name, 'path': str(child)})
                except PermissionError:
                    pass
        except PermissionError:
            pass

        self._json({
            'path':   str(d),
            'parent': parent,
            'exists': True,
            'dirs':   dirs[:300],   # cap to avoid huge responses on busy roots
        })

    # ── Ingest job list ───────────────────────────────────────────────────────
    def _measurements(self):
        """
        GET /api/measurements
        Reads TESTBED_ROOT/data/measurements.ndjson (bulk-upload comparison rows
        written by cmd_upload_filelist) and returns a JSON array newest-first.
        Returns [] when absent/empty — never an error.
        """
        log_path = self.server.testbed_root / 'data' / 'measurements.ndjson'
        rows = []
        try:
            with open(log_path, 'r', encoding='utf-8') as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        rows.append(json.loads(line))
                    except json.JSONDecodeError:
                        pass
        except FileNotFoundError:
            pass
        rows.sort(key=lambda r: r.get('ts', ''), reverse=True)
        self._json(rows)

    def _ingest_jobs(self):
        """
        GET /api/ingest-jobs
        Reads TESTBED_ROOT/data/ingest-jobs.ndjson (written by native-stress.sh
        and native-smoke.sh) and returns a JSON array sorted newest-first.
        Returns [] when the file is absent or empty — never an error.
        Result is cached by file mtime so repeated polls don't re-read the file.
        """
        log_path = self.server.testbed_root / 'data' / 'ingest-jobs.ndjson'
        with self.server._ndjson_lock:
            try:
                mtime = log_path.stat().st_mtime
                c = self.server._ingest_jobs_cache
                if c is not None and c['mtime'] == mtime:
                    self._json(c['data'])
                    return
            except FileNotFoundError:
                self._json([])
                return
            jobs = []
            try:
                with open(log_path, 'r', encoding='utf-8') as fh:
                    for line in fh:
                        line = line.strip()
                        if not line:
                            continue
                        try:
                            jobs.append(json.loads(line))
                        except json.JSONDecodeError:
                            pass
            except FileNotFoundError:
                pass
            jobs.sort(key=lambda j: j.get('created_at', ''), reverse=True)
            self.server._ingest_jobs_cache = {'mtime': mtime, 'data': jobs}
        self._json(jobs)

    # ── Run history ───────────────────────────────────────────────────────────
    def _runs(self):
        """
        GET /api/runs
        Reads TESTBED_ROOT/data/runs.ndjson and returns a JSON array sorted
        newest-first.  Returns [] when the file is absent or empty.
        Result is cached by file mtime so repeated polls don't re-read the file.
        """
        log_path = self.server.testbed_root / 'data' / 'runs.ndjson'
        with self.server._ndjson_lock:
            try:
                mtime = log_path.stat().st_mtime
                c = self.server._runs_cache
                if c is not None and c['mtime'] == mtime:
                    self._json(c['data'])
                    return
            except FileNotFoundError:
                self._json([])
                return
            runs = []
            try:
                with open(log_path, 'r', encoding='utf-8') as fh:
                    for line in fh:
                        line = line.strip()
                        if not line:
                            continue
                        try:
                            runs.append(json.loads(line))
                        except json.JSONDecodeError:
                            pass
            except FileNotFoundError:
                pass
            runs.sort(key=lambda r: r.get('start_time', ''), reverse=True)
            self.server._runs_cache = {'mtime': mtime, 'data': runs}
        self._json(runs)

    # ── Test-suite results ────────────────────────────────────────────────────
    # Catalog of selectable suite tests (must mirror _SUITE_TESTS in testbed.sh).
    _SUITE_TESTS = ('bits', 'ingest', 'pull-wss', 'chunking', 'content', 'stress')

    def _test_results(self, query_string: str):
        """
        GET /api/test-results?limit=N
        Reads TESTBED_ROOT/data/test-results.ndjson and returns a JSON array of
        the last N records, most recent (file-append order) first.
        Returns [] when the file is absent or empty.  limit defaults to 100.
        """
        params = urllib.parse.parse_qs(query_string or '')
        try:
            limit = int(params.get('limit', ['100'])[0])
        except (TypeError, ValueError):
            limit = 100
        limit = max(1, min(limit, 5000))

        log_path = self.server.testbed_root / 'data' / 'test-results.ndjson'
        records = []
        try:
            with open(log_path, 'r', encoding='utf-8') as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        records.append(json.loads(line))
                    except json.JSONDecodeError:
                        pass
        except FileNotFoundError:
            self._json([])
            return
        # NDJSON is appended chronologically; newest is at the end.  Return the
        # last `limit` records reversed so the newest is first.
        records = records[-limit:]
        records.reverse()
        self._json(records)

    def _testbed_config(self):
        """
        GET /api/testbed-config
        Returns the start-time config persisted by testbed.sh to
        data/testbed-config.json so the console can DISPLAY the active config.
        """
        default = {'method': None, 'wss': None, 'bits': None, 'started_at': None}
        cfg_path = self.server.testbed_root / 'data' / 'testbed-config.json'
        try:
            obj = json.loads(cfg_path.read_text(encoding='utf-8'))
            if not isinstance(obj, dict):
                obj = default
        except (FileNotFoundError, json.JSONDecodeError, OSError):
            obj = default
        self._json(obj)

    def _test_status(self):
        """
        GET /api/test-status
        Returns the contents of TESTBED_ROOT/data/test-suite-status.json, or an
        idle default if the file is absent or unparseable.
        """
        idle = {
            'suite_run_id': None, 'started_at': None, 'finished_at': None,
            'running': False, 'selected': [], 'current': None, 'results': [],
        }
        status_path = self.server.testbed_root / 'data' / 'test-suite-status.json'
        try:
            obj = json.loads(status_path.read_text(encoding='utf-8'))
            if not isinstance(obj, dict):
                obj = idle
        except (FileNotFoundError, json.JSONDecodeError, OSError):
            obj = idle
        self._json(obj)

    def _test_run(self):
        """
        POST /api/test-run
        Body JSON: {"tests": ["bits","chunking"]}  or  {"all": true}
        If a suite is already running (status file running=true) → 409.
        Otherwise launch  testbed.sh suite <names...>  in the BACKGROUND on the
        host (detached subprocess, cwd=testbed_root) and return immediately.
        Returns {"suite_run_id": <ts>, "started": true, "tests": [...]}.
        """
        cl = int(self.headers.get('Content-Length', 0) or 0)
        raw = self.rfile.read(cl) if cl else b'{}'
        try:
            req = json.loads(raw or b'{}')
        except Exception:
            self._json({'error': 'Invalid JSON body'}, 400)
            return

        # ── Refuse if a suite is already running ──────────────────────────────
        status_path = self.server.testbed_root / 'data' / 'test-suite-status.json'
        try:
            cur = json.loads(status_path.read_text(encoding='utf-8'))
            if isinstance(cur, dict) and cur.get('running'):
                self._json({'error': 'A suite is already running',
                            'suite_run_id': cur.get('suite_run_id')}, 409)
                return
        except (FileNotFoundError, json.JSONDecodeError, OSError):
            pass  # no/garbled status file → treat as idle

        # ── Resolve the requested test names ──────────────────────────────────
        if req.get('all'):
            tests = list(self._SUITE_TESTS)
        else:
            raw_tests = req.get('tests') or []
            if not isinstance(raw_tests, list):
                self._json({'error': 'tests must be a list'}, 400)
                return
            tests = [t for t in raw_tests
                     if isinstance(t, str) and t in self._SUITE_TESTS]
        if not tests:
            self._json({'error': 'no valid tests selected',
                        'known': list(self._SUITE_TESTS)}, 400)
            return

        # ── Launch the suite detached in the background ───────────────────────
        sid = str(int(time.time()))
        script = str(self.server.script_path)
        full_cmd = [script, 'suite'] + tests
        env = {
            **os.environ,
            'FORCE_COLOR': '0', 'NO_COLOR': '1', 'TERM': 'dumb',
            'TESTBED_ROOT': str(self.server.testbed_root),
        }
        try:
            # Detach: own session, stdio to DEVNULL so the HTTP response returns
            # immediately and the child outlives this request handler.
            subprocess.Popen(
                full_cmd,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                stdin=subprocess.DEVNULL,
                cwd=str(self.server.testbed_root),
                env=env,
                start_new_session=True,
            )
        except FileNotFoundError:
            self._json({'error': f'Script not found: {script}'}, 500)
            return
        except Exception as ex:
            self._json({'error': str(ex)}, 500)
            return

        self._json({'suite_run_id': sid, 'started': True, 'tests': tests})

    # ── CVMFS manifest ────────────────────────────────────────────────────────
    def _manifest(self):
        """
        GET /api/manifest?repo=<name>
        Reads TESTBED_ROOT/repos/<repo>/.cvmfspublished directly from the
        host filesystem for stratum0 only — bypasses CORS and network routing
        to the stratum0 container.

        Stratum1 manifests are NOT read here because stratum1 nodes are
        remote HTTP servers in real deployments and must not be assumed to
        share a filesystem with this host.  The console fetches stratum1
        manifests via the existing /api/proxy/<s1a|s1b>/... reverse proxy,
        which works with any remote stratum1 Apache endpoint.

        Returns JSON: {hash, revision, timestamp, iso_time, raw} or 404.
        """
        parsed = urllib.parse.urlparse(self.path)
        qs = urllib.parse.parse_qs(parsed.query)
        repo = (qs.get('repo', [None])[0] or '').strip()
        if not repo:
            self._json({'error': 'repo parameter required — pass ?repo=<repo_name>'}, 400)
            return

        pub_path = self.server.testbed_root / 'repos' / repo / '.cvmfspublished'
        try:
            raw = pub_path.read_text(encoding='utf-8', errors='replace')
        except FileNotFoundError:
            self._json({'error': f'.cvmfspublished not found for repo {repo}'}, 404)
            return
        except OSError as exc:
            self._json({'error': str(exc)}, 500)
            return

        def get(prefix):
            # CVMFS .cvmfspublished format: single-char key followed directly
            # by value with NO '=' separator (e.g. "Cabc123…", "S42", "T1700000000").
            # Lines after the '--' separator are part of the signature — stop there.
            for line in raw.splitlines():
                if line == '--':
                    break
                if len(line) > 0 and line[0] == prefix:
                    return line[1:].strip()
            return ''

        hash_val = get('C')
        revision = get('S')
        timestamp = get('T')
        iso_time = ''
        if timestamp:
            try:
                import datetime
                iso_time = datetime.datetime.fromtimestamp(int(timestamp), datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
            except (ValueError, OSError):
                pass

        self._json({
            'hash':      hash_val,
            'revision':  revision,
            'timestamp': timestamp,
            'iso_time':  iso_time,
            'raw':       raw,
        })

    # ── Container exec ────────────────────────────────────────────────────────
    def _exec_container(self):
        """
        POST /api/exec-container
        Body JSON: {container: str, cmd: str, timeout_s?: int}
        Runs: docker exec <container> bash -c <cmd>
        Returns: {stdout, stderr, exit_code, container, cmd}
        """
        try:
            length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(length)
            req = json.loads(body)
        except Exception:
            self._json({'error': 'invalid JSON body'}, 400)
            return

        container = str(req.get('container', '')).strip()
        cmd = str(req.get('cmd', '')).strip()
        timeout_s = int(req.get('timeout_s', 30))

        if not container:
            self._json({'error': 'container is required'}, 400)
            return
        if not cmd:
            self._json({'error': 'cmd is required'}, 400)
            return
        # Safety: cap timeout
        timeout_s = max(1, min(timeout_s, 120))

        try:
            proc = subprocess.run(
                ['docker', 'exec', container, 'bash', '-c', cmd],
                capture_output=True, text=True, timeout=timeout_s
            )
            self._json({
                'container': container,
                'cmd': cmd,
                'stdout': proc.stdout,
                'stderr': proc.stderr,
                'exit_code': proc.returncode,
            })
        except subprocess.TimeoutExpired:
            self._json({'error': f'command timed out after {timeout_s}s', 'exit_code': -1}, 200)
        except FileNotFoundError:
            self._json({'error': 'docker not found — is Docker installed?', 'exit_code': -1}, 200)
        except Exception as exc:
            self._json({'error': str(exc), 'exit_code': -1}, 200)

    # ── CAS stats ─────────────────────────────────────────────────────────────
    _CAS_CACHE_TTL = 20   # seconds between actual docker-exec calls

    def _cas_stats(self):
        """
        GET /api/cas-stats
        Counts CAS objects and sums their sizes by running a single awk pipeline
        inside the prepub Docker container via docker exec.
        Results are cached for _CAS_CACHE_TTL seconds.

        Returns JSON: {count, bytes, bytes_gb, cached, ts, error?}
        """
        now = time.time()
        with self.server._cas_lock:
            if self.server._cas_cache is not None:
                age = now - self.server._cas_cache['ts']
                if age < self._CAS_CACHE_TTL:
                    self._json({**self.server._cas_cache, 'cached': True})
                    return

        container = self.server.cas_container
        data_path = self.server.cas_data_path

        count, total_bytes, err = 0, 0, None
        try:
            # Single docker exec: count files and sum sizes atomically via awk.
            # This avoids the race between two separate exec calls and halves
            # the process-fork overhead on a busy host.
            cp = subprocess.run(
                ['docker', 'exec', container, 'bash', '-c',
                 f'find {data_path} -type f -printf "%s\\n" 2>/dev/null'
                 r" | awk 'BEGIN{c=0;s=0}{c++;s+=$1}END{print c,s}'"],
                capture_output=True, text=True, timeout=45,
            )
            if cp.returncode == 0:
                parts = cp.stdout.strip().split()
                if len(parts) == 2:
                    count       = int(parts[0])
                    total_bytes = int(parts[1])

        except subprocess.TimeoutExpired:
            err = 'docker exec timed out (CAS may be very large)'
        except FileNotFoundError:
            err = 'docker not found — is Docker installed and in PATH?'
        except Exception as exc:
            err = str(exc)

        result = {
            'count':    count,
            'bytes':    total_bytes,
            'bytes_gb': round(total_bytes / 1e9, 3),
            'cached':   False,
            'ts':       int(now),
            'container': container,
            'data_path': data_path,
        }
        if err:
            result['error'] = err

        with self.server._cas_lock:
            self.server._cas_cache = result

        self._json(result)

    # ── Host metrics ──────────────────────────────────────────────────────────
    @staticmethod
    def _read_net_counters():
        """Return (rx_bytes, tx_bytes) summed across all non-loopback interfaces."""
        rx = tx = 0
        try:
            for line in Path('/proc/net/dev').read_text().splitlines()[2:]:
                parts = line.split()
                if not parts:
                    continue
                iface = parts[0].rstrip(':')
                if iface == 'lo':
                    continue
                rx += int(parts[1])   # receive bytes
                tx += int(parts[9])   # transmit bytes
        except Exception:
            pass
        return rx, tx

    @staticmethod
    def _read_disk_counters():
        """Return (read_bytes, write_bytes) summed across all whole block devices."""
        rb = wb = 0
        try:
            for line in Path('/proc/diskstats').read_text().splitlines():
                parts = line.split()
                if len(parts) < 10:
                    continue
                dev = parts[2]
                # Skip virtual/loop/ram devices and partition entries.
                # Partitions of sd*/hd*/vd*/xvd* end in a digit; NVMe partitions
                # look like nvme0n1p1.  Whole devices: sda, nvme0n1, vda, …
                if re.match(r'^(loop|ram)\d*$', dev):
                    continue
                if re.match(r'^(sd|hd|vd|xvd)[a-z]+\d+$', dev):
                    continue   # sda1, sdb2, …
                if re.match(r'^nvme\d+n\d+p\d+$', dev):
                    continue   # nvme0n1p1, …
                rb += int(parts[5]) * 512   # sectors read  → bytes
                wb += int(parts[9]) * 512   # sectors written → bytes
        except Exception:
            pass
        return rb, wb

    def _host_metrics(self):
        """
        GET /api/host-metrics
        Reads live host metrics from /proc and /sys.  Computes network and disk
        I/O rates (KB/s) by differencing successive calls.
        Historical trends are available via VictoriaMetrics (node_* metrics from
        node-exporter scraped by vmagent).
        """
        now = time.time()
        result: dict = {}

        # ── CPU load (/proc/loadavg) ──────────────────────────────────────
        try:
            parts = Path('/proc/loadavg').read_text().split()
            result['cpu_load'] = {
                'load1':  float(parts[0]),
                'load5':  float(parts[1]),
                'load15': float(parts[2]),
            }
        except Exception:
            result['cpu_load'] = None

        # ── Memory (/proc/meminfo, values in kB) ─────────────────────────
        try:
            meminfo: dict = {}
            for line in Path('/proc/meminfo').read_text().splitlines():
                if ':' in line:
                    k, v = line.split(':', 1)
                    meminfo[k.strip()] = int(v.split()[0])
            total     = meminfo.get('MemTotal', 0)
            free      = meminfo.get('MemFree', 0)
            available = meminfo.get('MemAvailable', 0)
            buffers   = meminfo.get('Buffers', 0)
            cached    = meminfo.get('Cached', 0)
            used = total - free - buffers - cached
            result['memory'] = {
                'total_mb':     total     // 1024,
                'used_mb':      max(used, 0) // 1024,
                'free_mb':      free      // 1024,
                'available_mb': available // 1024,
                'percent_used': round(max(used, 0) / total * 100, 1) if total else 0,
            }
        except Exception:
            result['memory'] = None

        # ── Disk space (statvfs on testbed root) ──────────────────────────
        try:
            st = os.statvfs(str(self.server.testbed_root))
            total_b = st.f_frsize * st.f_blocks
            free_b  = st.f_frsize * st.f_bfree
            avail_b = st.f_frsize * st.f_bavail
            used_b  = total_b - free_b
            result['disk'] = {
                'total_gb':     round(total_b / 1e9, 1),
                'used_gb':      round(used_b  / 1e9, 1),
                'free_gb':      round(avail_b / 1e9, 1),
                'percent_used': round(used_b / total_b * 100, 1) if total_b else 0,
                'path':         str(self.server.testbed_root),
            }
        except Exception:
            result['disk'] = None

        # ── CPU temperature (/sys/class/thermal or hwmon) ─────────────────
        cpu_temp = None
        thermal_root = Path('/sys/class/thermal')
        if thermal_root.exists():
            for zone in sorted(thermal_root.glob('thermal_zone*')):
                try:
                    zone_type = (zone / 'type').read_text().strip()
                    if any(t in zone_type.lower() for t in ('cpu', 'x86', 'acpi', 'coretemp', 'soc')):
                        cpu_temp = round(int((zone / 'temp').read_text().strip()) / 1000.0, 1)
                        break
                except Exception:
                    continue
        if cpu_temp is None:
            hwmon_root = Path('/sys/class/hwmon')
            if hwmon_root.exists():
                for hwmon in sorted(hwmon_root.iterdir()):
                    try:
                        for tinput in sorted(hwmon.glob('temp*_input')):
                            cpu_temp = round(int(tinput.read_text().strip()) / 1000.0, 1)
                            break
                        if cpu_temp is not None:
                            break
                    except Exception:
                        continue
        result['cpu_temp_c'] = cpu_temp

        # ── Network I/O rate (/proc/net/dev) ──────────────────────────────
        net_rx, net_tx = self._read_net_counters()
        with self.server._metrics_lock:
            prev_net = self.server._prev_net
            if prev_net is not None:
                dt = now - prev_net[0]
                if dt > 0:
                    rx_kbs = round((net_rx - prev_net[1]) / dt / 1024, 1)
                    tx_kbs = round((net_tx - prev_net[2]) / dt / 1024, 1)
                    result['net_io'] = {
                        'rx_kbs': max(rx_kbs, 0.0),
                        'tx_kbs': max(tx_kbs, 0.0),
                    }
                else:
                    result['net_io'] = None
            else:
                result['net_io'] = None   # first call — no delta yet
            self.server._prev_net = (now, net_rx, net_tx)

        # ── Disk I/O rate (/proc/diskstats) ──────────────────────────────
        disk_rb, disk_wb = self._read_disk_counters()
        with self.server._metrics_lock:
            prev_disk = self.server._prev_disk
            if prev_disk is not None:
                dt = now - prev_disk[0]
                if dt > 0:
                    r_kbs = round((disk_rb - prev_disk[1]) / dt / 1024, 1)
                    w_kbs = round((disk_wb - prev_disk[2]) / dt / 1024, 1)
                    result['disk_io'] = {
                        'read_kbs':  max(r_kbs, 0.0),
                        'write_kbs': max(w_kbs, 0.0),
                    }
                else:
                    result['disk_io'] = None
            else:
                result['disk_io'] = None
            self.server._prev_disk = (now, disk_rb, disk_wb)

        result['timestamp'] = int(now)
        self._json(result)

    # ── Probe / connectivity diagnostics ─────────────────────────────────────
    def _probe(self, qs_str):
        """
        GET /api/probe?service=stratum0&path=/
        Returns detailed connectivity info for one service, useful for debugging.
        """
        qs = urllib.parse.parse_qs(qs_str)
        service = (qs.get('service', [''])[0]).strip()
        path    = (qs.get('path',    ['/'])[0]).strip() or '/'

        base = self.server.services.get(service)
        if not base:
            self._json({'error': f'Unknown service: {service!r}',
                        'known': list(self.server.services.keys())}, 404)
            return

        target = base.rstrip('/') + path
        result = {
            'service': service,
            'target':  target,
            'status':  None,
            'ok':      False,
            'error':   None,
            'headers': {},
            'body_preview': '',
        }
        try:
            req = urllib.request.Request(target, method='GET')
            with urllib.request.urlopen(req, timeout=10) as resp:
                data = resp.read(512)        # read only first 512 bytes
                result['status']  = resp.getcode()
                result['ok']      = 200 <= resp.getcode() < 300
                result['headers'] = dict(resp.headers)
                result['body_preview'] = data.decode('utf-8', errors='replace')
        except urllib.error.HTTPError as ex:
            result['status'] = ex.code
            result['error']  = str(ex)
            try: result['body_preview'] = ex.read(256).decode('utf-8', errors='replace')
            except Exception: pass
        except Exception as ex:
            result['error'] = f'{type(ex).__name__}: {ex}'

        self._json(result)

    # ── Reverse proxy ─────────────────────────────────────────────────────────
    def _proxy(self, remainder, qs, method='GET'):
        """Forward request to an internal service.
        remainder: 'prepub/api/v1/jobs' → service='prepub', sub='/api/v1/jobs'
        """
        parts = remainder.split('/', 1)
        service = parts[0]
        sub = '/' + parts[1] if len(parts) > 1 else '/'

        base = self.server.services.get(service)
        if not base:
            self._json({'error': f'Unknown service: {service}'}, 404)
            return

        # ── Stratum1 .cvmfspublished intercept ────────────────────────────────
        # The testbed s1a/s1b nodes run cvmfs-prepub in receiver mode, not Apache
        # httpd, so they have no /cvmfs/ HTTP endpoint.  Their data mux only serves
        # /api/v1/objects/ — forwarding the manifest request would always 404.
        #
        # Instead, serve the stratum0 .cvmfspublished directly from the host
        # filesystem (TESTBED_ROOT/repos/<repo>/.cvmfspublished).  In this testbed
        # distribution is fire-and-forget (quorum: 0), so stratum0's manifest is
        # the best available proxy for what s1a/s1b have received.
        if service in ('s1a', 's1b') and method == 'GET' and sub.endswith('/.cvmfspublished'):
            # sub = /cvmfs/<repo>/.cvmfspublished
            path_parts = [p for p in sub.split('/') if p]  # strip leading ''
            if len(path_parts) == 3 and path_parts[0] == 'cvmfs':
                repo = path_parts[1]
                pub_path = self.server.testbed_root / 'repos' / repo / '.cvmfspublished'
                try:
                    data = pub_path.read_bytes()
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/octet-stream')
                    self.send_header('Content-Length', str(len(data)))
                    self._cors()
                    self.end_headers()
                    self.wfile.write(data)
                    return
                except FileNotFoundError:
                    pass  # fall through → real proxy → 404 (acceptable)

        target = base.rstrip('/') + sub + ('?' + qs if qs else '')

        # Forward a curated set of request headers; strip X-Testbed-Token so it
        # never leaks to backend services.
        fwd_headers = {}
        for hdr in ('Authorization', 'Content-Type', 'Accept', 'Cookie'):
            val = self.headers.get(hdr)
            if val:
                fwd_headers[hdr] = val

        # When a browser opens a prepub log link directly (no JS auth header),
        # inject the prepub bearer token so the backend doesn't reject it.
        if service == 'prepub' and 'Authorization' not in fwd_headers and self.server.prepub_token:
            fwd_headers['Authorization'] = f'Bearer {self.server.prepub_token}'

        body = None
        if method == 'POST':
            cl = int(self.headers.get('Content-Length', 0) or 0)
            body = self.rfile.read(cl) if cl else b''

        try:
            req = urllib.request.Request(
                target,
                data=body,
                headers=fwd_headers,
                method=method,
            )
            with urllib.request.urlopen(req, timeout=15) as resp:
                data = resp.read()
                # resp.getcode() works on Python 3.8+; resp.status only 3.9+
                self.send_response(resp.getcode())
                for key, val in resp.headers.items():
                    if key.lower() not in PROXY_SKIP_HEADERS:
                        self.send_header(key, val)
                # Set Content-Length to the ACTUAL body length we just read,
                # which may differ from the upstream value when the response
                # was compressed (Grafana, etc.).
                self.send_header('Content-Length', str(len(data)))
                self._cors()
                self.end_headers()
                self.wfile.write(data)

        except urllib.error.HTTPError as ex:
            data = ex.read()
            self.send_response(ex.code)
            self._cors()
            self.send_header('Content-Type', ex.headers.get('Content-Type', 'text/plain'))
            self.end_headers()
            self.wfile.write(data)

        except Exception as ex:
            self._json({'error': str(ex), 'target': target}, 502)

    # ── Command runner (SSE) ──────────────────────────────────────────────────
    def _run_command(self):
        cl = int(self.headers.get('Content-Length', 0) or 0)
        raw = self.rfile.read(cl) if cl else b'{}'
        try:
            req = json.loads(raw)
        except Exception:
            self._json({'error': 'Invalid JSON body'}, 400)
            return

        cmd   = str(req.get('cmd', ''))
        flags = list(req.get('flags', []))
        args  = list(req.get('args',  []))
        # Optional: explicit file list for retry-failed scenarios (upload-filelist only).
        # If provided, the paths are written to a temp filelist and --filelist is injected.
        files = req.get('files')  # list[str] | None

        if cmd not in ALLOWED_COMMANDS:
            self._json({'error': f'Command not allowed: {cmd!r}'}, 403)
            return

        safe_flags, safe_args = [], []
        for tok in flags:
            if isinstance(tok, str) and SAFE_ARG_RE.match(tok):
                safe_flags.append(tok)
        for tok in args:
            if isinstance(tok, str) and SAFE_ARG_RE.match(tok):
                safe_args.append(tok)

        # If an explicit file list was provided for upload-filelist, write a temp
        # filelist and inject --filelist (dropping any --dir args from safe_args).
        tmp_filelist = None
        if files and cmd == 'upload-filelist':
            try:
                data_dir = self.server.testbed_root / 'data'
                data_dir.mkdir(parents=True, exist_ok=True)
                fd, tmp_path = tempfile.mkstemp(
                    prefix='retry-filelist-', suffix='.txt', dir=str(data_dir)
                )
                with os.fdopen(fd, 'w') as fh:
                    for p in files:
                        if isinstance(p, str):
                            fh.write(p.strip() + '\n')
                tmp_filelist = tmp_path
                # Strip any --dir args that were passed alongside files
                cleaned = []
                skip_next = False
                for tok in safe_args:
                    if skip_next:
                        skip_next = False
                        continue
                    if tok == '--dir':
                        skip_next = True
                        continue
                    cleaned.append(tok)
                safe_args = cleaned + ['--filelist', tmp_filelist]
            except Exception as ex:
                self._json({'error': f'Failed to write retry filelist: {ex}'}, 500)
                return

        script = str(self.server.script_path)
        full_cmd = [script, cmd] + safe_flags + safe_args

        self._sse_headers()
        self._sse(json.dumps({'cmd': cmd, 'flags': safe_flags, 'args': safe_args,
                               'full': ' '.join(full_cmd)}), event='start')

        env = {
            **os.environ,
            'FORCE_COLOR': '0', 'NO_COLOR': '1', 'TERM': 'dumb',
            'TESTBED_ROOT': str(self.server.testbed_root),
        }

        try:
            proc = subprocess.Popen(
                full_cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
                cwd=str(TESTBED_DIR),
                env=env,
            )
            self._sse(str(proc.pid), event='pid')

            for raw_line in proc.stdout:
                clean = ANSI_RE.sub('', raw_line.rstrip())
                if not self._sse(clean):
                    proc.terminate()
                    break

            proc.wait()
            self._sse(json.dumps({'exit_code': proc.returncode}), event='done')

        except FileNotFoundError:
            self._sse(json.dumps({'message': f'Script not found: {script}'}), event='error')
        except Exception as ex:
            self._sse(json.dumps({'message': str(ex)}), event='error')
        finally:
            if tmp_filelist:
                try:
                    os.unlink(tmp_filelist)
                except OSError:
                    pass


# ── MIME helper ───────────────────────────────────────────────────────────────
def _mime(suffix):
    return {
        '.html': 'text/html; charset=utf-8',
        '.js':   'application/javascript',
        '.css':  'text/css',
        '.json': 'application/json',
        '.svg':  'image/svg+xml',
        '.png':  'image/png',
        '.ico':  'image/x-icon',
    }.get(suffix.lower(), 'application/octet-stream')


# ── Server subclass carrying config ──────────────────────────────────────────
class TestbedServer(ThreadingHTTPServer):
    def __init__(self, addr, handler, args, use_tls=False):
        super().__init__(addr, handler)
        self.testbed_root = Path(args.testbed_root)
        self.script_path  = Path(args.script)
        self.use_bits     = args.bits
        self.use_mqtt     = args.mqtt
        self.use_tls      = use_tls
        self.verbose      = args.verbose
        self.auth_token    = None if args.no_auth else (args.token or secrets.token_hex(24))
        self.prepub_token      = args.prepub_token
        # Previous raw counters for rate computation (set on first call).
        self._prev_net : tuple | None = None   # (ts, rx_bytes, tx_bytes)
        self._prev_disk: tuple | None = None   # (ts, read_bytes, write_bytes)
        self._metrics_lock = threading.Lock()  # guards _prev_net / _prev_disk

        self.cas_container  = args.cas_container
        self.cas_data_path  = args.cas_data_path
        self._cas_cache: dict | None = None   # latest CAS snapshot, refreshed every TTL
        self._cas_lock = threading.Lock()

        self.services = {
            'prepub':          args.prepub,
            'gateway':         args.gateway,
            'stratum0':        args.stratum0,
            's1a':             args.s1a,
            's1b':             args.s1b,
            'victoriametrics': args.victoriametrics,
        }

        # ── NDJSON file caches ────────────────────────────────────────────────
        # Avoid reading runs.ndjson / ingest-jobs.ndjson on every HTTP request.
        # Each cache entry: {mtime: float, data: list}.  Invalidated when the
        # file's mtime changes (written by testbed.sh after each run).
        self._runs_cache: dict | None = None
        self._ingest_jobs_cache: dict | None = None
        self._ndjson_lock = threading.Lock()

        # ── Metrics push loop ─────────────────────────────────────────────────
        # Background thread: every _PUSH_INTERVAL seconds, fetches the prepub job
        # list and pushes derived time-series metrics to VictoriaMetrics.
        # On every Nth cycle also pushes CAS object/byte counts via docker exec.
        self._push_error: str | None = None   # last push error (None = OK)
        t = threading.Thread(target=self._metrics_push_loop, daemon=True)
        t.start()


# ── Metrics push loop ─────────────────────────────────────────────────────────
    # Defined as a method on TestbedServer so it can access self.services and
    # self.prepub_token.  Runs as a daemon thread started in __init__.
    _PUSH_INTERVAL  = 5    # seconds between push cycles
    _CAS_PUSH_EVERY = 12   # push CAS stats every N cycles (~60 s)

    def _metrics_push_loop(self):
        """
        Background daemon thread.  Every _PUSH_INTERVAL seconds:

        1. Fetches the prepub job list and pushes derived metrics to
           VictoriaMetrics via POST /api/v1/import/prometheus:

           testbed_prepub_bytes_total               — total compressed bytes across all jobs
           testbed_s1_bytes_distributed_total{node} — bytes confirmed per S1 node
           testbed_jobs_total{state}                — job count per state
           testbed_publish_duration_seconds{quantile="0.5"|"0.95"}
           testbed_publish_duration_seconds_sum / _count
           testbed_stage_duration_seconds{stage,quantile="0.5"}

        2. Every _CAS_PUSH_EVERY cycles also runs a docker exec inside the
           prepub container to push:

           testbed_cas_objects_total                — number of CAS files
           testbed_cas_bytes_total                  — total CAS bytes

        Distribution model:
          distribution_confirmed is a count of S1 endpoints that have ACKed.
          confirmed>=1 → s1a  confirmed>=2 → s1b (order-based heuristic;
          both converge to the same total once all endpoints confirm).
        """
        prepub_url = self.services.get('prepub', 'http://localhost:8080')
        vm_url     = self.services.get('victoriametrics', 'http://localhost:8428')
        jobs_url   = f'{prepub_url}/api/v1/jobs'
        push_url   = f'{vm_url}/api/v1/import/prometheus'
        cycle      = 0

        while True:
            try:
                ts_ms  = int(time.time() * 1000)
                lines: list[str] = []

                # ── Fetch jobs ────────────────────────────────────────────────
                req = urllib.request.Request(jobs_url)
                if self.prepub_token:
                    req.add_header('Authorization', f'Bearer {self.prepub_token}')
                with urllib.request.urlopen(req, timeout=5) as resp:
                    jobs = json.loads(resp.read().decode())

                if not isinstance(jobs, list):
                    raise ValueError(f'unexpected jobs response: {type(jobs).__name__}')

                # ── Bytes distributed (S1 ring / distribution fill) ───────────
                # testbed_prepub_bytes_total: sum of compressed bytes across all
                # jobs — useful for throughput tracking but NOT a good ring
                # reference because dedup means the same bytes are counted once per
                # job that contains them, inflating the total.
                # testbed_s1_bytes_distributed_total: actual bytes on each S1 node's
                # disk, measured via docker exec every _CAS_PUSH_EVERY cycles (same
                # cadence as CAS stats).  This avoids the job-confirmation heuristic
                # which under-reports when NewObjectHashes is empty (full-dedup jobs).
                prepub_bytes = 0
                for j in jobs:
                    prepub_bytes += int(j.get('n_bytes_compressed') or 0)

                lines.append(f'testbed_prepub_bytes_total {prepub_bytes} {ts_ms}')

                # ── Job state counts ──────────────────────────────────────────
                state_counts: dict[str, int] = {}
                for j in jobs:
                    st = str(j.get('state') or 'unknown')
                    state_counts[st] = state_counts.get(st, 0) + 1
                for state, count in state_counts.items():
                    safe = state.replace('"', '')
                    lines.append(f'testbed_jobs_total{{state="{safe}"}} {count} {ts_ms}')

                # ── Publish duration percentiles (published jobs only) ─────────
                # Try ISO-8601 created_at / published_at first; fall back to
                # pre-computed duration_s or duration_seconds fields.
                durations: list[float] = []
                for j in jobs:
                    if str(j.get('state') or '') != 'published':
                        continue
                    d = j.get('duration_s') or j.get('duration_seconds') or j.get('publish_duration_s')
                    if d is not None:
                        try:
                            durations.append(float(d))
                            continue
                        except (TypeError, ValueError):
                            pass
                    # Compute from timestamps
                    ca = j.get('created_at') or j.get('start_time') or ''
                    pa = j.get('published_at') or j.get('finish_time') or ''
                    if ca and pa:
                        try:
                            import datetime as _dt
                            def _parse(s):
                                s = s.rstrip('Z').split('+')[0]
                                for fmt in ('%Y-%m-%dT%H:%M:%S.%f', '%Y-%m-%dT%H:%M:%S'):
                                    try:
                                        return _dt.datetime.strptime(s, fmt)
                                    except ValueError:
                                        continue
                                return None
                            t0, t1 = _parse(ca), _parse(pa)
                            if t0 and t1:
                                delta = (t1 - t0).total_seconds()
                                if 0 < delta < 86400:
                                    durations.append(delta)
                        except Exception:
                            pass

                if durations:
                    durations_s = sorted(durations)
                    n = len(durations_s)
                    def _pct(p):
                        i = max(0, int(p / 100.0 * n) - 1)
                        return durations_s[min(i, n - 1)]
                    p50 = _pct(50)
                    p95 = _pct(95)
                    total = sum(durations_s)
                    lines.append(f'testbed_publish_duration_seconds{{quantile="0.5"}} {p50:.3f} {ts_ms}')
                    lines.append(f'testbed_publish_duration_seconds{{quantile="0.95"}} {p95:.3f} {ts_ms}')
                    lines.append(f'testbed_publish_duration_seconds_sum {total:.3f} {ts_ms}')
                    lines.append(f'testbed_publish_duration_seconds_count {n} {ts_ms}')

                # ── Stage duration percentiles ─────────────────────────────────
                # Jobs may carry stage-level durations in stage_durations dict or
                # individual fields (duration_pipeline_s, etc.).
                stage_fields = {
                    'pipeline':     ('duration_pipeline_s', 'pipeline_duration_s', 'pipeline_s'),
                    'lease_commit': ('duration_lease_commit_s', 'lease_commit_s', 'commit_duration_s'),
                    'distribution': ('duration_distribution_s', 'distribution_s', 'dist_duration_s'),
                }
                for stage, field_names in stage_fields.items():
                    vals: list[float] = []
                    for j in jobs:
                        if str(j.get('state') or '') != 'published':
                            continue
                        # Try nested stage_durations map first
                        sd = j.get('stage_durations') or {}
                        v = sd.get(stage)
                        if v is None:
                            for fn in field_names:
                                v = j.get(fn)
                                if v is not None:
                                    break
                        if v is not None:
                            try:
                                vals.append(float(v))
                            except (TypeError, ValueError):
                                pass
                    if vals:
                        vals_s = sorted(vals)
                        n = len(vals_s)
                        p50 = vals_s[max(0, int(0.5 * n) - 1)]
                        lines.append(
                            f'testbed_stage_duration_seconds{{stage="{stage}",quantile="0.5"}}'
                            f' {p50:.3f} {ts_ms}'
                        )

                # ── CAS disk stats (every _CAS_PUSH_EVERY cycles) ─────────────
                if cycle % self._CAS_PUSH_EVERY == 0:
                    try:
                        cp = subprocess.run(
                            ['docker', 'exec', self.cas_container, 'bash', '-c',
                             f'find {self.cas_data_path} -type f -printf "%s\\n" 2>/dev/null'
                             r" | awk 'BEGIN{c=0;s=0}{c++;s+=$1}END{print c,s}'"],
                            capture_output=True, text=True, timeout=45,
                        )
                        if cp.returncode == 0:
                            parts = cp.stdout.strip().split()
                            if len(parts) == 2:
                                cas_count = int(parts[0])
                                cas_bytes = int(parts[1])
                                if cas_count > 0:
                                    lines.append(f'testbed_cas_objects_total {cas_count} {ts_ms}')
                                    lines.append(f'testbed_cas_bytes_total {cas_bytes} {ts_ms}')
                    except Exception:
                        pass  # CAS push is best-effort; don't fail the whole cycle

                # ── Push to VictoriaMetrics ───────────────────────────────────
                payload = '\n'.join(lines) + '\n'
                push_req = urllib.request.Request(
                    push_url,
                    data=payload.encode(),
                    method='POST',
                    headers={'Content-Type': 'text/plain'},
                )
                urllib.request.urlopen(push_req, timeout=5)
                self._push_error = None

            except Exception as exc:
                self._push_error = str(exc)

            cycle += 1
            time.sleep(self._PUSH_INTERVAL)


# ── Entry point ───────────────────────────────────────────────────────────────
def main():
    args = parse_args()

    # ── Validate script ───────────────────────────────────────────────────────
    script = Path(args.script)
    if not script.is_file():
        print(f'[WARN] testbed.sh not found at {script}', file=sys.stderr)

    # ── TLS setup ─────────────────────────────────────────────────────────────
    use_tls = not args.no_tls
    ssl_ctx = None

    if use_tls:
        cert_path = Path(args.cert) if args.cert else SCRIPT_DIR / 'testbed-console-cert.pem'
        key_path  = Path(args.key)  if args.key  else SCRIPT_DIR / 'testbed-console-key.pem'

        if not cert_path.exists() or not key_path.exists():
            print('  Generating self-signed TLS certificate (first run)…', flush=True)
            generate_cert(cert_path, key_path)
            print(f'  Saved: {cert_path.name}, {key_path.name}')

        fingerprint = cert_fingerprint(cert_path)

        ssl_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ssl_ctx.load_cert_chain(cert_path, key_path)

    # ── Start server ──────────────────────────────────────────────────────────
    addr   = (args.bind, args.port)
    server = TestbedServer(addr, Handler, args, use_tls=use_tls)

    if ssl_ctx:
        server.socket = ssl_ctx.wrap_socket(server.socket, server_side=True)

    proto = 'https' if use_tls else 'http'
    token = server.auth_token

    try:
        import socket as _socket
        hostname = _socket.getfqdn()
    except Exception:
        hostname = 'this-host'

    # ── Print startup banner ──────────────────────────────────────────────────
    sep = '─' * 60
    print(sep)
    print('  CVMFS Testbed Console')
    print(sep)
    print(f'  Protocol  : {proto.upper()}')
    print(f'  Listening : {args.bind}:{args.port}')
    print(f'  Testbed   : {args.testbed_root}')
    print(f'  Script    : {args.script}')
    print(f'  Overlays  : bits={args.bits}  mqtt={args.mqtt}')
    if use_tls:
        print(f'  TLS cert  : {cert_path}')
        print(f'  Fingerprint: {fingerprint}')
    prepub_token    = server.prepub_token
    if token:
        params = f'token={urllib.parse.quote(token, safe="")}'
        if prepub_token:
            params += f'&prepub-token={urllib.parse.quote(prepub_token, safe="")}'
        base_url   = f'{proto}://{hostname}:{args.port}/'
        url_with_token = f'{base_url}?{params}'
        print(sep)
        print(f'  Secret token  : {token}')
        if prepub_token:
            print(f'  Prepub token  : {prepub_token}')
        print()
        print(f'  *** Open this URL in your browser — all tokens are pre-filled: ***')
        print()
        print(f'  {url_with_token}')
        print()
        # Also print just the base URL with a note about copy-paste resilience.
        # The server sets a session cookie when it sees ?token= on the page load,
        # so even if the browser is later refreshed (without the query string) it
        # stays authenticated for the lifetime of the browser session.
        print(f'  Base URL (works after first login): {base_url}')
        print()
        print(f'  Tip: copy the FULL URL above — it must include the ?token= part.')
        print(f'       If you get a login prompt, paste the secret token into the field.')
    else:
        base_url = f'{proto}://{hostname}:{args.port}/'
        if prepub_token:
            base_url += f'?prepub-token={urllib.parse.quote(prepub_token, safe="")}'
        print()
        print(f'  Open: {base_url}')
        print(f'  [WARNING] Authentication disabled (--no-auth). Use only on trusted networks.')
    print(sep)
    print('  Press Ctrl-C to stop.')
    print()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print('\nShutting down.')
        server.shutdown()


if __name__ == '__main__':
    main()
