FROM ubuntu:24.04

# Runtime dependencies for cvmfs_server (shell script) and its subprocesses:
#   cvmfs_swissknife  — catalog sync, hash computation, upload
#   cvmfs_publish     — per-commit signing and manifest update
# These call into the same C++ libs as cvmfs_receiver (ssl, sqlite, curl, zlib, attr).
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates \
        libssl3 \
        libsqlite3-0 \
        libcurl4 \
        # cvmfs_swissknife links libcurl-gnutls.so.4, which libcurl4 (the
        # OpenSSL flavour, libcurl.so.4) does NOT provide.  Without this the
        # binary is present and executable but dies at load time, and the suite
        # reports it as "catalog/data problems found (rc=127)" — 127 being
        # "command not found", not a catalog problem at all.
        libcurl3t64-gnutls \
        zlib1g \
        libattr1 \
        uuid-runtime \
        attr \
        libcap2-bin \
        bash \
        coreutils \
        curl \
        jq \
        python3 \
        mosquitto-clients \
 && rm -rf /var/lib/apt/lists/*

# cvmfs_server expects these directories to exist.
RUN mkdir -p /var/spool/cvmfs \
             /etc/cvmfs/repositories.d \
             /etc/cvmfs/keys \
             /srv/cvmfs \
             /tmp/cvmfs-ingest-tmp \
 && chmod 755 /var/spool/cvmfs /etc/cvmfs/repositories.d /etc/cvmfs/keys \
              /srv/cvmfs /tmp/cvmfs-ingest-tmp

COPY entrypoint.sh /usr/local/bin/native-publisher-entrypoint.sh
RUN chmod +x /usr/local/bin/native-publisher-entrypoint.sh

COPY scripts/ /scripts/
RUN chmod +x /scripts/*.sh

WORKDIR /scripts
ENTRYPOINT ["/usr/local/bin/native-publisher-entrypoint.sh"]
CMD ["sleep", "infinity"]
