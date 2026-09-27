"""
Query cluster state via SSH.

Wraps `sinfo` and `squeue` calls to report available capacity and
queue depth for each configured cluster. The allocator uses this to
decide where to submit work.

TODO for participants:
  - [ ] Parse sinfo output to get idle/allocated/total node counts
  - [ ] Parse squeue output to get pending/running job counts for the user
  - [ ] Add remaining budget tracking (hours used vs. allocation limit)
  - [ ] Cache results with a TTL to avoid SSH-ing on every call
  - [ ] Handle SSH timeouts gracefully (mark cluster as unreachable)
"""

from __future__ import annotations

import json
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

CLUSTERS_FILE = Path(__file__).parent.parent / "config" / "clusters.json"


@dataclass
class ClusterStatus:
    """Snapshot of one cluster's current state."""

    name: str
    reachable: bool = False
    idle_nodes: int = 0
    running_jobs: int = 0
    pending_jobs: int = 0
    budget_remaining_hours: float | None = None  # None = unknown

    @property
    def pressure(self) -> float:
        """
        Simple heuristic: higher = more congested.
        0.0 = idle, 1.0+ = heavily loaded.
        """
        if self.idle_nodes == 0:
            return float("inf")
        return self.pending_jobs / max(self.idle_nodes, 1)


def load_clusters(path: Path = CLUSTERS_FILE) -> dict:
    """Load cluster definitions from clusters.json."""
    with open(path) as f:
        return json.load(f)


def _ssh_cmd(host: str, port: int, user: str, command: str) -> str | None:
    """Run a command on a remote host via SSH. Returns stdout or None."""
    try:
        result = subprocess.run(
            [
                "ssh",
                "-p", str(port),
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=5",
                f"{user}@{host}",
                command,
            ],
            capture_output=True,
            text=True,
            timeout=15,
        )
        if result.returncode == 0:
            return result.stdout.strip()
        return None
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return None


def get_cluster_status(name: str, cluster: dict) -> ClusterStatus:
    """
    Query one cluster's state via SSH.

    Parameters
    ----------
    name : str
        Cluster name (key in clusters.json).
    cluster : dict
        Cluster config dict with host, port, user, type fields.
    """
    host = cluster["host"]
    port = cluster.get("port", 22)
    user = cluster["user"]

    status = ClusterStatus(name=name)

    # Check basic reachability
    if _ssh_cmd(host, port, user, "echo ok") != "ok":
        return status
    status.reachable = True

    # Skip sinfo/squeue for Docker simulator clusters
    if cluster.get("type") == "docker":
        status.idle_nodes = 1  # simulator always has "capacity"
        return status

    # ── Query SLURM ─────────────────────────────────────────────────
    # sinfo: count idle nodes in the default partition
    # TODO: filter by the partition from the cluster profile
    sinfo_out = _ssh_cmd(
        host, port, user,
        "sinfo --noheader --format='%t %D' 2>/dev/null"
    )
    if sinfo_out:
        for line in sinfo_out.splitlines():
            parts = line.strip().split()
            if len(parts) == 2:
                state, count = parts[0], int(parts[1])
                if state in ("idle", "idle~"):
                    status.idle_nodes += count

    # squeue: count this user's running and pending jobs
    squeue_out = _ssh_cmd(
        host, port, user,
        f"squeue --user={user} --noheader --format='%t' 2>/dev/null"
    )
    if squeue_out:
        for line in squeue_out.splitlines():
            state = line.strip()
            if state == "R":
                status.running_jobs += 1
            elif state == "PD":
                status.pending_jobs += 1

    # TODO: query budget remaining
    # Some clusters expose this via `sacctmgr show association` or
    # custom scripts. Parse it here if available.

    return status


def get_all_cluster_status(path: Path = CLUSTERS_FILE) -> list[ClusterStatus]:
    """Query all configured clusters and return their status."""
    clusters = load_clusters(path)
    return [
        get_cluster_status(name, config)
        for name, config in clusters.items()
    ]


# ── CLI entry point ─────────────────────────────────────────────────

if __name__ == "__main__":
    print(f"{'Cluster':<16} {'Reach?':<8} {'Idle':<6} {'Run':<6} {'Pend':<6} {'Pressure':<10}")
    print("-" * 58)
    for s in get_all_cluster_status():
        pressure = f"{s.pressure:.2f}" if s.pressure != float("inf") else "inf"
        print(
            f"{s.name:<16} {'yes' if s.reachable else 'NO':<8} "
            f"{s.idle_nodes:<6} {s.running_jobs:<6} {s.pending_jobs:<6} {pressure:<10}"
        )
