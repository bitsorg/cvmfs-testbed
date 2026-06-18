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
#   make bootstrap     Run privileged bootstrap container, create snapshot
#   make snapshot      Save repo state to repo-seed.tar.gz (called by bootstrap)
#   make restore       Restore repo state from repo-seed.tar.gz
#   make redeploy      install + full reset + bootstrap
#   make clean         Stop containers and wipe all testbed state (keeps snapshot and .env)
#   make cleanall      Like clean, but also deletes .env (full credential reset)
#   make test          Smoke test — bits method (default)
#   make test-ingest   Smoke test — cvmfs_server ingest path (needs bootstrap)
#   make test-bits     Smoke test — cvmfs-prepub REST API path
#   make stresstest    Stress test — bits method, N jobs (default N=10)
#   make stresstest-ingest  Stress test — ingest path
#   make catdiff       Diff catalog dumps: ingest vs bits
#   make help          Print this summary
#
# Variables (override on the command line or in the environment):
#   BITS_DIR      Path to the cvmfs-bits source tree.
#                 Default: $(CURDIR)/cvmfs-bits
#                 Example: make BITS_DIR=/home/user/src/cvmfs-bits
#   TESTBED_ROOT  Path to testbed data root (default: $HOME/cvmfs-testbed).
#                 Used to locate repo-seed.tar.gz for the bootstrap target.
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

# Number of jobs for stresstest targets.
N ?= 10

# Concurrency (max parallel active jobs) for the bits stresstest.
# Leave unset to use the script's built-in default (currently 2).
# Example: make stresstest N=100 C=20
C ?=
_CONCURRENCY := $(if $(C),--concurrency $(C),)

# Set MQTT=1 to start the Mosquitto broker and enable the MQTT control-plane
# for all relevant targets.  Example:
#   make MQTT=1 start          # start testbed with MQTT overlay
#   make MQTT=1 test           # smoke test via MQTT path
#   make MQTT=1 stresstest N=20
#   make start-mqtt            # convenience alias (same as MQTT=1 start)
MQTT ?= 0
_MQTT := $(if $(filter 1 yes true,$(MQTT)),--mqtt,)

# Set PULL=1 to enable the ADR-0001 pull-based distribution overlay (implies
# MQTT — receivers pull objects from Stratum 0 when notified instead of being
# pushed to).  Example:
#   make PULL=1 start          # start testbed with pull + MQTT overlays
#   make start-pull            # convenience alias (same as PULL=1 start)
#   make test-pull             # end-to-end pull test
PULL ?= 0
_PULL := $(if $(filter 1 yes true,$(PULL)),--pull,)

# Set WSS=1 to enable the ADR-0001 pull distribution over the embedded
# MQTT-over-WSS broker (no mosquitto).  Mirrors MQTT=/PULL=.  Example:
#   make WSS=1 start           # start testbed with the embedded-broker overlay
#   make start-wss             # convenience alias (same as WSS=1 start)
#   make test-pull-wss         # end-to-end pull test over wss
WSS ?= 0
_WSS := $(if $(filter 1 yes true,$(WSS)),--wss,)

# SCENARIO selects a named distribution preset (push|mqtt|pull|ingest) in one
# word, instead of setting MQTT=/PULL=/method individually.  Examples:
#   make scenario SCENARIO=pull     # start + smoke test the pull scenario
#   make scenario-pull              # convenience alias
#   make start SCENARIO=mqtt        # just start in the mqtt scenario
SCENARIO ?=
_SCENARIO := $(if $(SCENARIO),--scenario $(SCENARIO),)

# ── Default goal ──────────────────────────────────────────────────────────────
.DEFAULT_GOAL := all

.PHONY: all build install init start start-mqtt start-pull start-wss bootstrap snapshot restore redeploy clean cleanall \
        test test-ingest test-bits test-mqtt test-pull test-pull-wss pull-status \
        scenario scenario-push scenario-mqtt scenario-pull scenario-ingest \
        stresstest stresstest-ingest stresstest-mqtt stresstest-pull \
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
	bash "$(TESTBED)" start $(_MQTT) $(_PULL) $(_WSS) $(_SCENARIO)

start-mqtt: $(MAKE_DIR)/init
	@echo "── Starting testbed with MQTT overlay ────────────────────────────────"
	bash "$(TESTBED)" start --mqtt

start-pull: $(MAKE_DIR)/init
	@echo "── Starting testbed with pull + MQTT overlays ────────────────────────"
	bash "$(TESTBED)" start --pull

start-wss: $(MAKE_DIR)/init
	@echo "── Starting testbed with the embedded MQTT-over-WSS broker overlay ────"
	bash "$(TESTBED)" start --wss

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
test:
	bash "$(TESTBED)" test --method bits $(_MQTT)

# test-ingest requires the bootstrap to have run (nested catalog in snapshot).
test-ingest: $(MAKE_DIR)/bootstrap
	bash "$(TESTBED)" test --method ingest $(_MQTT)

test-bits:
	bash "$(TESTBED)" test --method bits $(_MQTT)

# Requires the MQTT stack: run `make start-mqtt` (or `make MQTT=1 start`) first.
test-mqtt:
	bash "$(TESTBED)" mqtttest --mqtt

# End-to-end pull test: publish one job and verify both Stratum 1 receivers
# pulled the new objects from Stratum 0 themselves (ADR-0001).
# Requires the pull stack: run `make start-pull` (or `make PULL=1 start`) first.
test-pull:
	bash "$(TESTBED)" pulltest --pull --method bits

# End-to-end pull test over the embedded MQTT-over-WSS control plane (no mosquitto).
# Requires the wss stack: run `make start-wss` (or `make WSS=1 start`) first.
test-pull-wss:
	bash "$(TESTBED)" pulltest --wss --method bits

# Monitoring: dump pull-relevant log lines from publisher + receivers.
pull-status:
	bash "$(TESTBED)" pullstatus --pull

# ── scenarios ─────────────────────────────────────────────────────────────────
# Start the testbed in SCENARIO and run its smoke test. `pull` uses the dedicated
# pull end-to-end check; the others use the standard smoke test.
scenario:
	@if [ -z "$(SCENARIO)" ]; then echo "set SCENARIO=push|mqtt|pull|ingest"; exit 1; fi
	bash "$(TESTBED)" start --scenario $(SCENARIO)
	@if [ "$(SCENARIO)" = "pull" ]; then \
	    bash "$(TESTBED)" pulltest --scenario pull; \
	else \
	    bash "$(TESTBED)" test --scenario $(SCENARIO); \
	fi

scenario-push:   ; @$(MAKE) scenario SCENARIO=push
scenario-mqtt:   ; @$(MAKE) scenario SCENARIO=mqtt
scenario-pull:   ; @$(MAKE) scenario SCENARIO=pull
scenario-ingest: ; @$(MAKE) scenario SCENARIO=ingest

# ── stresstest targets ────────────────────────────────────────────────────────
stresstest:
	bash "$(TESTBED)" stresstest $(N) $(_CONCURRENCY) --method bits $(_MQTT)

stresstest-ingest: $(MAKE_DIR)/bootstrap
	bash "$(TESTBED)" stresstest $(N) --method ingest $(_MQTT)

stresstest-mqtt:
	bash "$(TESTBED)" stresstest $(N) $(_CONCURRENCY) --mqtt --method bits

stresstest-pull:
	bash "$(TESTBED)" stresstest $(N) $(_CONCURRENCY) --pull --method bits

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
	@echo "  make bootstrap            Seed nested catalog + create snapshot (once)"
	@echo "  make snapshot             Save repo state to repo-seed.tar.gz"
	@echo "  make restore              Restore repo state from repo-seed.tar.gz"
	@echo "  make redeploy             Full rebuild from scratch"
	@echo "  make clean                Stop + wipe state (keeps snapshot and .env)"
	@echo "  make cleanall             Stop + wipe state + delete .env (fresh credentials)"
	@echo ""
	@echo "  make test                 Smoke test (bits method)"
	@echo "  make test-ingest          Smoke test (cvmfs_server ingest, needs bootstrap)"
	@echo "  make test-bits            Smoke test (cvmfs-prepub REST API)"
	@echo "  make test-mqtt            End-to-end MQTT notification test"
	@echo "  make test-pull            End-to-end pull-distribution test (needs make start-pull)"
	@echo "  make test-pull-wss        End-to-end pull test over embedded wss (needs make start-wss)"
	@echo "  make pull-status          Dump pull-relevant publisher/receiver logs"
	@echo ""
	@echo "  make stresstest [N=10]    Stress test, N jobs (bits)"
	@echo "  make stresstest-ingest    Stress test (ingest path)"
	@echo "  make stresstest-mqtt [N=10]  Stress test via MQTT path"
	@echo ""
	@echo "  make start-mqtt           Start testbed with Mosquitto MQTT broker"
	@echo "  make start-pull           Start testbed with pull + MQTT overlays (ADR-0001)"
	@echo "  make start-wss            Start testbed with embedded MQTT-over-WSS broker (no mosquitto)"
	@echo "  make MQTT=1 <target>      Enable MQTT overlay for any target"
	@echo "  make PULL=1 <target>      Enable pull overlay (implies MQTT) for any target"
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
