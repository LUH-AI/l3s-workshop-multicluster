# Cluster configurations

Reference for the three HPC targets supported by this workshop pipeline.
The local Docker simulators (Cluster A/B) are covered in the main README —
this file covers the real clusters only.

Each cluster has an entry in `config/clusters.json` that `deploy.sh`,
`verify.sh`, and `sync.sh` read at runtime. The sections below document the
system-specific details behind those entries and the one-time setup each
participant needs to do on their own account.

---

## LUIS (Leibniz Universität Hannover / L3S)

**Status:** primary HPC target for WP5. Already wired into `config/clusters.json` and `sync_luis.yml`.

### Connection

```json
"luis": {
  "host": "login.cluster.uni-hannover.de",
  "user": "<your-username>",
  "key": "~/workshop-keys/runner_key",
  "type": "apptainer",
  "sync_path": "/bigwork/<your-username>/multicluster-workshop"
}
```

SSH command: `ssh <your-username>@login.cluster.uni-hannover.de`

### Storage layout

| Path | Purpose |
|---|---|
| `/bigwork/<username>/` | Working storage — use this for code and `.sif` images |
| `~` (home dir) | Small quota — do not store large files here |

`sync.sh` and `sync_luis.yml` both rsync to `/bigwork/<username>/multicluster-workshop/`,
matching the `sync_path` in `clusters.json`. The `apptainer pull` in `deploy.sh`
also lands the `.sif` file in the home directory by default — consider adjusting to
`/bigwork/<username>/project_<tag>.sif` if you hit quota limits.

### Environment and container runtime

- **Container:** Apptainer (`apptainer pull docker://ghcr.io/...` → `project_<tag>.sif`)
- **Python env:** Pixi (`pixi install` after `sync.sh`)
- **Job scheduler:** SLURM (`sbatch`)

### Login node vs. compute nodes

The login node is a shared gateway. It **kills long-running or resource-intensive processes automatically**.

| Allowed on login node | Must go through `sbatch` |
|---|---|
| `git pull`, `rsync`, `apptainer pull` | Training runs, benchmarks |
| `pixi install` | Anything using significant CPU/RAM/GPU |
| Short smoke tests (`apptainer run project.sif echo ok`) | PyExperimenter workers |

`cluster-config/luis-apptainer.sh` is designed to run on the login node —
it only does `apptainer pull` + a quick `apptainer run`, so it's fine there.
Any real workload needs an `sbatch` script (WP5 DoD requires one).

### One-time setup per participant

Each participant uses their **own** LUIS account — there is no shared setup.

1. Confirm your LUIS account is active:
   ```bash
   ssh <your-username>@login.cluster.uni-hannover.de
   ```
2. Copy the workshop SSH public key to your LUIS account:
   ```bash
   ssh-copy-id -i ~/workshop-keys/runner_key.pub <your-username>@login.cluster.uni-hannover.de
   ```
   Or manually append the contents of `~/workshop-keys/runner_key.pub` to
   `~/.ssh/authorized_keys` on LUIS.
3. Update `config/clusters.json` in your fork — replace both `<your-username>`
   placeholders in the `luis` entry.
4. Test that `scripts/sync.sh luis` completes without errors.

### Known pitfalls

| Problem | Fix |
|---|---|
| Login node kills your process | Move it to `sbatch` — see WP5 |
| `apptainer pull` fails with auth error | Run `apptainer registry login --username <gh-user> --password-stdin docker://ghcr.io` first (same as `docker login` but for Apptainer) |
| Disk quota exceeded | Use `/bigwork/<username>/` not `~` for `.sif` files and code |
| `sync_luis.yml` fails for one participant but not another | The `sync_path` in `clusters.json` must match each person's actual username — update your fork |

---

## KISSKI (AI Services / GWDG / HLRN)

**Status:** not yet in `config/clusters.json` — add an entry to wire it into the pipeline (see template below).

### Connection

```bash
ssh -i ~/.ssh/<key-file> <username>@glogin9.hlrn.de
```

Accounts are managed through [Academic Cloud](https://academiccloud.de/).
After creating an account there, upload your SSH public key at
`https://id.academiccloud.de/` — allow **~10 minutes** for the key to
sync across all frontend nodes before trying to connect.

### Storage layout

| Path | Purpose |
|---|---|
| `/scratch/usr/<username>/` | High-performance scratch — use for code and `.sif` images |
| `/bigwork/` | Also available on some nodes |
| `/home/users/<username>/` | Home directory — small quota |

### Environment and container runtime

- **Container:** Apptainer / Singularity
- **Job scheduler:** SLURM with GPU partitions

### `clusters.json` entry

```json
"kisski": {
  "host": "glogin9.hlrn.de",
  "user": "<your-username>",
  "key": "~/workshop-keys/runner_key",
  "type": "apptainer",
  "sync_path": "/scratch/usr/<your-username>/multicluster-workshop"
}
```

### One-time setup per participant

1. Create or log in to your Academic Cloud account at [academiccloud.de](https://academiccloud.de/).
2. Upload your SSH public key (`~/workshop-keys/runner_key.pub`) at `https://id.academiccloud.de/`.
3. Wait ~10 minutes, then test: `ssh -i ~/workshop-keys/runner_key <username>@glogin9.hlrn.de`
4. Add the `kisski` entry to `config/clusters.json` in your fork.

---

## PC2 (Paderborn Center for Parallel Computing)

**Status:** not yet in `config/clusters.json` — add an entry to wire it in (see template below).

### Systems

- **Noctua 2 (N2)** — primary HPC system
- **Otus** — additional system

### Access

Access requires an approved project. Project acronyms follow the format
`hpc-prf-<acronym>` (e.g. `hpc-prf-lsdfa`). Apply via
[PC²-JARDS](https://jards.pc2.uni-paderborn.de/) or the IMT service portal
(Paderborn University members only).

### Storage layout

| Path | Purpose |
|---|---|
| `/scratch/hpc-prf-<acronym>/` | Project scratch — use for code and `.sif` images |
| `$PC2DATA` | Environment variable pointing to the same scratch location |
| `/pc2/users/<group>/<username>` or `~` | Home directory |

### Environment and container runtime

- **Job scheduler:** SLURM
- **Container:** Apptainer

### `clusters.json` entry

PC2 paths include a project acronym, so you need an extra field. The
deploy scripts read only the standard fields (`host`, `user`, `key`,
`type`, `sync_path`) — encode the full path directly in `sync_path`:

```json
"pc2": {
  "host": "fe.noctua2.pc2.uni-paderborn.de",
  "user": "<your-username>",
  "key": "~/workshop-keys/runner_key",
  "type": "apptainer",
  "sync_path": "/scratch/hpc-prf-<acronym>/<your-username>/multicluster-workshop"
}
```

---

## Adding a new cluster

1. Add an entry to `config/clusters.json` using one of the templates above.
2. Set `type` to `apptainer` for any real HPC cluster.
3. Set `sync_path` to the writable scratch path for your account.
4. Run `scripts/preflight.sh` to check SSH reachability before running a full deploy.
5. For SLURM-based clusters: make sure your workload goes through `sbatch`, not the login node directly.

No changes to `deploy.sh`, `verify.sh`, or `sync.sh` are needed — they read everything from `clusters.json`.
