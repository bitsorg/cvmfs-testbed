FROM ubuntu:24.04

# Runtime dependencies — same set as cvmfs-native-publisher plus fuse3
# for mounting /cvmfs/<repo> during cvmfs_server transaction.
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
        libcap2-bin \
        fuse3 \
        libfuse3-3 \
        bash \
        coreutils \
        curl \
        jq \
        python3 \
 && rm -rf /var/lib/apt/lists/*

# Directories expected by cvmfs_server
RUN mkdir -p /var/spool/cvmfs \
             /etc/cvmfs/repositories.d \
             /etc/cvmfs/keys \
             /srv/cvmfs \
             /cvmfs \
 && chmod 755 /var/spool/cvmfs /etc/cvmfs/repositories.d \
              /etc/cvmfs/keys /srv/cvmfs /cvmfs

COPY scripts/ /scripts/
RUN chmod +x /scripts/*.sh

CMD ["/scripts/bootstrap.sh"]
