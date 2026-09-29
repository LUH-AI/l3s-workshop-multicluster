# Cluster B image: SLURM (23.11, Ubuntu 24.04 packages) + munge + Apptainer.
# One image for every container; the command picks the role (slurmctld | slurmd).
FROM ubuntu:24.04

ARG APPTAINER_VERSION=1.5.4
ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Etc/UTC

# SLURM, munge and tzdata (Apptainer bind-mounts /etc/localtime, so it must exist).
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        slurmctld slurmd slurm-client munge \
        tzdata ca-certificates curl procps iproute2 python3 \
 && rm -rf /var/lib/apt/lists/*

# Apptainer from the GitHub release .deb (the PPA is not reachable from the build).
RUN curl -fsSL -o /tmp/apptainer.deb \
        "https://github.com/apptainer/apptainer/releases/download/v${APPTAINER_VERSION}/apptainer_${APPTAINER_VERSION}_amd64.deb" \
 && apt-get update \
 && apt-get install -y --no-install-recommends /tmp/apptainer.deb \
 && rm -rf /tmp/apptainer.deb /var/lib/apt/lists/* \
 && apptainer --version

# Shared munge key, baked in at build time (fine for a local lab, not for production).
RUN dd if=/dev/urandom of=/etc/munge/munge.key bs=1 count=1024 status=none \
 && chown munge:munge /etc/munge/munge.key \
 && chmod 0400 /etc/munge/munge.key \
 && mkdir -p /var/spool/slurmctld /var/spool/slurmd /var/log/slurm /run/munge \
 && chown munge:munge /run/munge \
 && printf 'CgroupPlugin=cgroup/v2\nIgnoreSystemd=yes\n' > /etc/slurm/cgroup.conf
# ^ slurmd 23.11 always loads a cgroup plugin; there is no systemd/dbus in the
#   container, so it must not ask systemd for a scope (entrypoint.sh prepares
#   /sys/fs/cgroup). Jobs are still tracked via /proc (proctrack/linuxproc).

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
# Files may have been checked out on Windows with CRLF line endings.
RUN sed -i 's/\r$//' /usr/local/bin/entrypoint.sh \
 && chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["slurmd"]
