#!/usr/bin/env python3
"""
seed.py — One-shot Gitea seeder for the cvmfs-bits testbed.

What it does (idempotently):
  1. Waits for Gitea to become healthy.
  2. Creates (or reuses) a long-lived admin API token.
  3. Creates the 'testbed' organisation and 'bits-project' repository.
  4. Pushes bits-console source (+ testbed community + Gitea workflow) to 'main'.
  5. Runs build-communities.sh, copies index.html, pushes built Pages to 'gh-pages'.
  6. Sets CI variables (PREPUB_URL, CVMFS_REPO, METRICS_URL) and secret (PREPUB_API_TOKEN).
  7. Prints the runner registration token.
"""

import os
import sys
import time
import shutil
import subprocess
import tempfile
import textwrap
import requests
import yaml

# ── Environment ───────────────────────────────────────────────────────────────
GITEA_URL           = os.environ["GITEA_URL"].rstrip("/")
GITEA_ADMIN_USER    = os.environ["GITEA_ADMIN_USER"]
GITEA_ADMIN_PASSWORD= os.environ["GITEA_ADMIN_PASSWORD"]
GITEA_ORG           = os.environ.get("GITEA_ORG", "testbed")
GITEA_REPO          = os.environ.get("GITEA_REPO", "bits-project")
BITS_CONSOLE_SRC    = "/bits-console"  # mounted read-only from host

# CI variables passed to act_runner jobs (host-visible URLs)
PREPUB_URL          = os.environ.get("PREPUB_URL", "http://localhost:8080")
PREPUB_API_TOKEN    = os.environ.get("PREPUB_API_TOKEN", "")
CVMFS_REPO          = os.environ.get("CVMFS_REPO", "test.cvmfs.io")
METRICS_URL         = os.environ.get("METRICS_URL", "http://localhost:8428")

TOKEN_NAME = "seeder-token"

# ── Helpers ───────────────────────────────────────────────────────────────────

def log(msg: str) -> None:
    print(f"[seeder] {msg}", flush=True)


def api(method: str, path: str, **kwargs) -> requests.Response:
    """Make an authenticated request to the Gitea API."""
    url = f"{GITEA_URL}/api/v1{path}"
    headers = kwargs.pop("headers", {})
    headers["Authorization"] = f"token {_admin_token()}"
    headers["Content-Type"] = "application/json"
    return requests.request(method, url, headers=headers, **kwargs)


_token_cache: str | None = None

def _admin_token() -> str:
    global _token_cache
    if _token_cache:
        return _token_cache
    # Try to create a new token (idempotent: delete first if already exists)
    auth = (GITEA_ADMIN_USER, GITEA_ADMIN_PASSWORD)
    base = f"{GITEA_URL}/api/v1"
    # List existing tokens
    r = requests.get(f"{base}/users/{GITEA_ADMIN_USER}/tokens", auth=auth)
    r.raise_for_status()
    for tok in r.json():
        if tok["name"] == TOKEN_NAME:
            # Delete the old token so we can create a fresh one with a known value
            requests.delete(
                f"{base}/users/{GITEA_ADMIN_USER}/tokens/{tok['id']}", auth=auth
            ).raise_for_status()
            break
    # Create a new token
    r = requests.post(
        f"{base}/users/{GITEA_ADMIN_USER}/tokens",
        auth=auth,
        json={"name": TOKEN_NAME},
    )
    r.raise_for_status()
    _token_cache = r.json()["sha1"]
    log(f"Admin API token created (name={TOKEN_NAME})")
    return _token_cache


def wait_for_gitea(timeout: int = 300) -> None:
    log(f"Waiting for Gitea at {GITEA_URL} ...")
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            r = requests.get(f"{GITEA_URL}/api/v1/version", timeout=5)
            if r.status_code == 200:
                log(f"Gitea is up: {r.json()}")
                return
        except Exception:
            pass
        time.sleep(3)
    raise RuntimeError(f"Gitea did not become healthy within {timeout}s")


def ensure_org() -> None:
    r = api("GET", f"/orgs/{GITEA_ORG}")
    if r.status_code == 200:
        log(f"Organisation '{GITEA_ORG}' already exists")
        return
    api("POST", "/orgs", json={
        "username": GITEA_ORG,
        "visibility": "public",
        "repo_admin_change_team_access": True,
    }).raise_for_status()
    log(f"Organisation '{GITEA_ORG}' created")


def ensure_repo() -> None:
    r = api("GET", f"/repos/{GITEA_ORG}/{GITEA_REPO}")
    if r.status_code == 200:
        log(f"Repository '{GITEA_ORG}/{GITEA_REPO}' already exists")
        return
    api("POST", f"/orgs/{GITEA_ORG}/repos", json={
        "name": GITEA_REPO,
        "description": "bits-console testbed repository",
        "private": False,
        "auto_init": False,
        "default_branch": "main",
    }).raise_for_status()
    log(f"Repository '{GITEA_ORG}/{GITEA_REPO}' created")


def push_main_branch(work_dir: str) -> None:
    """Clone a fresh local repo, populate it with bits-console source, push to main."""
    repo_dir = os.path.join(work_dir, "repo")
    log("Assembling 'main' branch content ...")

    # Copy bits-console source
    shutil.copytree(BITS_CONSOLE_SRC, repo_dir, symlinks=False,
                    ignore=shutil.ignore_patterns(".git", "node_modules", "public"))

    # Ensure the testbed community config is present
    community_dst = os.path.join(repo_dir, "communities", "testbed")
    os.makedirs(community_dst, exist_ok=True)
    ui_config = {
        "title": "CVMFS Testbed",
        "description": "Local testbed for bits-console + cvmfs-prepub",
        "api_type": "gitea",
        "gitlab_url": "http://localhost:3000",
        "project_id": f"{GITEA_ORG}/{GITEA_REPO}",
        "workflow_file": "bits-publish.yaml",
        "admins": ["testbed-admin"],
        "read_token": "",  # public repo — no token needed
        "cvmfs_repo": CVMFS_REPO,
        "cvmfs_prefix": "/cvmfs/" + CVMFS_REPO,
        "cvmfs_user_prefix": "/cvmfs/" + CVMFS_REPO + "/users",
        "platforms": [
            {"name": "linux/amd64",  "runner_arch": "amd64",  "label": "Linux x86_64"},
            {"name": "linux/arm64",  "runner_arch": "arm64",  "label": "Linux ARM64"},
        ],
    }
    with open(os.path.join(community_dst, "ui-config.yaml"), "w") as f:
        yaml.dump(ui_config, f, default_flow_style=False)

    # Ensure the Gitea Actions workflow is present
    wf_dir = os.path.join(repo_dir, ".gitea", "workflows")
    os.makedirs(wf_dir, exist_ok=True)
    wf_path = os.path.join(wf_dir, "bits-publish.yaml")
    if not os.path.exists(wf_path):
        _write_workflow(wf_path)

    # Initialise git and push
    _git_init_and_push(repo_dir, "main")
    log("'main' branch pushed")


def push_gh_pages(work_dir: str) -> None:
    """Build communities static tree and push to gh-pages branch."""
    build_dir = os.path.join(work_dir, "build")
    shutil.copytree(BITS_CONSOLE_SRC, build_dir, symlinks=False,
                    ignore=shutil.ignore_patterns(".git", "node_modules"))

    # Ensure the testbed community config exists in the build tree
    community_dst = os.path.join(build_dir, "communities", "testbed")
    os.makedirs(community_dst, exist_ok=True)
    ui_config_path = os.path.join(community_dst, "ui-config.yaml")
    if not os.path.exists(ui_config_path):
        ui_config = {
            "title": "CVMFS Testbed",
            "description": "Local testbed for bits-console + cvmfs-prepub",
            "api_type": "gitea",
            "gitlab_url": "http://localhost:3000",
            "project_id": f"{GITEA_ORG}/{GITEA_REPO}",
            "workflow_file": "bits-publish.yaml",
            "admins": ["testbed-admin"],
            "read_token": "",
            "cvmfs_repo": CVMFS_REPO,
            "cvmfs_prefix": "/cvmfs/" + CVMFS_REPO,
            "cvmfs_user_prefix": "/cvmfs/" + CVMFS_REPO + "/users",
            "platforms": [
                {"name": "linux/amd64",  "runner_arch": "amd64",  "label": "Linux x86_64"},
                {"name": "linux/arm64",  "runner_arch": "arm64",  "label": "Linux ARM64"},
            ],
        }
        with open(ui_config_path, "w") as f:
            yaml.dump(ui_config, f, default_flow_style=False)

    # Run build-communities.sh
    build_script = os.path.join(build_dir, "build-communities.sh")
    if not os.path.exists(build_script):
        log("WARNING: build-communities.sh not found — skipping Pages build")
        return

    log("Running build-communities.sh ...")
    result = subprocess.run(
        ["bash", build_script],
        cwd=build_dir,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        log(f"build-communities.sh stdout:\n{result.stdout}")
        log(f"build-communities.sh stderr:\n{result.stderr}")
        raise RuntimeError(f"build-communities.sh failed (exit {result.returncode})")
    log("build-communities.sh succeeded")

    public_dir = os.path.join(build_dir, "public")
    if not os.path.exists(public_dir):
        raise RuntimeError("build-communities.sh did not produce public/")

    # Copy index.html into each community subdirectory
    # (build-communities.sh generates community-specific files but not index.html per subdir)
    index_html = os.path.join(build_dir, "index.html")
    if os.path.exists(index_html):
        for item in os.listdir(public_dir):
            subdir = os.path.join(public_dir, item)
            if os.path.isdir(subdir):
                dst = os.path.join(subdir, "index.html")
                if not os.path.exists(dst):
                    shutil.copy2(index_html, dst)
                    log(f"Copied index.html → public/{item}/index.html")
    else:
        log("WARNING: index.html not found in bits-console root — community subdirs will lack index.html")

    # Also ensure index.html is at the Pages root
    root_index = os.path.join(public_dir, "index.html")
    if not os.path.exists(root_index) and os.path.exists(index_html):
        shutil.copy2(index_html, root_index)

    # Push public/ as an orphan gh-pages branch
    pages_repo = os.path.join(work_dir, "pages")
    shutil.copytree(public_dir, pages_repo)
    _git_init_and_push(pages_repo, "gh-pages")
    log("'gh-pages' branch pushed")


def set_ci_variables() -> None:
    """Create repository-level CI variables for the act_runner jobs."""
    variables = [
        {"key": "PREPUB_URL",   "value": PREPUB_URL,   "masked": False},
        {"key": "CVMFS_REPO",   "value": CVMFS_REPO,   "masked": False},
        {"key": "METRICS_URL",  "value": METRICS_URL,  "masked": False},
    ]
    for var in variables:
        r = api("GET", f"/repos/{GITEA_ORG}/{GITEA_REPO}/actions/variables/{var['key']}")
        if r.status_code == 200:
            api("PUT", f"/repos/{GITEA_ORG}/{GITEA_REPO}/actions/variables/{var['key']}",
                json=var).raise_for_status()
            log(f"CI variable updated: {var['key']}")
        else:
            api("POST", f"/repos/{GITEA_ORG}/{GITEA_REPO}/actions/variables",
                json=var).raise_for_status()
            log(f"CI variable created: {var['key']}")

    # Create secret for the API token
    if PREPUB_API_TOKEN:
        api("PUT", f"/repos/{GITEA_ORG}/{GITEA_REPO}/actions/secrets/PREPUB_API_TOKEN",
            json={"data": PREPUB_API_TOKEN, "name": "PREPUB_API_TOKEN"}).raise_for_status()
        log("CI secret created/updated: PREPUB_API_TOKEN")


def print_runner_token() -> None:
    """Fetch and print the runner registration token."""
    r = api("GET", f"/repos/{GITEA_ORG}/{GITEA_REPO}/runners/registration-token")
    if r.status_code == 200:
        token = r.json().get("token", "<check Gitea UI>")
    else:
        # Fallback: admin-level token
        r2 = api("GET", "/admin/runners/registration-token")
        token = r2.json().get("token", "<unavailable>") if r2.status_code == 200 else "<unavailable>"

    print()
    print("=" * 60)
    print("act_runner registration token:")
    print(f"  {token}")
    print()
    print("Register the runner on the host:")
    print("  act_runner register \\")
    print(f"    --instance http://localhost:3000 \\")
    print(f"    --token {token} \\")
    print(f"    --name bits-host-runner \\")
    print(f"    --labels self-hosted,bits,ubuntu-latest \\")
    print(f"    --no-interactive")
    print()
    print("Or use the systemd unit in act_runner/act_runner.service")
    print("=" * 60)
    print(flush=True)


# ── Git helpers ───────────────────────────────────────────────────────────────

def _git_init_and_push(src_dir: str, branch: str) -> None:
    """Initialise a git repo in src_dir and force-push to Gitea."""
    remote_url = (
        f"http://{GITEA_ADMIN_USER}:{GITEA_ADMIN_PASSWORD}"
        f"@{GITEA_URL.split('://', 1)[1]}/{GITEA_ORG}/{GITEA_REPO}.git"
    )

    def git(*args: str) -> None:
        result = subprocess.run(
            ["git"] + list(args),
            cwd=src_dir,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            raise RuntimeError(
                f"git {' '.join(args)} failed:\n{result.stderr}"
            )

    git("init", "-b", branch)
    git("config", "user.email", "seeder@testbed.local")
    git("config", "user.name", "Testbed Seeder")
    git("add", "-A")
    git("commit", "-m", f"chore: seed {branch} branch")
    git("remote", "add", "origin", remote_url)
    git("push", "--force", "origin", branch)


def _write_workflow(path: str) -> None:
    """Write the Gitea Actions bits-publish workflow."""
    content = textwrap.dedent("""\
        # .gitea/workflows/bits-publish.yaml
        # Triggered by bits-console when a user submits a build job.
        # Runs on the physical host runner (act_runner) which has direct access
        # to the Docker daemon, CVMFS mounts, and the bits build toolchain.
        name: bits-publish
        on:
          workflow_dispatch:
            inputs:
              COMMUNITY:
                description: "Community name (matches communities/ directory)"
                required: true
              PACKAGE:
                description: "Package name to build"
                required: true
              VERSION:
                description: "Package version"
                required: true
              PLATFORM:
                description: "Target platform (e.g. linux/amd64)"
                required: true
              RUNNER_ARCH:
                description: "Runner architecture (amd64 or arm64)"
                required: false
                default: "amd64"
              BITS_BUILD_ARGS:
                description: "Extra arguments forwarded to bits build"
                required: false
                default: ""
              PUBLISH_TIMEOUT:
                description: "Timeout for cvmfs-prepub publish (seconds)"
                required: false
                default: "300"

        run-name: "${{ inputs.PACKAGE }} (${{ inputs.PLATFORM }})"

        jobs:
          publish:
            runs-on: [self-hosted, bits]
            timeout-minutes: 60

            env:
              COMMUNITY:    ${{ inputs.COMMUNITY }}
              PACKAGE:      ${{ inputs.PACKAGE }}
              VERSION:      ${{ inputs.VERSION }}
              PLATFORM:     ${{ inputs.PLATFORM }}
              RUNNER_ARCH:  ${{ inputs.RUNNER_ARCH }}

            steps:
              - name: Checkout repository
                uses: actions/checkout@v3

              - name: Validate community config
                run: |
                  CONFIG="communities/${COMMUNITY}/ui-config.yaml"
                  if [[ ! -f "$CONFIG" ]]; then
                    echo "ERROR: Community config not found: $CONFIG"
                    exit 1
                  fi
                  echo "Community config found: $CONFIG"
                  # Extract key fields for subsequent steps
                  CVMFS_REPO=$(python3 -c "import yaml,sys; c=yaml.safe_load(open('$CONFIG')); print(c['cvmfs_repo'])")
                  CVMFS_PREFIX=$(python3 -c "import yaml,sys; c=yaml.safe_load(open('$CONFIG')); print(c['cvmfs_prefix'])")
                  echo "CVMFS_REPO=$CVMFS_REPO"    >> "$GITHUB_ENV"
                  echo "CVMFS_PREFIX=$CVMFS_PREFIX" >> "$GITHUB_ENV"

              - name: Authorize submitter
                run: |
                  CONFIG="communities/${COMMUNITY}/ui-config.yaml"
                  ADMINS=$(python3 -c "import yaml,sys; c=yaml.safe_load(open('$CONFIG')); print(' '.join(c.get('admins', [])))")
                  ACTOR="${{ github.actor }}"
                  echo "Submitter: $ACTOR"
                  echo "Authorized admins: $ADMINS"
                  if echo "$ADMINS" | grep -qw "$ACTOR"; then
                    echo "Submitter is authorized."
                  else
                    echo "ERROR: $ACTOR is not in the admin list for community ${COMMUNITY}"
                    exit 1
                  fi

              - name: Set up bits environment
                run: |
                  # Source bits environment setup if present
                  if [[ -f "config/bits-setup.sh" ]]; then
                    source config/bits-setup.sh
                  fi
                  # Determine work directory from config
                  if [[ -f "config/dirs.yaml" ]]; then
                    BITS_WORK_DIR=$(python3 -c "import yaml; c=yaml.safe_load(open('config/dirs.yaml')); print(c.get('sw_dir', '/tmp/bits-work'))")
                  else
                    BITS_WORK_DIR="/tmp/bits-work"
                  fi
                  # Create a unique scratch dir for this job
                  JOB_SCRATCH="${BITS_WORK_DIR}/jobs/${{ github.run_id }}-${{ github.run_number }}"
                  mkdir -p "$JOB_SCRATCH"
                  echo "BITS_WORK_DIR=$BITS_WORK_DIR" >> "$GITHUB_ENV"
                  echo "JOB_SCRATCH=$JOB_SCRATCH"     >> "$GITHUB_ENV"

              - name: Build package
                run: |
                  set -euo pipefail
                  BUILD_ARGS="${{ inputs.BITS_BUILD_ARGS }}"
                  echo "Building: ${PACKAGE} ${VERSION} for ${PLATFORM}"
                  bits build \
                    --community "${COMMUNITY}" \
                    --package   "${PACKAGE}" \
                    --version   "${VERSION}" \
                    --platform  "${PLATFORM}" \
                    --output    "${JOB_SCRATCH}" \
                    ${BUILD_ARGS}

              - name: Publish to CVMFS
                env:
                  PREPUB_API_TOKEN: ${{ secrets.PREPUB_API_TOKEN }}
                run: |
                  set -euo pipefail
                  TIMEOUT="${{ inputs.PUBLISH_TIMEOUT }}"
                  echo "Publishing ${PACKAGE} ${VERSION} to ${CVMFS_REPO} ..."
                  bits publish \
                    --prepub-url   "${PREPUB_URL}" \
                    --token        "${PREPUB_API_TOKEN}" \
                    --repo         "${CVMFS_REPO}" \
                    --prefix       "${CVMFS_PREFIX}" \
                    --package      "${PACKAGE}" \
                    --version      "${VERSION}" \
                    --platform     "${PLATFORM}" \
                    --source       "${JOB_SCRATCH}" \
                    --timeout      "${TIMEOUT}"

              - name: Update status file
                if: always()
                env:
                  PREPUB_API_TOKEN: ${{ secrets.PREPUB_API_TOKEN }}
                run: |
                  STATUS="success"
                  if [[ "${{ job.status }}" != "success" ]]; then
                    STATUS="failed"
                  fi
                  # Update cvmfs-status.json in the repository
                  TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
                  STATUS_FILE="cvmfs-status.json"
                  echo "{ \\"package\\": \\"${PACKAGE}\\", \\"version\\": \\"${VERSION}\\", \\"platform\\": \\"${PLATFORM}\\", \\"status\\": \\"${STATUS}\\", \\"timestamp\\": \\"${TIMESTAMP}\\" }" > "${STATUS_FILE}"
                  git config user.email "ci@testbed.local"
                  git config user.name  "Testbed CI"
                  git add "${STATUS_FILE}"
                  git diff --cached --quiet || git commit -m "ci: update status for ${PACKAGE} ${VERSION} [skip ci]"
                  git push "https://x-access-token:${{ github.token }}@${GITEA_URL#http://}/${GITEA_ORG}/${GITEA_REPO}.git" HEAD:main || true

              - name: Cleanup scratch dir
                if: always()
                run: |
                  rm -rf "${JOB_SCRATCH}" || true
    """)
    with open(path, "w") as f:
        f.write(content)


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    wait_for_gitea()

    log("Creating organisation and repository ...")
    ensure_org()
    ensure_repo()

    with tempfile.TemporaryDirectory(prefix="seeder-") as work_dir:
        log("Pushing main branch ...")
        push_main_branch(work_dir)

        log("Building and pushing gh-pages branch ...")
        try:
            push_gh_pages(work_dir)
        except Exception as e:
            log(f"WARNING: gh-pages push failed: {e}")
            log("bits-console Pages will not be available until this is resolved.")

    log("Setting CI variables and secrets ...")
    set_ci_variables()

    log("Fetching runner registration token ...")
    print_runner_token()

    log("Seeding complete.")


if __name__ == "__main__":
    main()
