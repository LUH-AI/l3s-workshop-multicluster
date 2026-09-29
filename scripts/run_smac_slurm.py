#!/usr/bin/env python3
"""
run_smac_slurm.py
=================
Fabric-based script that:
  1. Reads the target cluster profile from config/clusters.json
  2. Renders a SLURM job script from scripts/job.sh.j2
  3. Connects to the cluster login node via SSH (Fabric)
  4. Uploads the rendered script and submits it with sbatch
  5. Polls squeue until the job terminates (max ~10 min safety cap)
  6. Fetches and prints the SLURM stdout and stderr logs

Usage
-----
  # Run on KISSKI (default):
  python scripts/run_smac_slurm.py

  # Run on a different cluster defined in config/clusters.json:
  python scripts/run_smac_slurm.py --cluster kisski

  # Dry-run: render and print the SLURM script without connecting:
  python scripts/run_smac_slurm.py --dry-run

  # Override the conda environment name:
  python scripts/run_smac_slurm.py --conda-env my-smac-env

Assumptions
-----------
- SSH key-based auth, no 2FA (KISSKI: id_ed25519, no OTP)
- The repo is already synced at cluster.repo_path on the login node
- The login node can reach the compute nodes via sbatch
- conda / miniforge3 is available via `module load`

Storage layout (all relative to cluster.scratch_dir = repo_path)
-----------
  <scratch_dir>/
    logs/              # SLURM stdout/stderr files (created by this script)
    smac_job.sh        # the rendered and uploaded SLURM script
"""

from __future__ import annotations

import argparse
import json
import sys
import tempfile
import time
from pathlib import Path

from fabric import Connection
from jinja2 import Environment, FileSystemLoader

# ── Path constants (relative to repo root) ─────────────────────────
REPO_ROOT = Path(__file__).parent.parent
CLUSTERS_FILE = REPO_ROOT / "config" / "clusters.json"
TEMPLATE_DIR = REPO_ROOT / "scripts"
TEMPLATE_NAME = "job.sh.j2"

# Polling interval (seconds) and hard timeout (seconds)
POLL_INTERVAL = 15
POLL_TIMEOUT = 600  # 10 minutes — well above the 5-min job walltime


# ── Config loading ──────────────────────────────────────────────────

def load_cluster(name: str) -> dict:
    """Load and return one cluster profile from clusters.json."""
    if not CLUSTERS_FILE.exists():
        sys.exit(f"ERROR: clusters.json not found at {CLUSTERS_FILE}")
    with CLUSTERS_FILE.open() as fh:
        all_clusters = json.load(fh)
    if name not in all_clusters:
        available = ", ".join(all_clusters.keys())
        sys.exit(
            f"ERROR: cluster '{name}' not in clusters.json.\n"
            f"Available: {available}"
        )
    return all_clusters[name]


# ── SLURM script rendering ──────────────────────────────────────────

def render_slurm_script(cluster: dict, job_name: str, conda_env_override: str | None) -> str:
    """
    Render job.sh.j2 with the given cluster profile.

    conda_env_override replaces cluster['conda_env'] when provided,
    useful for --conda-env CLI flag.
    """
    if conda_env_override:
        cluster = {**cluster, "conda_env": conda_env_override}

    env = Environment(
        loader=FileSystemLoader(str(TEMPLATE_DIR)),
        keep_trailing_newline=True,
    )
    template = env.get_template(TEMPLATE_NAME)

    return template.render(
        cluster=cluster,
        job_name=job_name,
        n_workers=1,
        image_tag="latest",   # unused for conda path, kept for template compat
        registry="",          # unused for conda path
        extra_env={},
    )


# ── Fabric helpers ──────────────────────────────────────────────────

def make_connection(cluster: dict) -> Connection:
    """
    Build a Fabric Connection from the cluster profile.

    Uses key-based auth only (no password, no 2FA).
    The SSH key path is expanded so '~' resolves correctly.
    """
    key_path = str(Path(cluster["key"]).expanduser())
    return Connection(
        host=cluster["host"],
        user=cluster["user"],
        port=cluster.get("port", 22),
        connect_kwargs={"key_filename": key_path},
    )


def ensure_log_dir(c: Connection, scratch_dir: str) -> None:
    """Create the logs directory on the remote host if absent."""
    c.run(f"mkdir -p {scratch_dir}/logs", hide=True)


def upload_script(c: Connection, local_script: str, remote_path: str) -> None:
    """Write the rendered SLURM script to a temp file and upload it."""
    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".sh", delete=False, prefix="smac_job_"
    ) as tmp:
        tmp.write(local_script)
        tmp_path = tmp.name
    c.put(tmp_path, remote=remote_path)
    Path(tmp_path).unlink()
    print(f"  Uploaded SLURM script → {remote_path}")


def submit_job(c: Connection, remote_script: str) -> str:
    """
    Run sbatch and return the job ID.

    sbatch prints: "Submitted batch job 12345"
    We parse the last token of that line.
    """
    result = c.run(f"sbatch {remote_script}", hide=True)
    output = result.stdout.strip()
    print(f"  sbatch output: {output}")
    tokens = output.split()
    if not tokens or not tokens[-1].isdigit():
        sys.exit(f"ERROR: could not parse job ID from sbatch output:\n{output}")
    job_id = tokens[-1]
    print(f"  Job ID: {job_id}")
    return job_id


def wait_for_job(c: Connection, job_id: str) -> None:
    """
    Poll squeue every POLL_INTERVAL seconds until the job is gone.

    squeue -j <id> -h prints one line while the job exists (queued,
    running, completing). An empty result means it has finished or
    failed. We add a hard timeout as a safety net.
    """
    print(f"\n  Waiting for job {job_id} to complete "
          f"(polling every {POLL_INTERVAL}s, timeout {POLL_TIMEOUT}s) …")
    elapsed = 0
    while elapsed < POLL_TIMEOUT:
        result = c.run(
            f"squeue -j {job_id} -h --format='%i %T %r'",
            hide=True, warn=True
        )
        line = result.stdout.strip()
        if not line:
            print(f"  Job {job_id} is no longer in the queue.")
            return
        print(f"  [{elapsed:>4}s] {line}")
        time.sleep(POLL_INTERVAL)
        elapsed += POLL_INTERVAL

    print(f"WARNING: timeout after {POLL_TIMEOUT}s — job may still be running.")


def fetch_and_print_logs(
    c: Connection,
    scratch_dir: str,
    job_name: str,
    job_id: str,
) -> None:
    """
    Cat the SLURM stdout and stderr files back to the local terminal.

    File naming follows the template's --output / --error directives:
      <scratch_dir>/logs/<job-name>_<job-id>.out
      <scratch_dir>/logs/<job-name>_<job-id>.err
    """
    for ext, label in [("out", "STDOUT"), ("err", "STDERR")]:
        remote_path = f"{scratch_dir}/logs/{job_name}_{job_id}.{ext}"
        result = c.run(f"cat {remote_path}", hide=True, warn=True)
        content = result.stdout.strip()
        print(f"\n{'='*60}")
        print(f"  SLURM {label}  ({remote_path})")
        print(f"{'='*60}")
        if content:
            print(content)
        else:
            print(f"  (empty or file not found: {remote_path})")


# ── Main ────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Submit a SMAC SLURM job and stream its output."
    )
    parser.add_argument(
        "--cluster", default="kisski",
        help="Cluster name from config/clusters.json (default: kisski)",
    )
    parser.add_argument(
        "--conda-env", default=None,
        help="Override the conda environment name from clusters.json",
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Render and print the SLURM script without connecting",
    )
    args = parser.parse_args()

    # 1. Load cluster profile
    print(f"[1/6] Loading cluster profile: {args.cluster}")
    cluster = load_cluster(args.cluster)
    scratch_dir = cluster["scratch_dir"]
    job_name = f"smac_{args.cluster}"
    remote_script = f"{scratch_dir}/smac_job.sh"

    # 2. Render SLURM script
    print(f"[2/6] Rendering SLURM script from {TEMPLATE_NAME}")
    script = render_slurm_script(cluster, job_name, args.conda_env)

    if args.dry_run:
        print("\n── Rendered SLURM script (dry-run, not submitted) ──────────")
        print(script)
        return

    # 3. Connect
    print(f"[3/6] Connecting to {cluster['user']}@{cluster['host']}")
    c = make_connection(cluster)
    c.open()
    print(f"  Connected.")

    # 4. Upload and submit
    print(f"[4/6] Uploading and submitting")
    ensure_log_dir(c, scratch_dir)
    upload_script(c, script, remote_script)
    job_id = submit_job(c, remote_script)

    # 5. Poll until done
    print(f"[5/6] Monitoring job")
    wait_for_job(c, job_id)

    # 6. Fetch and print output
    print(f"[6/6] Fetching results")
    fetch_and_print_logs(c, scratch_dir, job_name, job_id)

    c.close()
    print("\nDone.")


if __name__ == "__main__":
    main()
