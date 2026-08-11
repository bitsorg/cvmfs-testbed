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
        # ── cvmfs_server (the `ingest` publish path, --ingest-publish) ────────
        # cvmfs_server is a POSIX shell script that shells out constantly, so
        # its dependencies are ordinary userland tools rather than libraries.
        # This set mirrors cvmfs-native-publisher, which already runs
        # `cvmfs_server ingest` in a container and is the existence proof that
        # this works.
        #
        # MOUNTLESS is what makes it possible: `cvmfs_server connect-gw -P`
        # publishes through the gateway API with no FUSE mount, so no
        # /dev/fuse, no SYS_ADMIN, no privileged container. The repository is
        # never mounted here — see ensureAncestors in cvmfs-bits, which treats
        # a missing /cvmfs/<repo> as "mountless", not as an error.
        bash \
        coreutils \
        uuid-runtime \
        attr \
        libcap2-bin \
        curl \
        jq \
        python3 \
 && rm -rf /var/lib/apt/lists/*

RUN useradd -r -s /sbin/nologin prepub

# cvmfs_server writes transaction state, lock files and staging scratch into
# /var/spool/cvmfs/<repo>, and reads the repository config from
# /etc/cvmfs/repositories.d/<repo>.  Both are created here and handed to the
# prepub user.
#
# Ownership is the whole game.  cvmfs_server assumes it runs AS the repository
# owner; getting that wrong on cvmfs-bits-01 produced five consecutive, nearly
# identical permission failures, each costing a full round trip, and the last
# one was a 0750 parent directory that made every file beneath it unreadable
# regardless of its own mode.  In an image we can simply decide: prepub owns
# the spool, so the question never arises.  /etc/cvmfs/keys and
# /etc/cvmfs/repositories.d/<repo> are bind-mounted read-only from the host and
# only need to be TRAVERSABLE, which is why /etc/cvmfs itself is 0755.
#
# /etc/cvmfs itself is prepub-owned (non-recursively — the bind-mounted
# subdirectories keep their own ownership) so the entrypoint can create
# <repo>.s3.conf there for the direct-to-S3 ingest variant.
#
# That path is the DEFAULT, not a fixed one: cvmfs_server_ingest.sh reads
# "${CVMFS_INGEST_DIRECT_S3_CONFIG:-/etc/cvmfs/${name}.s3.conf}", so the env var
# wins when set.  The testbed sets it to a canonical file provisioned by init.sh
# and mounted read-only at /etc/cvmfs/s3/<repo>.s3.conf, shared with the gateway
# receiver — the entrypoint's own copy is now only the fallback for deployments
# that provision nothing.  (An earlier version of this comment asserted the path
# was fixed and that writing it elsewhere would not switch anything; that was
# wrong, and the whole shared-config arrangement depends on it being wrong.)
RUN mkdir -p /data/cas /data/spool /etc/cvmfs-prepub \
             /var/spool/cvmfs /etc/cvmfs/repositories.d /etc/cvmfs/keys /srv/cvmfs \
 && chown -R prepub:prepub /data /etc/cvmfs-prepub /var/spool/cvmfs /srv/cvmfs \
 && chown prepub:prepub /etc/cvmfs \
 && chmod 755 /etc/cvmfs /etc/cvmfs/repositories.d /etc/cvmfs/keys

COPY entrypoint.sh /usr/local/bin/prepub-entrypoint.sh
# 0755, NOT `chmod +x`.  `+x` only adds execute bits and keeps whatever read
# bits the build context happened to carry; a 0600 source file becomes 0711,
# and a SHELL SCRIPT must be READABLE by the interpreter that runs it.  The
# container then fails at startup with the actively misleading
#   bash: /usr/local/bin/prepub-entrypoint.sh: Permission denied
# on a file that is, technically, executable.
RUN chmod 0755 /usr/local/bin/prepub-entrypoint.sh

USER prepub

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/prepub-entrypoint.sh"]
