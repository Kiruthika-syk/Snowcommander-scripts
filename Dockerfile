# ==============================================================================
# Snow Commander security tools — deployment control plane
#
# This container ORCHESTRATES installation onto remote RHEL-family servers over
# SSH. It never runs a security agent itself, because every agent here is bound
# to its host: Falcon is a kernel/eBPF sensor, Tanium needs host systemd and
# hardware inventory, and azcmagent registers the host identity in Azure. An
# agent inside this container would report the container, not the VM.
#
# The container OS is intentionally independent of the target OS. AlmaLinux 9 is
# used because it carries a native, well-tested `rpm` for validating package
# digests before shipping them; targets may be EL7, EL8, EL9 or EL10 on either
# x86_64 or aarch64, and none of that depends on this base image.
#
# Build:
#   podman build -t snowcommander-deployer:latest .
#   docker build  -t snowcommander-deployer:latest .
# ==============================================================================

FROM almalinux:9

LABEL org.opencontainers.image.title="snowcommander-deployer" \
      org.opencontainers.image.description="SSH control plane for RHEL-family security tool deployment" \
      org.opencontainers.image.source="https://github.com/Kiruthika-syk/Snowcommander-scripts"

# Only what the base image lacks. bash, rpm, tar, gzip, sed, gawk, grep,
# findutils, util-linux and ca-certificates already ship in almalinux:9, and
# requesting full `coreutils` would conflict with the bundled coreutils-single.
#
# openssh-clients  SSH and scp to targets
# rsync            optional faster re-sync
# procps-ng        process inspection when troubleshooting
RUN dnf -y install --setopt=install_weak_deps=False \
        openssh-clients \
        rsync \
        procps-ng \
    && dnf clean all \
    && rm -rf /var/cache/dnf \
    # Fail loudly at build time if any orchestration primitive is missing.
    && for c in bash ssh rpm tar gzip sed awk grep find shred install mktemp; do \
         command -v "$c" >/dev/null || { echo "FATAL: missing $c" >&2; exit 1; }; \
       done \
    && echo "all required tools present"

ENV APP_DIR=/opt/snowcommander \
    REMOTE_DIR=/var/tmp/sectools \
    SSH_USER=tpx-admin \
    SSH_PORT=22 \
    PARALLEL=5 \
    RETRIES=1 \
    COMPONENTS=all

WORKDIR ${APP_DIR}

# Orchestration logic first: these change far more often than the packages,
# so keeping them in a later layer would invalidate the large package layer.
COPY deploy-manifest.txt ./
COPY lib/ ./lib/
COPY scripts/ ./scripts/
COPY entrypoint.sh ./

# Host-side payload shipped to targets.
COPY security.sh sentinel_core.sh uninstall.sh sub-reg.sh ./
COPY install_crowdstrike.sh install_tanium.sh install_cmdbsync.sh \
     install_sentinel.sh install_syslog.sh ./
COPY securitytools.env.example ./

# Vendor packages last: ~548 MB, and the least frequently changed.
# .dockerignore keeps securitytools.env and key material out of the build.
COPY crowdstrike/ ./crowdstrike/
COPY tanium/ ./tanium/

RUN chmod 0755 entrypoint.sh security.sh sentinel_core.sh uninstall.sh \
                sub-reg.sh install_*.sh lib/*.sh scripts/*.sh \
    && chmod 0600 tanium/tanium-init.dat \
    # Fail the build rather than ship an image containing a live secrets file.
    && if [ -f securitytools.env ]; then \
         echo "FATAL: securitytools.env is present in the build context" >&2; exit 1; \
       fi \
    # Fail the build if any staged package is corrupt.
    && for f in crowdstrike/*.rpm tanium/*.rpm; do \
         rpm -K --nosignature "$f" 2>&1 | grep -qi 'NOT OK' \
           && { echo "FATAL: corrupt package $f" >&2; exit 1; } || true; \
       done \
    && echo "packages verified: $(ls -1 crowdstrike/*.rpm tanium/*.rpm | wc -l)"

# Run as an unprivileged user. No capabilities are required: the container only
# opens outbound SSH connections. Privilege is needed on the TARGET (via sudo),
# never here. Root inside the container would add risk and buy nothing.
RUN useradd --system --create-home --home-dir /home/deployer --shell /bin/bash deployer \
    && install -d -m 700 -o deployer -g deployer /home/deployer/.ssh \
    && chown -R deployer:deployer ${APP_DIR}

USER deployer
ENV HOME=/home/deployer

HEALTHCHECK --interval=60s --timeout=10s --retries=3 \
    CMD ["/opt/snowcommander/entrypoint.sh", "healthcheck"]

ENTRYPOINT ["/opt/snowcommander/entrypoint.sh"]
CMD ["plan"]
