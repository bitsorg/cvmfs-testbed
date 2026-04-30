FROM ubuntu:24.04

# Runtime dependencies for cvmfs_gateway (Go binary) and cvmfs_receiver (C++ binary).
# cvmfs_receiver needs: libssl3, libsqlite3, libcurl, libz, libattr, libuuid,
# and the CVMFS syslog/watchdog plumbing (SYS_PTRACE capability for the watchdog).
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates \
        libssl3 \
        libsqlite3-0 \
        libcurl4 \
        zlib1g \
        libattr1 \
        uuid-runtime \
        attr \
 && rm -rf /var/lib/apt/lists/*

# cvmfs_receiver MkdirDeep("/var/log/cvmfs_receiver/", 0755) is the first call it
# makes; if the directory can't be created the receiver exits immediately (return 1)
# before any protocol exchange, which the gateway sees as EOF.
RUN mkdir -p /var/log/cvmfs_receiver && chmod 755 /var/log/cvmfs_receiver

# cvmfs_receiver also needs /var/lib/cvmfs-gateway for the gateway work directory.
RUN mkdir -p /var/lib/cvmfs-gateway && chmod 755 /var/lib/cvmfs-gateway

# Scratch / spool directory used by cvmfs_receiver when CVMFS_UPSTREAM_STORAGE
# is patched to local mode.  Must exist before the receiver starts.
# /var/spool/cvmfs is the conventional CVMFS spool root.
RUN mkdir -p /var/spool/cvmfs && chmod 755 /var/spool/cvmfs

# Binary injected at runtime from the software mount.
# Config injected at runtime from ${TESTBED_ROOT}/config/gateway/.
EXPOSE 4929
