# Fabric-based SMAC SLURM Runner

This document covers `scripts/run_smac_slurm.py` — a
[Fabric](https://www.fabfile.org/)-based script that connects to an HPC
login node, submits a SMAC experiment as a SLURM job, waits for it to
finish, and prints the output. It is the recommended way to launch a
single timed SMAC run from your local machine without manually SSHing,
uploading scripts, and tailing logs.

---

## What it does

1. Loads the target cluster profile from `config/clusters.json`
2. Renders `scripts/job.sh.j2` into a concrete `sbatch` script
3. Connects to the login node via SSH (key-based, no 2FA)
4. Uploads the rendered script and submits it with `sbatch`
5. Polls `squeue` every 15 seconds until the job leaves the queue
6. Fetches and prints the SLURM stdout and stderr logs

---

## Files

| File | Location in repo | Role |
|---|---|---|
| `run_smac_slurm.py` | `scripts/run_smac_slurm.py` | Fabric script — the entry point |
| `clusters.json` | `config/clusters.json` | Cluster connection and SLURM profiles |
| `job.sh.j2` | `scripts/job.sh.j2` | Jinja2 SLURM job template |

---

## Prerequisites

Fabric must be installed in your local Python environment.
It is already listed in `requirements-dev.txt`:

```bash
pip install -r requirements-dev.txt
```

Verify:

```bash
python -c "import fabric; print(fabric.__version__)"
```

---

## Quick start

```bash
# 1. Dry-run: render and print the SLURM script without connecting
python scripts/run_smac_slurm.py --dry-run

# 2. Live run on KISSKI
python scripts/run_smac_slurm.py --cluster kisski

# 3. Override the conda environment name if yours differs from the default
python scripts/run_smac_slurm.py --cluster kisski --conda-env my-env-name
```

Always do a `--dry-run` first to confirm the rendered script looks
correct before submitting.

---

## Cluster configuration

Cluster profiles live in `config/clusters.json`. The KISSKI entry
(the currently supported real cluster) looks like this:

```json
"kisski": {
  "host": "glogin-gpu.hpc.gwdg.de",
  "port": 22,
  "user": "<your-username>",
  "key": "~/.ssh/id_ed25519",
  "type": "slurm",
  "env_manager": "conda",
  "conda_env": "smac-env",
  "modules": ["miniforge3"],
  "repo_path": "/projects/extern/kisski/kisski-multicluster/dir.project/l3s-workshop-multicluster",
  "scratch_dir": "/projects/extern/kisski/kisski-multicluster/dir.project",
  "slurm": {
    "partition": "kisski",
    "time": "00:05:00",
    "nodes": 1,
    "cpus_per_task": 4,
    "mem": "8G"
  }
}
```

Key fields:

| Field | Purpose |
|---|---|
| `host` | Login node hostname |
| `user` | Your HPC username |
| `key` | Path to your SSH private key (expanded locally) |
| `env_manager` | `conda`, `pixi`, or `apptainer` — controls the run branch in the template |
| `conda_env` | Conda environment name to activate (conda path only) |
| `modules` | List of modules loaded before activating the environment |
| `repo_path` | Absolute path to the cloned repo on the cluster |
| `scratch_dir` | Root for logs (`<scratch_dir>/logs/`) and the uploaded job script |
| `slurm.time` | Walltime limit — set to `00:05:00` for a 5-minute SMAC run |

> `repo_path` and `scratch_dir` are separate because the repo is
> nested inside the project directory:
> `scratch_dir = dir.project/`, `repo_path = dir.project/l3s-workshop-multicluster/`.
> Logs always land in `scratch_dir/logs/`.

---

## Conda environment on KISSKI

The SLURM script runs:

```bash
module load miniforge3
source $(conda info --base)/etc/profile.d/conda.sh
conda activate <conda_env>
cd <repo_path>
python src/smac_worker.py
```

The `source` line is required because `conda activate` does not work
in non-interactive batch scripts without it. If your environment has a
different name from the default (`smac-env`), either update
`config/clusters.json` or pass `--conda-env <name>` at runtime.

If the environment does not exist yet, create it on the login node
before submitting:

```bash
ssh u31890@glogin-gpu.hpc.gwdg.de
module load miniforge3
conda create -n smac-env python=3.10 -y
conda activate smac-env
cd /projects/extern/kisski/kisski-multicluster/dir.project/l3s-workshop-multicluster
pip install -r requirements.txt
```

---

## SLURM job template

`scripts/job.sh.j2` supports three environment managers via a branch
in the template:

| `env_manager` value | What runs on the compute node |
|---|---|
| `conda` | `module load` → `source conda.sh` → `conda activate` → `python src/smac_worker.py` |
| `apptainer` | `apptainer exec` with the project `.sif` image |
| `pixi` (default) | `pixi run python src/smac_worker.py` |

SLURM directives (`--partition`, `--time`, `--mem`, etc.) are all
driven by the `slurm` block in `clusters.json` — no template edits
are needed when switching clusters.

---

## Adding a new cluster (e.g. LUIS)

1. Add an entry to `config/clusters.json` following the KISSKI
   template above, with the correct host, username, key, paths, and
   SLURM partition name.
2. Set `env_manager` to `conda`, `pixi`, or `apptainer` to match
   what is available on that cluster.
3. Dry-run to verify the rendered script:
   ```bash
   python scripts/run_smac_slurm.py --cluster luis --dry-run
   ```
4. Submit:
   ```bash
   python scripts/run_smac_slurm.py --cluster luis
   ```

No changes to `run_smac_slurm.py` or `job.sh.j2` are needed.

---

## Monitoring and output

The script prints progress as it runs:

```
[1/6] Loading cluster profile: kisski
[2/6] Rendering SLURM script from job.sh.j2
[3/6] Connecting to u31890@glogin-gpu.hpc.gwdg.de
  Connected.
[4/6] Uploading and submitting
  Uploaded SLURM script → .../smac_job.sh
  sbatch output: Submitted batch job 16325750
  Job ID: 16325750
[5/6] Monitoring job
  Waiting for job 16325750 to complete (polling every 15s, timeout 600s) …
  [   0s] 16325750 PENDING None
  [  15s] 16325750 RUNNING None
  Job 16325750 is no longer in the queue.
[6/6] Fetching results
  SLURM STDOUT  (.../logs/smac_kisski_16325750.out)
  ...
  SLURM STDERR  (.../logs/smac_kisski_16325750.err)
  ...
Done.
```

Logs are also retained on the cluster at:

```
<scratch_dir>/logs/smac_<cluster>_<job-id>.out
<scratch_dir>/logs/smac_<cluster>_<job-id>.err
```

The polling timeout is 600 seconds (10 minutes). For a 5-minute
walltime job this is sufficient headroom. If the job is still in the
queue at timeout, the script prints a warning and proceeds to fetch
whatever logs exist.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `cluster 'kisski' not in clusters.json` | Profile missing or misspelled | Check `config/clusters.json` has a `"kisski"` key |
| `Permission denied (publickey)` | Wrong key path or key not accepted | Verify `key` in `clusters.json`; run `ssh-add <key>` |
| `python: can't open file '.../smac_worker.py'` | `repo_path` points to the wrong directory | Check that `repo_path` contains `src/smac_worker.py`; see note above about `dir.project` vs `dir.project/l3s-workshop-multicluster` |
| `conda activate` silently does nothing | Shell not initialised for conda in batch | Ensure the template includes `source $(conda info --base)/etc/profile.d/conda.sh` before `conda activate` |
| Job exits immediately with `NonZeroExitCode` | Worker error — check stderr | Read `<scratch_dir>/logs/<job>.err`; common causes are wrong Python path, missing packages, or DB not found |
| Empty stdout log | Job failed before `smac_worker.py` started | stderr log will have the error; fix environment setup |
| Timeout warning after 600s | Job stuck in queue or very slow node | Check `squeue -j <id>` manually on the login node; increase `POLL_TIMEOUT` in the script if needed |