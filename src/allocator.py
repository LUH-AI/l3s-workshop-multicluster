"""
Multi-cluster experiment allocator.

Reads the experiment grid state from PyExperimenter, queries cluster
capacity, decides how to distribute pending experiments, generates
SLURM scripts from Jinja2 templates, and optionally submits them.

This implements Approach A/C from the feasibility study — a rule-based
allocator with template-based script generation. Swap in the LLM layer
(see llm_scheduler.py) for Approach B/D.

Usage:
    python src/allocator.py --plan               # show plan, don't submit
    python src/allocator.py --submit              # generate and submit
    python src/allocator.py --cluster luis --max 100  # cap for one cluster

TODO for participants:
  - [ ] Read real experiment state from PyExperimenter DB
  - [ ] Integrate the runtime predictor for smarter allocation
  - [ ] Add --dry-run flag that calls sbatch --test-only
  - [ ] Add budget-aware allocation (don't exceed remaining hours)
  - [ ] Support array jobs instead of one script per batch
"""

from __future__ import annotations

import argparse
import json
import math
import subprocess
from dataclasses import dataclass
from pathlib import Path

from jinja2 import Environment, FileSystemLoader

from cluster_state import (
    ClusterStatus,
    get_all_cluster_status,
    load_clusters,
)

TEMPLATES_DIR = Path(__file__).parent.parent / "templates"
CLUSTERS_FILE = Path(__file__).parent.parent / "config" / "clusters.json"
GENERATED_DIR = Path(__file__).parent.parent / "generated"


# ── Experiment grid state ───────────────────────────────────────────

@dataclass
class GridState:
    """Summary of the PyExperimenter experiment grid."""

    total: int
    done: int
    running: int
    pending: int  # = total - done - running

    @property
    def remaining(self) -> int:
        return self.pending


def get_grid_state() -> GridState:
    """
    Query PyExperimenter for experiment counts by status.

    TODO: Replace this stub with a real DB query.
    Something like:
        from py_experimenter.experimenter import PyExperimenter
        exp = PyExperimenter(experiment_configuration_file_path=...)
        table = exp.get_table()
        done = len(table[table.status == 'done'])
        ...
    """
    # ── STUB: fake grid state for development ───────────────────────
    # Participants: replace with real PyExperimenter query.
    return GridState(
        total=600,    # e.g. 2 algorithms × 3 datasets × 10 seeds × 10 n_trials
        done=50,
        running=20,
        pending=530,
    )


# ── Allocation strategies ───────────────────────────────────────────

@dataclass
class Allocation:
    """How many experiments to assign to one cluster."""

    cluster_name: str
    n_experiments: int
    n_workers: int  # parallel SLURM tasks


def allocate_proportional(
    remaining: int,
    statuses: list[ClusterStatus],
    max_per_cluster: int | None = None,
) -> list[Allocation]:
    """
    Distribute experiments proportionally to idle capacity.

    Clusters with more idle nodes get more experiments. Unreachable
    clusters get nothing.

    Parameters
    ----------
    remaining : int
        Number of experiments to distribute.
    statuses : list[ClusterStatus]
        Current state of each cluster.
    max_per_cluster : int or None
        Cap per cluster (e.g. to respect budget limits).
    """
    reachable = [s for s in statuses if s.reachable and s.idle_nodes > 0]

    if not reachable:
        print("WARNING: no reachable clusters with idle capacity")
        return []

    total_idle = sum(s.idle_nodes for s in reachable)
    allocations = []

    for s in reachable:
        share = s.idle_nodes / total_idle
        n = math.floor(remaining * share)

        if max_per_cluster is not None:
            n = min(n, max_per_cluster)

        if n > 0:
            # One worker per idle node, but no more than the batch size
            n_workers = min(s.idle_nodes, n)
            allocations.append(Allocation(s.name, n, n_workers))

    return allocations


# TODO: add more strategies
# def allocate_shortest_queue(remaining, statuses): ...
# def allocate_budget_aware(remaining, statuses, budgets): ...
# def allocate_with_runtime_predictor(remaining, statuses, predictor): ...


# ── SLURM script generation ────────────────────────────────────────

def generate_sbatch(
    allocation: Allocation,
    cluster_profile: dict,
    image_tag: str = "latest",
    registry: str = "ghcr.io/your-org/project",
) -> str:
    """
    Render a SLURM script from the Jinja2 template.

    Returns the rendered script as a string.
    """
    env = Environment(
        loader=FileSystemLoader(str(TEMPLATES_DIR)),
        keep_trailing_newline=True,
    )
    template = env.get_template("job.sh.j2")

    return template.render(
        cluster=cluster_profile,
        job_name=f"smac_{allocation.cluster_name}_{allocation.n_experiments}",
        n_workers=allocation.n_workers,
        image_tag=image_tag,
        registry=registry,
        extra_env={
            "PYEXP_MAX_EXPERIMENTS": str(allocation.n_experiments),
            # Workers will claim up to this many rows, then exit.
        },
    )


def write_script(allocation: Allocation, script: str) -> Path:
    """Write a generated script to the generated/ directory."""
    GENERATED_DIR.mkdir(parents=True, exist_ok=True)
    path = GENERATED_DIR / f"job_{allocation.cluster_name}.sh"
    path.write_text(script)
    path.chmod(0o755)
    return path


# ── Submission ──────────────────────────────────────────────────────

def submit_to_cluster(
    cluster_name: str,
    cluster_config: dict,
    script_path: Path,
) -> str | None:
    """
    Copy the script to the cluster and run sbatch.

    Returns the SLURM job ID on success, None on failure.

    TODO for participants:
      - [ ] Use scp or rsync to copy the script
      - [ ] Parse the sbatch output for the job ID
      - [ ] Store the job ID in PyExperimenter or a local log
    """
    host = cluster_config["host"]
    port = cluster_config.get("port", 22)
    user = cluster_config["user"]
    sync_path = cluster_config.get("sync_path", "~/workshop")

    # Copy script to cluster
    scp_target = f"{user}@{host}:{sync_path}/"
    scp_cmd = ["scp", "-P", str(port), str(script_path), scp_target]

    try:
        subprocess.run(scp_cmd, check=True, capture_output=True, timeout=15)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as e:
        print(f"  ERROR copying script to {cluster_name}: {e}")
        return None

    # Submit via sbatch
    remote_script = f"{sync_path}/{script_path.name}"
    ssh_cmd = [
        "ssh", "-p", str(port),
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=5",
        f"{user}@{host}",
        f"sbatch {remote_script}",
    ]

    try:
        result = subprocess.run(
            ssh_cmd, capture_output=True, text=True, timeout=15
        )
        if result.returncode == 0:
            # sbatch prints "Submitted batch job 12345"
            job_id = result.stdout.strip().split()[-1]
            return job_id
        else:
            print(f"  ERROR sbatch on {cluster_name}: {result.stderr.strip()}")
            return None
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as e:
        print(f"  ERROR submitting to {cluster_name}: {e}")
        return None


# ── Main ────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Allocate and submit SMAC experiments across clusters."
    )
    parser.add_argument(
        "--plan", action="store_true",
        help="Show the allocation plan without submitting.",
    )
    parser.add_argument(
        "--submit", action="store_true",
        help="Generate scripts and submit to clusters.",
    )
    parser.add_argument(
        "--cluster", type=str, default=None,
        help="Target a single cluster (default: all reachable).",
    )
    parser.add_argument(
        "--max", type=int, default=None,
        help="Max experiments per cluster.",
    )
    parser.add_argument(
        "--image-tag", type=str, default="latest",
        help="Container image tag to deploy.",
    )
    args = parser.parse_args()

    # 1. Read state
    grid = get_grid_state()
    print(f"Experiment grid: {grid.total} total, {grid.done} done, "
          f"{grid.running} running, {grid.pending} pending\n")

    if grid.remaining == 0:
        print("Nothing to allocate — all experiments done or running.")
        return

    # 2. Query clusters
    statuses = get_all_cluster_status()
    if args.cluster:
        statuses = [s for s in statuses if s.name == args.cluster]

    print(f"{'Cluster':<16} {'Reachable':<12} {'Idle nodes':<12} {'Queue pressure'}")
    for s in statuses:
        p = f"{s.pressure:.2f}" if s.pressure != float("inf") else "inf"
        print(f"  {s.name:<14} {'yes' if s.reachable else 'NO':<12} {s.idle_nodes:<12} {p}")
    print()

    # 3. Allocate
    allocations = allocate_proportional(
        grid.remaining, statuses, max_per_cluster=args.max
    )

    if not allocations:
        print("No allocations possible. Check cluster connectivity.")
        return

    print("Allocation plan:")
    for a in allocations:
        print(f"  {a.cluster_name}: {a.n_experiments} experiments, {a.n_workers} workers")
    print()

    if args.plan:
        return

    # 4. Generate scripts
    clusters = load_clusters()
    for a in allocations:
        profile = clusters.get(a.cluster_name, {})
        script = generate_sbatch(a, profile, image_tag=args.image_tag)
        path = write_script(a, script)
        print(f"Generated: {path}")

        if args.submit:
            job_id = submit_to_cluster(a.cluster_name, profile, path)
            if job_id:
                print(f"  Submitted to {a.cluster_name}: job {job_id}")
            else:
                print(f"  FAILED to submit to {a.cluster_name}")

    print("\nDone.")


if __name__ == "__main__":
    main()
