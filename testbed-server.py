#!/usr/bin/env python3
"""
testbed-server.py — Backend server for the CVMFS Testbed Console.

Usage:
    python3 testbed-server.py [--port 8888] [--bind 0.0.0.0]
    # Or via the testbed.sh wrapper (preferred):
    ./testbed.sh server [port]

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
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

# ── Globals ───────────────────────────────────────────────────────────────────
SCRIPT_DIR = Path(__file__).parent.resolve()
ANSI_RE = re.compile(r'\x1b\[[0-9;]*[mKHABCDGJ]')

# Commands allowed via /api/run (security whitelist — no shell metacharacters).
ALLOWED_COMMANDS = frozenset({
    'status', 'info', 'logs', 'test', 'stresstest', 'mqtttest', 'unittest',
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

        self._json({'error': 'Unauthorized — supply X-Testbed-Token or Authorization: Bearer header'}, 401)
        return False

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
        if path in ('/', '/testbed-console.html'):
            self._serve_static(SCRIPT_DIR / 'testbed-console.html',
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

            if path == '/api/manifest':
                self._manifest()
                return

            if path == '/api/host-metrics':
                self._host_metrics()
                return

            if path == '/api/host-metrics/history':
                self._host_metrics_history()
                return

            if path == '/api/cas-stats':
                self._cas_stats()
                return

            if path == '/api/cas-stats/history':
                self._cas_stats_history()
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
        fpath = SCRIPT_DIR / path.lstrip('/')
        if fpath.is_file() and fpath.is_relative_to(SCRIPT_DIR):
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
        self._cors()
        self.end_headers()
        self.wfile.write(data)

    # ── Filelist ──────────────────────────────────────────────────────────────
    def _filelist(self):
        """
        GET /api/filelist
        Looks for filelist.txt in:
          1. TESTBED_ROOT/data/filelist.txt
          2. SCRIPT_DIR/filelist.txt  (same directory as this script)
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
            SCRIPT_DIR / 'filelist.txt',
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
    DEFAULT_SCAN_DIR = '/home/pbuncic/Software/Bits/sw-lhcb/TARS'

    def _scan_dir(self, query_string: str):
        """
        GET /api/scan-dir?path=<dir>[&recursive=1]
        Scans the given directory for *.tar.gz files and returns metadata.
        Default path: /home/pbuncic/Software/Bits/sw-lhcb/TARS
        Response: {path, exists, files: [{name, path, size_bytes, size_human}]}
        """
        params = urllib.parse.parse_qs(query_string or '')
        scan_path = (params.get('path', [self.DEFAULT_SCAN_DIR])[0]).strip()
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

    # ── Ingest job list ───────────────────────────────────────────────────────
    def _ingest_jobs(self):
        """
        GET /api/ingest-jobs
        Reads TESTBED_ROOT/data/ingest-jobs.ndjson (written by native-stress.sh
        and native-smoke.sh) and returns a JSON array sorted newest-first.
        Returns [] when the file is absent or empty — never an error.
        """
        log_path = self.server.testbed_root / 'data' / 'ingest-jobs.ndjson'
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
                        pass  # skip corrupt lines
        except FileNotFoundError:
            pass  # log not created yet — return empty list
        # Newest first (sort by created_at string; ISO-8601 sorts lexicographically)
        jobs.sort(key=lambda j: j.get('created_at', ''), reverse=True)
        self._json(jobs)

    # ── Run history ───────────────────────────────────────────────────────────
    def _runs(self):
        """
        GET /api/runs
        Reads TESTBED_ROOT/data/runs.ndjson and returns a JSON array sorted
        newest-first.  Returns [] when the file is absent or empty.
        """
        log_path = self.server.testbed_root / 'data' / 'runs.ndjson'
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
        self._json(runs)

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
                iso_time = datetime.datetime.utcfromtimestamp(int(timestamp)).strftime('%Y-%m-%dT%H:%M:%SZ')
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
        Counts CAS objects and sums their sizes by running two short commands
        inside the prepub Docker container via docker exec.
        Results are cached for _CAS_CACHE_TTL seconds and appended to a
        rolling history ring so /api/cas-stats/history can power a chart.

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
            # File count
            cp = subprocess.run(
                ['docker', 'exec', container, 'bash', '-c',
                 f'find {data_path} -type f 2>/dev/null | wc -l'],
                capture_output=True, text=True, timeout=45,
            )
            if cp.returncode == 0:
                count = int(cp.stdout.strip() or '0')

            # Total size in bytes via du -sb (works on GNU/BusyBox)
            cs = subprocess.run(
                ['docker', 'exec', container, 'bash', '-c',
                 f'du -sb {data_path} 2>/dev/null | cut -f1 || echo 0'],
                capture_output=True, text=True, timeout=45,
            )
            if cs.returncode == 0:
                raw = cs.stdout.strip().splitlines()
                total_bytes = int(raw[0]) if raw else 0

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

        snap = {'ts': int(now), 'count': count, 'bytes': total_bytes}
        with self.server._cas_lock:
            self.server._cas_cache = result
            if count > 0:          # only record valid snapshots
                self.server._cas_history.append(snap)

        self._json(result)

    def _cas_stats_history(self):
        """
        GET /api/cas-stats/history
        Returns the rolling history of CAS snapshots as a JSON array (oldest first).
        Each entry: {ts, count, bytes}
        """
        with self.server._cas_lock:
            history = list(self.server._cas_history)
        self._json(history)

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
        I/O rates (KB/s) by differencing successive calls.  Appends a flat
        snapshot to the server-side history ring for /api/host-metrics/history.
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

        # ── Append flat snapshot to history ring ──────────────────────────
        snap: dict = {'ts': int(now)}
        if result['cpu_load']:
            snap['cpu_load1']  = result['cpu_load']['load1']
            snap['cpu_load5']  = result['cpu_load']['load5']
            snap['cpu_load15'] = result['cpu_load']['load15']
        if result['memory']:
            snap['mem_pct'] = result['memory']['percent_used']
        if result['disk']:
            snap['disk_pct'] = result['disk']['percent_used']
        if result['cpu_temp_c'] is not None:
            snap['cpu_temp'] = result['cpu_temp_c']
        if result['net_io']:
            snap['net_rx_kbs'] = result['net_io']['rx_kbs']
            snap['net_tx_kbs'] = result['net_io']['tx_kbs']
        if result['disk_io']:
            snap['disk_read_kbs']  = result['disk_io']['read_kbs']
            snap['disk_write_kbs'] = result['disk_io']['write_kbs']
        with self.server._metrics_lock:
            self.server._metrics_history.append(snap)

        self._json(result)

    def _host_metrics_history(self):
        """
        GET /api/host-metrics/history
        Returns the in-memory ring of flat metric snapshots as a JSON array,
        oldest first (chronological order for charting).
        """
        with self.server._metrics_lock:
            history = list(self.server._metrics_history)
        self._json(history)

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

        target = base.rstrip('/') + sub + ('?' + qs if qs else '')

        # Forward a curated set of request headers; strip X-Testbed-Token so it
        # never leaks to backend services.
        fwd_headers = {}
        for hdr in ('Authorization', 'Content-Type', 'Accept', 'Cookie'):
            val = self.headers.get(hdr)
            if val:
                fwd_headers[hdr] = val

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
                cwd=str(SCRIPT_DIR),
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
        # ── Host-metrics history ──────────────────────────────────────────────
        # Rolling buffer of flat metric snapshots, one per /api/host-metrics call.
        # 120 samples × 30 s auto-refresh ≈ 60 minutes of history.
        self._metrics_history: deque = deque(maxlen=120)
        self._metrics_lock    = threading.Lock()
        # Previous raw counters for rate computation (set on first call).
        self._prev_net : tuple | None = None   # (ts, rx_bytes, tx_bytes)
        self._prev_disk: tuple | None = None   # (ts, read_bytes, write_bytes)

        self.cas_container = args.cas_container
        self.cas_data_path = args.cas_data_path
        # Rolling CAS stats history (200 samples × 20 s TTL ≈ ~67 min)
        self._cas_history: deque = deque(maxlen=200)
        self._cas_cache: dict | None = None   # latest result, refreshed every TTL
        self._cas_lock = threading.Lock()

        self.services = {
            'prepub':          args.prepub,
            'gateway':         args.gateway,
            'stratum0':        args.stratum0,
            's1a':             args.s1a,
            's1b':             args.s1b,
            'victoriametrics': args.victoriametrics,
        }


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
        url_with_token = f'{proto}://{hostname}:{args.port}/?{params}'
        print(sep)
        print(f'  Secret token  : {token}')
        if prepub_token:
            print(f'  Prepub token  : {prepub_token}')
        print()
        print(f'  *** Open this URL in your browser (all tokens pre-filled): ***')
        print(f'  {url_with_token}')
        print()
        print(f'  (The server token is required for all /api/* requests.)')
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
