# Makefile — cvmfs-testbed top-level build and lifecycle management.
#
# Sentinel-file pattern
# ─────────────────────
# Each one-time setup step touches a file in .make/ when it succeeds.
# Make uses the sentinel as the target so it only reruns if the sentinel is
# absent or older than its dependencies.  Delete a sentinel to force a step
# to rerun:
#   rm .make/bootstrap && make bootstrap   # re-run bootstrap only
#   rm -rf .make        && make            # re-run everything
#
# Key sentinels:
#   .make/build        cvmfs-bits compiled
#   .make/install      binaries copied to software/
#   .make/init         testbed initialised (secrets, configs, host repo)
#   .make/bootstrap    cvmfs-bootstrap container ran + snapshot created
#
# Targets:
#   make               Full pipeline: build → install → init → start → bootstrap
#   make build         git pull + make build inside cvmfs-bits/
#   make install       build, then copy binaries into software/
#   make init          One-time testbed initialisation
#   make start         Start containers (auto-restores from snapshot if present)
#   make ensure        Make the testbed ready (init+payload+start+golden), idempotent
#   make bootstrap     Run privileged bootstrap container, create snapshot
#   make snapshot      Save repo state to repo-seed.tar.gz (called by bootstrap)
#   make restore       Restore repo state from repo-seed.tar.gz
#   make redeploy      install + full reset + bootstrap
#   make clean         Stop containers and wipe all testbed state (keeps snapshot and .env)
#   make cleanall      Like clean, but also deletes .env (full credential reset)
#   make test          FULL test suite — all nine tests (records metrics);
#                      auto-runs 'ensure' first so it works from ANY state;
#                      subset via  make test TESTS="bits chunking content"
#   make test-suite    Alias of `make test` (honors TESTS=)
#   make test-ingest   Suite: cvmfs_server ingest smoke (auto-ensure; skips if no golden)
#   make test-bits     Suite: cvmfs-prepub REST API smoke
#   make test-chunking Suite: bits publish + xor32 chunk verify
#   make test-content  Suite: compare-trees vs golden/smoke
#   make test-stress   Suite: stress N=10 (bits)
#   make test-mkdirp   Suite: CVMFS_GW_MKDIR_PARENTS gate, on AND off
#   make test-idem     Suite: two packages under one shared parent (-c matrix)
#   make test-check    Suite: cvmfs_swissknife check -c (catalogs + data objects)
#   make check         Same check, raw output, no metrics record
#   make stresstest    Stress test — bits method, N jobs (default N=10)
#   make stresstest-ingest  Stress test — ingest path
#   make catdiff       Diff catalog dumps: ingest vs bits
#   make runner-perms  Grant the CI runner access to the testbed + spool
#   make check-runner-access  Check that access, read-only
#   make help          Print this summary
#
# Variables (override on the command line or in the environment):
#   BITS_DIR      Path to the cvmfs-bits source tree.
#                 Default: $(CURDIR)/cvmfs-bits
#                 Example: make BITS_DIR=/home/user/src/cvmfs-bits
#   TESTBED_ROOT  Path to testbed data root (default: $HOME/cvmfs-testbed).
#                 Used to locate repo-seed.tar.gz for the bootstrap target.
#   RUNNER_USER   CI user that runs producer-side publish steps, for
#                 runner-perms / check-runner-access (default: gitlab-runner)
#   ADVISORY      Set to 1 to make check-runner-access report without failing
#   N             Number of jobs for stresstest targets (default: 10)
#   C             Concurrency (max parallel jobs) for the bits stresstest (default: unset = script default of 2)
#
# Examples:
#   make                            # full pipeline from scratch
#   make bootstrap                  # seed nested catalog + snapshot (once)
#   make test-ingest                # run ingest smoke test (needs bootstrap)
#   make test-ingest test-bits      # run both paths
#   make catdiff                    # diff catalog dumps
#   make stresstest N=50            # 50-job bits stress test (concurrency=2)
#   make stresstest N=50 C=10       # 50-job bits stress test, 10 at a time
#   make BITS_DIR=~/cvmfs-bits      # custom bits source location
#   rm .make/bootstrap && make bootstrap  # force re-bootstrap

# ── Shell ─────────────────────────────────────────────────────────────────────
SHELL := /bin/bash

# ── Paths ─────────────────────────────────────────────────────────────────────
MAKEFILE_DIR := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
TESTBED      := $(MAKEFILE_DIR)/testbed
INSTALL_SH   := $(MAKEFILE_DIR)/scripts/install.sh
MAKE_DIR     := $(MAKEFILE_DIR)/.make

# cvmfs-bits source directory — override if your clone lives elsewhere.
BITS_DIR ?= $(MAKEFILE_DIR)/cvmfs-bits

# ── Runtime introspection helpers (used by verify-* recipes) ───────────────────
# Resolve the testbed data root: prefer TESTBED_ROOT from .env, else CURDIR.
# (verify-* use relative-looking repos/ and data/ paths; this makes them work
# regardless of where the data root actually lives.)
# The value is trimmed of surrounding whitespace, a trailing CR (a .env saved
# with CRLF endings) and optional surrounding quotes.  Without the trim, a
# trailing space in .env produced paths like "/home/u/cvmfs-testbed /repos/..."
# and every verify-* target failed with a confusing "No such file or directory".
GET_TESTBED_ROOT = r=$$(sed -n 's/^TESTBED_ROOT=//p' "$(MAKEFILE_DIR)/.env" 2>/dev/null | tail -1 \
	| tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$$//' -e 's/^"\(.*\)"$$/\1/' -e "s/^'\(.*\)'$$/\1/"); \
	echo "$${r:-$(MAKEFILE_DIR)}"

# Read one key from .env, applying the same trimming as GET_TESTBED_ROOT plus
# an inline-comment strip (check-env already needed that for S3_ENABLED).
# The '\#' escape is required: in a variable assignment an unescaped '#'
# starts a Make comment and silently truncates the pipeline.
# Three ad-hoc sed pipelines over one file is how they come to disagree about
# quoting.  Usage: v=$$($(call GET_ENV_VAR,REPO_NAME))
GET_ENV_VAR = sed -n 's/^$(1)=//p' "$(MAKEFILE_DIR)/.env" 2>/dev/null | tail -1 \
	| tr -d '\r' | sed -e 's/[[:space:]]\#.*$$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$$//' \
	                    -e 's/^"\(.*\)"$$/\1/' -e "s/^'\(.*\)'$$/\1/"

# "MIN AVG MAX" chunk sizes, read from config.yaml by testbed.sh (single source
# of truth) so verify-chunking never hard-codes them and can't report a false
# divergence when config.yaml changes.
GET_CHUNK_SIZES = bash "$(TESTBED)" chunksizes

# Number of jobs for stresstest targets.
N ?= 10

# Concurrency (max parallel active jobs) for the bits stresstest.
# Leave unset to use the script's built-in default (currently 2).
# Example: make stresstest N=100 C=20
C ?=
_CONCURRENCY := $(if $(C),--concurrency $(C),)

# The ADR-0001 pull distribution (embedded MQTT-over-WSS broker) is ON BY DEFAULT.
# Set WSS=0 to start the bare base stack.
#   make start          # pull overlay on (default)
#   make WSS=0 start     # bare stack, no pull overlay
WSS ?= 1
_WSS := $(if $(filter 0 no false,$(WSS)),--no-wss,)

# The CI user that runs producer-side steps (staged prepares run as this user,
# not as the testbed owner). Override: make RUNNER_USER=someone runner-perms
RUNNER_USER ?= gitlab-runner

# Publishing method (bits|ingest) passed to start/ensure for this invocation.
METHOD ?= bits
_METHOD := $(if $(METHOD),--method $(METHOD),)

# ── Default goal ──────────────────────────────────────────────────────────────
.DEFAULT_GOAL := all

.PHONY: all build install init start start-wss ensure bootstrap snapshot restore redeploy clean cleanall baseline \
        test test-suite test-ingest test-bits test-pull test-pull-wss pull-status \
        test-chunking test-content test-stress test-mkdirp test-idem test-check check \
        s3-on s3-off s3-status _s3-set check-env redeploy-prepub \
        runner-perms _grant-spool check-runner-access \
        stresstest stresstest-ingest \
        verify verify-chunking verify-content \
        catdump-ingest catdump-bits catdiff \
        help

# ── Sentinel directory ────────────────────────────────────────────────────────
$(MAKE_DIR):
	mkdir -p $(MAKE_DIR)

# ── all ───────────────────────────────────────────────────────────────────────
# Full pipeline: always rebuild bits + refresh software, then init → start →
# bootstrap only when their sentinels are absent.
all: install $(MAKE_DIR)/bootstrap

# ── build ─────────────────────────────────────────────────────────────────────
# Always runs: git pull + incremental make build inside cvmfs-bits.
# No sentinel — the cvmfs-bits build system handles incrementality itself
# (unchanged source compiles in seconds).
build:
	@if [[ ! -d "$(BITS_DIR)" ]]; then \
	    echo "ERROR: BITS_DIR not found: $(BITS_DIR)"; \
	    echo "  Clone cvmfs-bits there, or override: make BITS_DIR=/path/to/cvmfs-bits"; \
	    exit 1; \
	fi
	@echo "── Pulling latest cvmfs-bits ─────────────────────────────────────────"
	cd "$(BITS_DIR)" && git pull
	@echo "── Building cvmfs-bits ───────────────────────────────────────────────"
	cd "$(BITS_DIR)" && $(MAKE) build

# ── install ───────────────────────────────────────────────────────────────────
# Always runs: copies fresh binaries from both build trees into software/.
# Depends on build so bits is up to date before the copy.
install: build
	@echo "── Installing binaries into software/ ────────────────────────────────"
	BITS_DIR="$(BITS_DIR)" bash "$(INSTALL_SH)"

# ── init ──────────────────────────────────────────────────────────────────────
# Sentinel-protected: runs only once (or after make clean).
# Order-only dependency on $(MAKE_DIR) — the phony install target is NOT listed
# here so that the sentinel is not invalidated on every make all.  The all
# target sequences install before $(MAKE_DIR)/bootstrap which depends on this.
$(MAKE_DIR)/init: | $(MAKE_DIR)
	@echo "── Initialising testbed ──────────────────────────────────────────────"
	bash "$(TESTBED)" init
	@touch $@

init: $(MAKE_DIR)/init

# ── start ─────────────────────────────────────────────────────────────────────
# Not a sentinel target — containers can start/stop independently of make state.
# Depends on init having run.  auto-restores snapshot if repo is absent.
start: $(MAKE_DIR)/init
	@echo "── Starting testbed ──────────────────────────────────────────────────"
	bash "$(TESTBED)" start $(_WSS) $(_METHOD)
	@$(MAKE) --no-print-directory check-env

# Back-compat alias — the pull overlay is on by default, so this == start.
start-wss: start

# ── ensure ────────────────────────────────────────────────────────────────────
# Idempotent readiness gate: bring up whatever is missing (init, canonical
# payload, container stack, golden tree) so the test targets ALWAYS run from any
# starting state — fresh checkout, after `make clean`, stopped stack, or already
# running.  Fast and quiet on the happy path (every sub-step is checked first).
#
# This is the RUNTIME source of truth for "is the testbed ready" — it inspects
# live container/repo state, which the .make/init and .make/bootstrap file
# sentinels cannot (those can go stale after the stack stops or is cleaned).
# The test targets therefore depend on `ensure`, NOT on the sentinels.
#
# Starts the wss overlay so the pull-wss test can also run from any state.
#
# After a successful ensure, reconcile the make sentinels so a later plain
# `make` / `make bootstrap` sees init+bootstrap as already done (ensure has
# brought the live stack to that state).  Order-only dep on $(MAKE_DIR) so the
# directory exists before we touch into it.
ensure: | $(MAKE_DIR)
	bash "$(TESTBED)" ensure $(_WSS) $(_METHOD)
	@touch $(MAKE_DIR)/init $(MAKE_DIR)/bootstrap
	@$(MAKE) --no-print-directory check-env

# ── bootstrap ─────────────────────────────────────────────────────────────────
# Run once: seeds the nested-catalog structure required by cvmfs_server ingest,
# then creates repo-seed.tar.gz.  Re-run by deleting .make/bootstrap.
$(MAKE_DIR)/bootstrap: $(MAKE_DIR)/init
	@echo "── Starting testbed (bootstrap needs running containers) ─────────────"
	bash "$(TESTBED)" start
	@echo "── Bootstrapping repository ──────────────────────────────────────────"
	bash "$(TESTBED)" bootstrap
	@touch $@

bootstrap: $(MAKE_DIR)/bootstrap

# ── snapshot ──────────────────────────────────────────────────────────────────
# Save repo state manually (normally called automatically by bootstrap).
snapshot:
	bash "$(TESTBED)" snapshot

# ── restore ───────────────────────────────────────────────────────────────────
restore:
	bash "$(TESTBED)" restore

# ── s3-on / s3-off / s3-status ────────────────────────────────────────────────
# Turn the S3 CAPABILITY on or off. This does not choose a publish path.
#
#   s3-on   MinIO runs and /etc/cvmfs/<repo>.s3.conf exists, so any build MAY
#           ask for the direct-to-S3 path
#   s3-off  neither exists; a build asking for it fails
#
# Which path a publish actually takes is per build: prepub passes --direct-s3
# when the job carries direct_s3=true. That is why this is a capability rather
# than a mode — comparing the two paths means switching per build, not
# restarting the stack between measurements.
#
# Changing it recreates cvmfs-prepub (the entrypoint writes the config at
# container start) and starts or stops MinIO via COMPOSE_PROFILES.
#
# NOTE: objects from a direct_s3 build land in MinIO, not under repos/<repo>
# where stratum0 serves from, so a client cannot read them until the
# repository's data source is moved to MinIO too.
s3-on:
	@$(MAKE) --no-print-directory _s3-set S3_VALUE=1 S3_PROFILE=s3
s3-off:
	@$(MAKE) --no-print-directory _s3-set S3_VALUE=0 S3_PROFILE=

_s3-set:
	@if [[ ! -f "$(MAKEFILE_DIR)/.env.s3" ]]; then \
	    printf '[WARN] .env.s3 not found — run '"'"'make'"'"' to generate it.\n'; exit 1; \
	fi
	@# Refuse to enable with empty credentials. compose cannot enforce this: it
	@# interpolates the whole file before profiles are applied, so a required
	@# ${VAR:?} breaks every command for people who never use the variant.
	@# Enabling is the only moment where the check is both safe and meaningful —
	@# MinIO with unset credentials falls back to minioadmin/minioadmin on
	@# published ports.
	@if [ "$(S3_VALUE)" = "1" ]; then \
	    pw=$$(sed -n 's|^MINIO_ROOT_PASSWORD=||p' "$(MAKEFILE_DIR)/.env.s3"); \
	    us=$$(sed -n 's|^MINIO_ROOT_USER=||p' "$(MAKEFILE_DIR)/.env.s3"); \
	    if [ -z "$$pw" ] || [ -z "$$us" ]; then \
	        printf '[ERR] MINIO_ROOT_USER/MINIO_ROOT_PASSWORD are empty in .env.s3.\n'; \
	        printf '      MinIO would start on minioadmin/minioadmin, published on\n'; \
	        printf '      9000/9001. Set them (or delete .env.s3 and re-run make,\n'; \
	        printf '      which generates a random password) before enabling.\n'; \
	        exit 1; \
	    fi; \
	fi
	@set -e; f="$(MAKEFILE_DIR)/.env.s3"; \
	for kv in "S3_ENABLED=$(S3_VALUE)" "COMPOSE_PROFILES=$(S3_PROFILE)"; do \
	    k=$${kv%%=*}; \
	    if grep -q "^$$k=" "$$f"; then \
	        sed -i "s|^$$k=.*|$$kv|" "$$f"; \
	    else \
	        echo "$$kv" >> "$$f"; \
	    fi; \
	done
	@# COMPOSE_PROFILES is what actually starts MinIO: the services are behind
	@# `profiles: [s3]`, and testbed.sh passes .env.s3 as a second --env-file,
	@# from which compose reads COMPOSE_PROFILES. Verified: with it, `config
	@# --services` lists the gated services; without it, they do not exist.
	@echo "── S3_ENABLED=$(S3_VALUE) written to .env.s3 ─────────────────────────"
	@printf '\n'
	@printf 'Not applied yet. Environment is captured when the container is\n'
	@printf 'CREATED, so a restart keeps the old setting — the container must be\n'
	@printf 'recreated. Bring the testbed up the way you normally do, e.g.\n'
	@printf '\n'
	@printf '    make start          (or: make ensure)\n'
	@printf '\n'
	@printf 'Then  make redeploy-prepub  to recreate prepub with the new value\n'
	@printf '(make ensure will NOT recreate a healthy container), and\n'
	@printf 'make check-env  to confirm it agrees with the file.\n'
	@printf '\n'
	@$(MAKE) --no-print-directory s3-status

# Report the switch AND what the container actually has, so a stale container
# (flag changed, never recreated) is visible rather than assumed correct.
s3-status:
	@printf '.env.s3     : %s\n' "$$(grep '^S3_ENABLED=' "$(MAKEFILE_DIR)/.env.s3" 2>/dev/null || echo '<no .env.s3>')"
	@printf 'container   : S3_ENABLED=%s\n' \
	    "$$(docker exec cvmfs-prepub sh -c 'echo $${S3_ENABLED:-<unset>}' 2>/dev/null || echo '<not running>')"
	@# Report the file cvmfs_server will ACTUALLY read, which is the path in
	@# CVMFS_INGEST_DIRECT_S3_CONFIG when set and only otherwise the conventional
	@# /etc/cvmfs/<repo>.s3.conf.  Globbing the conventional path alone reports a
	@# stale per-container copy as healthy while direct_s3 publishes abort, and
	@# reports the shared provisioned config as "absent" when it is working.
	@printf 'S3 config   : %s\n' \
	    "$$(docker exec cvmfs-prepub sh -c 'p=$${CVMFS_INGEST_DIRECT_S3_CONFIG:-/etc/cvmfs/'"$$(grep -m1 "^REPO_NAME=" "$(MAKEFILE_DIR)/.env" | cut -d= -f2- | tr -d " \r")"'.s3.conf}; if [ -r "$$p" ]; then echo "$$p (readable)"; elif [ -e "$$p" ]; then echo "$$p (EXISTS BUT UNREADABLE)"; else echo "$$p (absent — direct_s3 builds will fail)"; fi' 2>/dev/null || echo '<not running>')"
	@printf 'minio       : %s\n' "$$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c '^cvmfs-minio$$' | sed 's/^0$$/not running/; s/^1$$/running/')"
	@printf 'path choice : per build (job field direct_s3), not set here\n' 

# ── runner-perms ──────────────────────────────────────────────────────────────
# Make the testbed reachable by the CI runner that runs producer-side steps
# (the staged publish path prepares with `bits cvmfs-stage` AS THE RUNNER, not
# as the testbed owner).
#
# NOT the same thing as `./testbed fix-perms`, which repairs REPOSITORY TREE
# ownership so the containers can write. Different problem, different fix.
#
# Two distinct things have to be true, and only one survives a re-init:
#
#   1. the runner can WRITE the publisher spool -- init.sh does this via
#      SPOOL_SHARED_GROUP (chgrp + setgid + a default ACL), re-applied here so
#      a spool recreated by mkfs is repaired without a full init;
#   2. the runner can TRAVERSE to the testbed root -- and $$HOME is 0750 on a
#      stock Ubuntu account, so it cannot.
#
# A staged run that hits (2) dies in the first package's prepare, before any
# job reaches the prepub, so it leaves no measurement record and no service-log
# entry -- the failure that cost a run on 2026-08-15.
#
# Traversal is granted with a per-user ACL, NOT chmod o+x: this host also runs
# CI for other projects, and o+x on a home directory opens it to every uid on
# the box. `setfacl -m u:<runner>:x` names one user and grants search only.
# Two caveats, neither hidden: setfacl RECALCULATES the ACL mask, so on a
# directory that already carries other named entries this can widen THEIR
# effective rights -- the walk prints the exact `setfacl -x` line for each
# grant so it can be undone, and skips directories that already work.
#
# The walk goes TOP-DOWN and re-probes the target after each grant: `test -x`
# on a deep path fails when any ancestor blocks, so a bottom-up walk grants an
# ACL to every directory below the real blocker. Top-down touches the blocker
# and stops. Component splitting is done with ${} rather than a word-split
# list so a path containing spaces still works.
#
# Deliberately split across three recipe lines. A recipe line containing
# $(MAKE) is executed even under `make -n`, so the setfacl walk MUST NOT share
# a line with a sub-make, or a dry run would apply the grants for real.
runner-perms:
	@set -u; \
	runner="$(RUNNER_USER)"; \
	if ! id -u "$$runner" >/dev/null 2>&1; then \
	    printf '[runner-perms] no such user %s - set RUNNER_USER=<user> if the CI runs as someone else.\n' "$$runner"; \
	    exit 0; \
	fi; \
	if ! sudo -n -u "$$runner" true 2>/dev/null; then \
	    printf '[runner-perms] cannot run commands as %s: no passwordless sudo, or no\n' "$$runner"; \
	    printf '                sudoers rule permitting -u %s (running as root is a\n' "$$runner"; \
	    printf '                different privilege). Without it every probe fails the same\n'; \
	    printf '                way as a real permission problem, and this would grant ACLs\n'; \
	    printf '                on directories that do not need them. Refusing.\n'; \
	    exit 1; \
	fi; \
	grp=$$($(call GET_ENV_VAR,SPOOL_SHARED_GROUP)); \
	repo=$$($(call GET_ENV_VAR,REPO_NAME)); \
	if [ -z "$$repo" ]; then \
	    printf '[runner-perms] REPO_NAME is not set in .env - skipping the spool grant.\n'; \
	elif ! printf '%s' "$$repo" | grep -qE '^[A-Za-z0-9._-]+$$'; then \
	    printf '[runner-perms] REPO_NAME=%s is not a plain repository name - refusing to\n' "$$repo"; \
	    printf '                interpolate it into a privileged command.\n'; \
	    exit 1; \
	elif [ -z "$$grp" ]; then \
	    printf '[runner-perms] SPOOL_SHARED_GROUP is not set in .env - skipping the spool grant.\n'; \
	elif ! getent group "$$grp" >/dev/null 2>&1; then \
	    printf '[runner-perms] group %s does not exist on this host - skipping the spool grant.\n' "$$grp"; \
	else \
	    $(MAKE) --no-print-directory _grant-spool GRP="$$grp" REPO="$$repo"; \
	fi
	@set -u; \
	runner="$(RUNNER_USER)"; \
	id -u "$$runner" >/dev/null 2>&1 || exit 0; \
	root=$$($(GET_TESTBED_ROOT)); \
	root=$$(cd "$$root" 2>/dev/null && pwd -P) || { \
	    printf '[runner-perms] TESTBED_ROOT does not resolve to a directory - fix .env first.\n'; \
	    exit 1; }; \
	printf '[runner-perms] runner=%s  testbed=%s\n' "$$runner" "$$root"; \
	command -v setfacl >/dev/null 2>&1 || { \
	    printf '[runner-perms] setfacl not found - install the acl package.\n'; exit 1; }; \
	d=""; rest="$${root#/}"; \
	while [ -n "$$rest" ]; do \
	    comp="$${rest%%/*}"; d="$$d/$$comp"; \
	    case "$$rest" in */*) rest="$${rest#*/}";; *) rest="";; esac; \
	    sudo -n -u "$$runner" test -x "$$root" 2>/dev/null && break; \
	    sudo -n -u "$$runner" test -x "$$d" 2>/dev/null && continue; \
	    printf '[runner-perms] granting %s search access to %s\n' "$$runner" "$$d"; \
	    if sudo -n setfacl -m "u:$$runner:x" "$$d"; then \
	        printf '[runner-perms]   undo with: sudo setfacl -x u:%s %s\n' "$$runner" "$$d"; \
	    else \
	        printf '[runner-perms] WARNING: setfacl failed on %s (no ACL support on this fs?)\n' "$$d"; \
	    fi; \
	done
	@$(MAKE) --no-print-directory check-runner-access

# Re-apply init.sh's SPOOL_SHARED_GROUP grant to the paths the producer writes.
# Deliberately NOT a blanket recursion over <spool>/<repo>: that contains
# rdonly, the read-only CVMFS mount, where a recursive chmod returns EROFS for
# every published file.
#
# The three paths, from bits/bits_helpers/cvmfs_stage*.py: tmp/ (per-invocation
# scratch and the prepare lock), scratch/, and stats.db in the spool ROOT --
# which every prepare writes unless swissknife is given -n. Missing the last
# one made the "repair without a full init" case fail on the statistics DB.
#
# Steps are ';'-separated, not '&&'-chained: one failure must not skip setgid.
_grant-spool:
	@set -u; \
	[ -n "$(REPO)" ] && [ -n "$(GRP)" ] || { \
	    printf '[runner-perms] _grant-spool needs REPO= and GRP= - refusing.\n'; exit 1; }; \
	spool="/var/spool/cvmfs/$(REPO)"; \
	[ -d "$$spool" ] || { printf '[runner-perms] %s does not exist - skipping.\n' "$$spool"; exit 0; }; \
	printf '[runner-perms] re-applying the %s grant under %s\n' "$(GRP)" "$$spool"; \
	sudo -n chgrp "$(GRP)" "$$spool" \
	  || printf '[runner-perms] WARNING: chgrp failed on %s\n' "$$spool"; \
	sudo -n chmod g+rwxs "$$spool" \
	  || printf '[runner-perms] WARNING: chmod failed on %s\n' "$$spool"; \
	if [ -e "$$spool/stats.db" ]; then \
	    sudo -n chgrp "$(GRP)" "$$spool/stats.db" || true; \
	    sudo -n chmod g+rw "$$spool/stats.db" \
	      || printf '[runner-perms] WARNING: chmod failed on stats.db\n'; \
	fi; \
	for sub in tmp scratch; do \
	    [ -d "$$spool/$$sub" ] || continue; \
	    sudo -n chgrp -R "$(GRP)" "$$spool/$$sub" \
	      || printf '[runner-perms] WARNING: chgrp failed on %s\n' "$$spool/$$sub"; \
	    sudo -n chmod -R g+rwX "$$spool/$$sub" \
	      || printf '[runner-perms] WARNING: chmod failed on %s\n' "$$spool/$$sub"; \
	    sudo -n find "$$spool/$$sub" -xdev -type d -exec chmod g+s {} + \
	      || printf '[runner-perms] WARNING: setgid failed on %s\n' "$$spool/$$sub"; \
	    if command -v setfacl >/dev/null 2>&1; then \
	        sudo -n setfacl -R -m "g:$(GRP):rwx" "$$spool/$$sub" || true; \
	        sudo -n setfacl -R -d -m "g:$(GRP):rwx" "$$spool/$$sub" || true; \
	    else \
	        printf '[runner-perms] setfacl not found - group grant without ACLs.\n'; \
	    fi; \
	done

# ── check-runner-access ───────────────────────────────────────────────────────
# Verify, as the runner itself, what a producer-side publish needs. Read-only.
# Exits non-zero so `make runner-perms` fails when it did not work; callers that
# treat it as advisory pass ADVISORY=1.
check-runner-access:
	@set -u; \
	runner="$(RUNNER_USER)"; \
	if ! id -u "$$runner" >/dev/null 2>&1; then \
	    printf '[runner-access] no user %s on this host - producer-side access NOT checked.\n' "$$runner"; \
	    exit 0; \
	fi; \
	if ! sudo -n -u "$$runner" true 2>/dev/null; then \
	    printf '[runner-access] cannot probe as %s (no passwordless sudo) - NOT verified.\n' "$$runner"; \
	    exit 0; \
	fi; \
	root=$$($(GET_TESTBED_ROOT)); \
	root=$$(cd "$$root" 2>/dev/null && pwd -P) || root=$$($(GET_TESTBED_ROOT)); \
	repo=$$($(call GET_ENV_VAR,REPO_NAME)); \
	_bad=0; \
	if sudo -n -u "$$runner" test -x "$$root" 2>/dev/null; then \
	    printf '[runner-access] %s can reach %s\n' "$$runner" "$$root"; \
	else \
	    printf '[runner-access] %s CANNOT reach %s - a staged publish dies in the\n' "$$runner" "$$root"; \
	    printf '                first prepare, before any job reaches the prepub.  Fix: make runner-perms\n'; \
	    _bad=1; \
	fi; \
	spool="/var/spool/cvmfs/$$repo"; \
	if [ -n "$$repo" ] && [ -d "$$spool" ]; then \
	    for t in "$$spool" "$$spool/tmp"; do \
	        [ -d "$$t" ] || continue; \
	        if sudo -n -u "$$runner" test -w "$$t"; then \
	            printf '[runner-access] %s can write %s\n' "$$runner" "$$t"; \
	        else \
	            printf '[runner-access] %s CANNOT write %s - Fix: make runner-perms\n' "$$runner" "$$t"; \
	            _bad=1; \
	        fi; \
	    done; \
	fi; \
	if [ -n "$(ADVISORY)" ]; then exit 0; fi; \
	exit $$_bad

# ── check-env ─────────────────────────────────────────────────────────────────
# Refuse to proceed when the RUNNING containers disagree with the files on
# disk.  The drift this catches is not theoretical: a container recreated with
# a hand-typed `docker compose` reads only .env, so prepub came up with
# S3_ENABLED=0 while .env.s3 said 1 — and the next 170-package publish died on
# "Direct-to-S3 upload requested but S3 config does not exist".  `make
# s3-status` showed the mismatch all along; nothing was looking at it.
#
# Silent-pass when nothing is running (a stopped testbed cannot drift) or when
# .env.s3 is absent (the S3 variant is genuinely optional).
check-env:
	@$(MAKE) --no-print-directory ADVISORY=1 check-runner-access
	@_fail=0; \
	if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^cvmfs-prepub$$'; then \
	    printf '[check-env] cvmfs-prepub is not running - nothing to check.\n'; \
	    exit 0; \
	fi; \
	if [ ! -f "$(MAKEFILE_DIR)/.env.s3" ]; then \
	    printf '[check-env] no .env.s3 - S3 variant not configured, skipping.\n'; \
	    exit 0; \
	fi; \
	want=$$(sed -n 's|^S3_ENABLED=||p' "$(MAKEFILE_DIR)/.env.s3" | tail -1 \
	    | tr -d '\r' | sed -e 's/[[:space:]]#.*$$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$$//' \
	                       -e 's/^"\(.*\)"$$/\1/' -e "s/^'\(.*\)'$$/\1/"); \
	want=$${want:-0}; \
	if ! have=$$(docker exec cvmfs-prepub sh -c 'echo $${S3_ENABLED:-<unset>}' 2>/dev/null); then \
	    printf '[check-env] WARNING: cannot exec into cvmfs-prepub (restarting or\n'; \
	    printf '            unhealthy?) - environment NOT verified. Diagnose with:\n'; \
	    printf '                docker logs cvmfs-prepub; make status\n'; \
	    exit 0; \
	fi; \
	if [ "$$want" != "$$have" ]; then \
	    printf '[check-env] DRIFT: .env.s3 says S3_ENABLED=%s, cvmfs-prepub is running with %s.\n' "$$want" "$$have"; \
	    printf '            The container was created without .env.s3 - a hand-typed\n'; \
	    printf '            "docker compose" reads only .env.  Recreate it properly:\n'; \
	    printf '                make redeploy-prepub\n'; \
	    _fail=1; \
	fi; \
	if [ "$$want" = "1" ]; then \
	    cfg=$$(docker exec cvmfs-prepub sh -c 'echo $${CVMFS_INGEST_DIRECT_S3_CONFIG:-}' 2>/dev/null || echo ''); \
	    if [ -z "$$cfg" ]; then \
	        printf '[check-env] DRIFT: S3 enabled but CVMFS_INGEST_DIRECT_S3_CONFIG is unset in the\n'; \
	        printf '            container, so a direct_s3 build looks for /etc/cvmfs/<repo>.s3.conf\n'; \
	        printf '            and aborts.  Recreate: make redeploy-prepub\n'; \
	        _fail=1; \
	    elif ! docker exec cvmfs-prepub test -r "$$cfg" 2>/dev/null; then \
	        printf '[check-env] DRIFT: S3 config %s is not readable in the container.\n' "$$cfg"; \
	        _fail=1; \
	    fi; \
	fi; \
	if [ $$_fail -eq 0 ]; then \
	    printf '[check-env] cvmfs-prepub environment matches .env.s3.\n'; \
	fi; \
	exit $$_fail

# ── redeploy-prepub ───────────────────────────────────────────────────────────
# Recreate the prepub container through the testbed's own compose wrapper, so
# .env AND .env.s3 both apply. With the pull-wss overlay prepub depends_on
# gateway and stratum0, so those enter the target set (and are recreated only
# if their own config changed); on the base stack it has no dependencies and
# nothing else is touched. The published repository is a bind mount either way.
#
# This is the supported way to pick up a changed flag or env value without
# touching the published repository: a full 'make redeploy' re-inits and wipes
# it, and a hand-typed docker compose silently drops .env.s3.
#
# Deliberately does NOT depend on 'install': recreating a container to pick up
# an env change should not also git-pull and rebuild cvmfs-bits.  To deploy a
# NEW BINARY, ask for both:  make install redeploy-prepub
redeploy-prepub:
	@echo "── Recreating cvmfs-prepub (repository state untouched) ──────────────"
	bash "$(TESTBED)" compose $(_WSS) up -d cvmfs-prepub
	@sleep 2
	@$(MAKE) --no-print-directory check-env

# ── redeploy ──────────────────────────────────────────────────────────────────
# Full rebuild: wipe sentinels + state, then run the full pipeline from scratch.
redeploy: install
	@if [[ ! -f "$(MAKE_DIR)/init" ]]; then \
	    printf '\n'; \
	    printf '[WARN] testbed is not initialised — $(MAKE_DIR)/init not found.\n'; \
	    printf '       Run '"'"'make'"'"' instead to do a clean first-time setup.\n'; \
	    printf '\n'; \
	    exit 1; \
	fi
	@echo "── Stopping testbed ──────────────────────────────────────────────────"
	-bash "$(TESTBED)" stop
	@echo "── Full reset (wipes snapshot too) ───────────────────────────────────"
	bash "$(TESTBED)" clean --yes --purge-snapshot
	rm -f $(MAKE_DIR)/init $(MAKE_DIR)/bootstrap
	@echo "── Initialising testbed ──────────────────────────────────────────────"
	bash "$(TESTBED)" init && touch $(MAKE_DIR)/init
	@echo "── Starting testbed ──────────────────────────────────────────────────"
	bash "$(TESTBED)" start
	@echo "── Bootstrapping ─────────────────────────────────────────────────────"
	bash "$(TESTBED)" bootstrap && touch $(MAKE_DIR)/bootstrap

# ── clean ─────────────────────────────────────────────────────────────────────
# Stop containers and remove runtime state.  Snapshot and .env are PRESERVED so
# services can restart with the same credentials on the next 'make start'.
# Wipe .make/init and .make/bootstrap so make knows to re-run them next time.
#
# Guard: refuse to run if the testbed has never been initialised.  Without this
# guard, docker compose expands unset ${TESTBED_ROOT} volume paths to wrong
# host paths, creating root-owned placeholder directories that overwrite files
# in the repo tree.
clean:
	@if [[ ! -f "$(MAKE_DIR)/init" ]]; then \
	    printf '\n'; \
	    printf '[WARN] testbed is not initialised — $(MAKE_DIR)/init not found.\n'; \
	    printf '       Nothing to clean.  Run '"'"'make'"'"' first to set up the testbed.\n'; \
	    printf '\n'; \
	else \
	    echo "── Stopping testbed ──────────────────────────────────────────────────"; \
	    bash "$(TESTBED)" stop || true; \
	    echo "── Cleaning testbed state ────────────────────────────────────────────"; \
	    bash "$(TESTBED)" clean --yes; \
	    rm -f $(MAKE_DIR)/init $(MAKE_DIR)/bootstrap; \
	fi

# ── cleanall ──────────────────────────────────────────────────────────────────
# Like clean, but also deletes .env — full credential reset.
# Use this when you want to regenerate secrets (gateway key, API token, etc.).
# The next 'make' will run init from scratch and create a fresh .env.
cleanall:
	@if [[ ! -f "$(MAKE_DIR)/init" ]]; then \
	    printf '\n'; \
	    printf '[WARN] testbed is not initialised — $(MAKE_DIR)/init not found.\n'; \
	    printf '       Nothing to clean.  Run '"'"'make'"'"' first to set up the testbed.\n'; \
	    printf '\n'; \
	else \
	    echo "── Stopping testbed ──────────────────────────────────────────────────"; \
	    bash "$(TESTBED)" stop || true; \
	    echo "── Cleaning testbed state (including .env) ───────────────────────────"; \
	    bash "$(TESTBED)" clean --yes --purge-snapshot --purge-env; \
	    rm -f $(MAKE_DIR)/init $(MAKE_DIR)/bootstrap; \
	fi

# ── test targets ──────────────────────────────────────────────────────────────
# `make test` runs the FULL selectable suite (all six tests incl. stress N=10),
# recording per-test metrics to data/test-results.ndjson and live progress to
# data/test-suite-status.json.  Select a subset with TESTS:
#   make test                              # all six
#   make test TESTS="bits chunking content"
# TESTS is passed straight through to `testbed.sh suite`.
test: | ensure
	bash "$(TESTBED)" suite $(TESTS)

# Native-ingest REFERENCE BASELINE (golden/smoke). bits is the default/monitored
# path; this slow, occasional native reference feeds the content/ingest tests and
# the bits-vs-ingest comparison. Captured in the snapshot. Run once after setup.
baseline: | ensure
	bash "$(TESTBED)" baseline

# Individual smoke targets delegate to the suite so they ALSO log a
# test-results.ndjson record (keeping history complete).
test-ingest: | ensure
	bash "$(TESTBED)" suite ingest

test-bits: | ensure
	bash "$(TESTBED)" suite bits

# End-to-end pull test over the embedded MQTT-over-WSS control plane (no mosquitto).
# Requires the wss stack: run `make start-wss` (or `make WSS=1 start`) first.
test-pull-wss: | ensure
	bash "$(TESTBED)" suite pull-wss

# Convenience alias: pull distribution is now wss-only.
test-pull: test-pull-wss

# Monitoring: dump pull-relevant log lines from publisher + receivers.
pull-status:
	bash "$(TESTBED)" pullstatus --wss

# ── stresstest targets ────────────────────────────────────────────────────────
# Direct stress run (raw, N/C configurable, no test-results record).
stresstest: | ensure
	bash "$(TESTBED)" stresstest $(N) $(_CONCURRENCY) --method bits

# Suite-wrapped stress (fixed N=10) — logs a test-results.ndjson record.
test-stress: | ensure
	bash "$(TESTBED)" suite stress

# Gated receiver feature: publishing into a lease path whose ancestors do not
# exist must succeed with CVMFS_GW_MKDIR_PARENTS on and still be refused with it
# off.  The OFF half is the one that keeps the upstream change honest.
test-mkdirp: | ensure
	bash "$(TESTBED)" suite mkdirp

# Can two packages share a parent prefix?  That is what a multi-package build
# does, and the ingest path cannot currently do it: the second publish aborts
# the publisher with a duplicate INSERT.  Reports the -c matrix.
test-idem: | ensure
	bash "$(TESTBED)" suite idem

# Whole-repository consistency gate: cvmfs_swissknife check -c walks every
# catalog from the signed manifest AND verifies every referenced data object is
# retrievable.  Catches objects stored under the wrong key (e.g. a chunk missing
# its 'P' suffix) — internally consistent catalogs, unreadable files.
test-check: | ensure
	bash "$(TESTBED)" suite check

# Same check, unwrapped: prints swissknife's own output, records no metrics.
check: | ensure
	bash "$(TESTBED)" check

stresstest-ingest: | ensure
	bash "$(TESTBED)" stresstest $(N) --method ingest

# ── catalog comparison ────────────────────────────────────────────────────────
catdump-ingest:
	bash "$(TESTBED)" catdump ingest

catdump-bits:
	bash "$(TESTBED)" catdump bits

catdiff:
	bash "$(TESTBED)" catdiff ingest bits

# ── help ──────────────────────────────────────────────────────────────────────
help:
	@echo ""
	@echo "cvmfs-testbed Makefile"
	@echo ""
	@echo "  make                      Full pipeline (build→install→init→start→bootstrap)"
	@echo "  make build                git pull + compile cvmfs-bits"
	@echo "  make install              build + copy binaries to software/"
	@echo "  make init                 One-time testbed initialisation"
	@echo "  make start                Start containers (auto-restores snapshot)"
	@echo "  make ensure               Make the testbed ready (init+payload+start+golden), idempotent"
	@echo "  make bootstrap            Seed nested catalog + create snapshot (once)"
	@echo "  make snapshot             Save repo state to repo-seed.tar.gz"
	@echo "  make restore              Restore repo state from repo-seed.tar.gz"
	@echo "  make redeploy             Full rebuild from scratch (re-inits: WIPES the repository)"
	@echo "  make redeploy-prepub      Recreate ONLY prepub (repository untouched; add 'install' to rebuild)"
	@echo "  make check-env            Verify the running prepub matches .env.s3"
	@echo "  make runner-perms         Let the CI runner reach the testbed + spool (staged path)"
	@echo "  make check-runner-access  Check that access, read-only (no changes)"
	@echo "  make clean                Stop + wipe state (keeps snapshot and .env)"
	@echo "  make cleanall             Stop + wipe state + delete .env (fresh credentials)"
	@echo ""
	@echo "  Never run 'docker compose' by hand: it reads .env but NOT .env.s3, so a"
	@echo "  container recreated that way comes up with S3 disabled. Use"
	@echo "  'make redeploy-prepub', or './testbed compose <args>' for anything else."
	@echo ""
	@echo "  All test/verify/stress targets auto-run 'ensure' first, so they work"
	@echo "  from ANY state (fresh checkout, after 'make clean', stopped or running)."
	@echo ""
	@echo "  make test                 FULL test suite — all seven tests (records metrics)"
	@echo "  make test TESTS=\"bits chunking content\"   Run a selected subset"
	@echo "  make test-suite           Alias of 'make test' (honors TESTS=)"
	@echo "  make test-ingest          Suite: native ingest into golden/smoke (auto-ensure; skips if no golden)"
	@echo "  make test-bits            Suite: cvmfs-prepub REST API smoke"
	@echo "  make test-chunking        Suite: bits publish + xor32 chunk verify"
	@echo "  make test-content         Suite: compare-trees vs golden/smoke"
	@echo "  make test-stress          Suite: stress N=10 (bits)"
	@echo "  make test-check           Suite: swissknife check -c (catalogs + objects)"
	@echo "  make check                Same check, raw output"
	@echo "  make test-pull-wss        Suite: end-to-end pull over embedded wss (auto-ensure --wss; skips if not up)"
	@echo "  make test-pull            Alias of test-pull-wss"
	@echo "  make pull-status          Dump pull-relevant publisher/receiver logs"
	@echo ""
	@echo "  Suite tests (names for TESTS=): bits ingest pull-wss chunking content stress check"
	@echo "  Results: data/test-results.ndjson  ·  Live status: data/test-suite-status.json"
	@echo ""
	@echo "  make stresstest [N=10]    Stress test, N jobs (bits)"
	@echo "  make stresstest-ingest    Stress test (ingest path)"
	@echo ""
	@echo "  make start-wss            Start testbed with embedded MQTT-over-WSS broker (ADR-0001)"
	@echo "  make WSS=1 <target>       Enable embedded MQTT-over-WSS overlay for any target"
	@echo ""
	@echo "  make catdump-ingest       Dump catalogs after ingest test"
	@echo "  make catdump-bits         Dump catalogs after bits test"
	@echo "  make catdiff              Diff ingest vs bits catalog dumps"
	@echo ""
	@echo "  Sentinels in .make/ track completed steps."
	@echo "  Delete a sentinel to force that step to rerun:"
	@echo "    rm .make/bootstrap && make bootstrap"
	@echo "    rm -rf .make       && make           # full rebuild"
	@echo ""
	@echo "  Variables:"
	@echo "    BITS_DIR  = $(BITS_DIR)"
	@echo "    N         = $(N)  (jobs for stresstest)"
	@echo "    C         = $(if $(C),$(C),(unset = script default of 2))  (concurrency for stresstest)"
	@echo ""
	@echo "  Examples:"
	@echo "    make stresstest N=50           # 50 jobs, default concurrency"
	@echo "    make stresstest N=100 C=20     # 100 jobs, 20 at a time"
	@echo ""
	@echo "  Full comparison workflow:"
	@echo "    make test-ingest catdump-ingest test-bits catdump-bits catdiff"
	@echo ""

# verify-chunking — publish via bits at the configured chunk sizes, then verify
# the published catalog's chunk boundaries match CVMFS's xor32 content-defined
# chunker (cvmfs/ingestion/chunk_detector.cc) exactly. CVMFS's tarball ingest
# path does not chunk, so the oracle is the algorithm itself (reproduced in
# scripts/cvmfs-chunk-reference.py).
#
# Chunk sizes are READ from config.yaml (no longer hard-coded) so they cannot
# drift out of sync and report a false divergence.  TESTBED_ROOT is resolved
# from .env (falling back to CURDIR) so the relative repos/ and data/ paths work
# even when the testbed data root is not the repo checkout.
verify-chunking: | ensure
	bash "$(TESTBED)" test --method bits
	@root=$$($(GET_TESTBED_ROOT)); \
	sizes=$$($(GET_CHUNK_SIZES)); \
	r=$$(basename $$(dirname $$(ls "$$root"/repos/*/.cvmfspublished | head -1))); \
	python3 scripts/verify-chunking.py "$$root/repos/$$r" "$$root/data/payload/payload.tar" $$sizes

# verify-content — directly compare the latest bits publish to the native
# cvmfs_server-ingest golden (golden/smoke) for byte-identical decompressed
# content (compressor/chunking-independent). Reports metadata diffs as warnings.
verify-content: | ensure
	@root=$$($(GET_TESTBED_ROOT)); \
	r=$$(basename $$(dirname $$(ls "$$root"/repos/*/.cvmfspublished | head -1))); \
	a=$$(CAS="$$root/repos/$$r" python3 -c "import zlib,sqlite3,os,tempfile;cas=os.environ['CAS'];root=[l[1:].strip().decode() for l in open(cas+'/.cvmfspublished','rb') if l[:1]==b'C'][0];raw=zlib.decompress(open(cas+'/data/'+root[:2]+'/'+root[2:]+'C','rb').read());fd,t=tempfile.mkstemp();os.write(fd,raw);os.close(fd);print(sorted([p for (p,h) in sqlite3.connect(t).execute('select path,sha1 from nested_catalogs') if '/test/smoke.' in p])[-1])"); \
	python3 scripts/compare-trees.py "$$root/repos/$$r" "$$a" /golden/smoke

# verify — full bits-reproduces-CVMFS check: chunk boundaries + content.
verify: verify-chunking verify-content

# Suite-wrapped chunking / content checks — these log a test-results.ndjson
# record (unlike the raw verify-chunking / verify-content targets above).
test-chunking: | ensure
	bash "$(TESTBED)" suite chunking

test-content: | ensure
	bash "$(TESTBED)" suite content

# Full suite — explicit alias for `make test` with all six tests.
test-suite: | ensure
	bash "$(TESTBED)" suite $(TESTS)
