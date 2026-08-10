FROM ubuntu:24.04

# cvmfs-prepub itself is a static Go binary and needs almost nothing.  The
# libraries below are for the C++ cvmfs_swissknife it EXECS: the coarse-publish
# finalize (ingestsql) and, when started with --ingest-swissknife, the gateway
# ingest publish path.  Both run inside this container via
# --ingest-env LD_LIBRARY_PATH=/opt/cvmfs-software.
#
# The 2.15 swissknife links these dynamically; the 2.14 build vendored them, so
# this image worked without them until the SOFTWARE_ROOT binaries were rebuilt.
# The failure is quiet in a way that matters: prepub PROBES the ingest backend
# at startup, the probe fails because swissknife will not load, and the path is
# simply absent from /api/v1/health publish_paths.  Nothing logs "missing
# library" -- the console just stops offering ingest, and a build that asks for
# it is rejected as an unavailable path.
#
# gnutls flavour specifically: swissknife wants libcurl-gnutls.so.4, which
# libcurl4 (the OpenSSL flavour, libcurl.so.4) does NOT provide.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates \
        libcurl3t64-gnutls \
        libsqlite3-0 \
        libssl3 \
        zlib1g \
        libattr1 \
 && rm -rf /var/lib/apt/lists/*

RUN useradd -r -s /sbin/nologin prepub

RUN mkdir -p /data/cas /data/spool /etc/cvmfs-prepub \
 && chown -R prepub:prepub /data /etc/cvmfs-prepub

USER prepub

EXPOSE 8080
