# Multicluster Workshop

Google Doc Link for documentation: https://docs.google.com/document/d/1NuCSgZUgpmlF0FqM69olTEBSOrzrL12ooCNQkdBXK_Q/edit?usp=sharing

A deployment pipeline that builds a container once, pushes it to GHCR, and
rolls it out via SSH to multiple clusters - a local Docker simulator
standing in for a real target during development, plus real HPC clusters
(LUIS, and eventually KISSKI/PC2) via Apptainer - with a central place to
check whether the right code is actually running everywhere.

The project is organized into three work packages, each documented in
full under `doc/`:

- **[WP1 - Proposed Solution](doc/wp1_proposed_solution.md)** - the
  pipeline itself: orchestration, containers, transport, runner hosting,
  secrets, verification, and central data storage. This is the design
  this README's practical steps below implement.
- **[WP2 - Alternative Solutions](doc/wp2_alternative_solutions.md)** -
  why a custom pipeline over adopting Ansible/Fabric/etc. wholesale.
- **[WP3 - Cluster Integration & Resource Optimization](doc/wp3.md)** -
  wiring up the rest of the real clusters, running experiments via
  PyExperimenter, and an AI-assisted scheduler (runtime predictor +
  allocator, method open) that decides where they run.

See also `doc/clusters.md` (per-cluster connection details for
LUIS/KISSKI/PC2) and `doc/ansible-hpc-automation.md` (the Ansible/Fabric
tooling referenced in WP2).

Additional documentation added with the WP3 starter code:

- **[Setup Guide](doc/setup.md)** - complete participant onboarding from
  a fresh machine to a working environment.
- **[Contributing Guidelines](doc/contributing.md)** - fork model, branch
  conventions, cross-WP coordination, and PR workflow.
- **[Feasibility Study: SMAC & AI Scheduling](doc/feasibility_study_smac_agentic_scheduling.md)** -
  four approaches to multi-cluster experiment distribution with tradeoffs
  and time estimates.

## Time budget: 3-4h total, across all three WPs

Each WP doc has its own "Definition of Done for this session" scoped to
that budget (WP1 §9, WP2's final section, WP3's "Scoped for a 3-4h
session") - short version: WP1 is mostly already built (two concrete
gaps left), WP2 is one hands-on comparison test, and WP3 runs entirely
against the Cluster A simulator and synthetic data, not real historical
data or PC2 (that needs an already-approved project - not something
arranged during the session). Do individual setup and confirm
`deploy.sh`/`verify.sh` work against Cluster A **before** splitting into
groups - everything else depends on that.

**If the prototype at the end is the priority and time runs short:**
WP3 doesn't need to wait on WP1 either: Component 2 has a local-sync
default for getting results into the central DB (see `doc/wp3.md`
Component 2) so it isn't blocked if WP1's live SSH tunnel isn't ready in
time - that tunnel is a nice-to-have upgrade, not a dependency.

## Model: everyone forks, everyone runs their own runner

This repo is public. There's no shared infrastructure for individual
development: each contributor **forks** it, runs their **own**
self-hosted GitHub Actions runner, and pushes to their **own** GHCR
namespace - see Individual setup below. `doc/wp1_proposed_solution.md` §4 describes
the target production setup (one runner, permanently on dedicated
hardware) - that's the deployment target this pipeline is designed for,
distinct from each contributor's own fork used for development.

## Architecture

```
Cloud services
  GitHub repo (private/your fork) --> GitHub Actions (build+push) --> GHCR (ghcr.io/<you>/project)
                    ^
                    | git push
Local machine (your laptop)
  Self-hosted runner (Docker + Actions) --> deploy scripts (deploy · sync · verify)
                                                  | SSH deploy              ^ image pull
                                                  v                        |
Target clusters
  Cluster A (Docker, local sim)   LUIS (Apptainer, HPC)
                                          |
                                          v
                                    PyExperimenter DB (SQLite / MySQL)
                                    (experiment grid, results, status)
```

## Repo structure

```
multicluster-workshop/
├── .github/workflows/
│   ├── build.yml            # on push to main: pushes ghcr.io/<you>/project:<sha> + :dummy, then pull-only deploy to every docker cluster in clusters.json
│   ├── deploy.yml            # workflow_dispatch: build + deploy to one cluster or all in clusters.json
│   ├── health.yml            # manual verify run (no deploy)
│   ├── sync.yml               # on push to main: rsync code to every cluster with a sync_path
│   └── test_runner.yml       # minimal smoke test for your self-hosted runner
├── config/
│   ├── clusters.json         # cluster-name -> {host, port, user, key, type, ...}
│   └── experiment_config.yaml # PyExperimenter experiment grid definition
├── scripts/
│   ├── deploy.sh             # ./scripts/deploy.sh <cluster-name> <image-tag> [--run] - pull only unless --run
│   ├── verify.sh             # ./scripts/verify.sh [tag] [cluster] - expected vs. actual per cluster (default: all)
│   ├── sync.sh                # ./scripts/sync.sh [cluster-name] - rsync source (default: every cluster with a sync_path)
│   ├── preflight.sh           # local tooling + SSH reachability checks (extended: Docker daemon, GHCR, Python tools)
│   ├── job.sh.j2              # Jinja2 SLURM job template (rendered by allocator.py)
│   └── create-deployment-info.sh  # optional: commit/tag/timestamp JSON (not wired into CI)
├── cluster-config/
│   └── local-docker.sh        # ./cluster-config/local-docker.sh <cluster-name> <pubkey> - local Docker simulator for any "type": "docker", localhost entry
├── doc/
│   ├── setup.md               # participant onboarding guide (start here if new)
│   ├── contributing.md        # fork model, branch conventions, cross-WP coordination
│   ├── feasibility_study_smac_agentic_scheduling.md  # four scheduling approaches for WP3
│   ├── wp1_proposed_solution.md
│   ├── wp2_alternative_solutions.md
│   ├── wp3.md
│   ├── clusters.md
│   └── ansible-hpc-automation.md
├── src/
│   ├── smac_worker.py         # SMAC benchmark worker (PyExperimenter) - replaces hello.py
│   ├── cluster_state.py       # query cluster capacity via SSH (sinfo/squeue)
│   ├── allocator.py           # multi-cluster experiment allocator
│   └── llm_scheduler.py       # optional: LLM-generated sbatch scripts / agentic scheduling
├── deploy.sh                    # wrapper -> scripts/deploy.sh (so `./deploy.sh ...` works too)
├── version.txt
├── requirements.txt             # in-container Python deps (smac, py-experimenter, jinja2, etc.)
├── requirements-dev.txt         # local/participant Python deps (fabric, ansible, pyyaml, etc.)
└── Dockerfile                   # Python 3.10 + swig/g++ + SMAC + PyExperimenter
```

## Individual setup

Do this before anything else - none of the scripts or workflows below can
be tested without it. You'll need Docker installed locally.

> **For a more detailed walkthrough, see [`doc/setup.md`](doc/setup.md).**

**Supported platforms:** macOS and Linux. The scripts need `bash`, `jq`,
`rsync`, `ssh` and `docker` (macOS: `brew install jq`; Debian/Ubuntu:
`sudo apt install jq rsync`). Windows works only via **WSL2** with Docker
Desktop's WSL backend - run the scripts *and* the self-hosted runner inside
WSL; PowerShell and Git Bash lack `rsync`/`jq`.

1. Fork this repo, clone your fork.
2. Nothing to edit for the image registry: the workflows push to
   `ghcr.io/<your-username>/project`, and `scripts/deploy.sh` derives the
   same owner from your fork's `origin` remote (override with
   `REGISTRY=ghcr.io/<owner>/project` if needed). After the first push
   (step 7's test run or any push to `main`), set the package to
   **public** (GitHub -> your profile -> Packages -> project -> Package
   settings) - otherwise running `deploy.sh` locally fails with
   `unauthorized` (see "Secrets" below).
3. Create a classic GitHub PAT with the **`write:packages`** scope (a
   fine-grained token does not reliably work with GHCR; `write:packages`
   already covers pulling too, so `read:packages` isn't needed
   separately). 
4. Generate a dedicated SSH key:
   ```bash
   ssh-keygen -t ed25519 -f ~/workshop-keys/runner_key -N ""
   ```
5. Store both as repo secrets. In your fork on GitHub: **Settings ->
   Secrets and variables -> Actions -> New repository secret**:
   - `GHCR_TOKEN` - the PAT from step 3
   - `SSH_PRIVATE_KEY` - the private key content, from `cat ~/workshop-keys/runner_key`

   Every workflow loads this straight into an `ssh-agent` at the start of
   the run (see `doc/wp1_proposed_solution.md` §5) - it never touches disk
   in CI. Running the scripts **locally** (outside a workflow) needs the
   same thing done by hand once per shell session:
   ```bash
   ssh-add ~/workshop-keys/runner_key
   ```
   `scripts/preflight.sh` checks for this and tells you if nothing's
   loaded.
6. Register a self-hosted runner in your fork (Settings -> Actions ->
   Runners -> New self-hosted runner) and run the setup commands GitHub
   shows you there. Keep it running (`./run.sh`).
7. Once a cluster simulator exists, the runner's **public** key needs to
   be in that container's `~/.ssh/authorized_keys` too - see "Adding the
   SSH key to Cluster A" under "Cluster config" below.
8. Install Python dependencies (Python 3.10 required for SMAC compatibility):
   ```bash
   pip install -r requirements.txt
   pip install -r requirements-dev.txt    # optional: fabric, ansible, jinja2
   ```

**Definition of Done:** `docker ps` works, `docker login ghcr.io` with your
token works, a test push to `ghcr.io/<you>/project:test` works, the runner
shows "Idle", and `.github/workflows/test_runner.yml` runs successfully.

## Cluster config (`config/clusters.json`)

One entry per cluster, keyed by name:

```json
{
  "cluster-a": { "host": "localhost", "port": 2222, "user": "clustera", "key": "~/workshop-keys/runner_key", "type": "docker", "sync_path": "/home/clustera/workshop" }
}
```

`sync_path` is optional: only clusters that have one are targeted by
`scripts/sync.sh`/`sync.yml`. Cluster A doesn't strictly need it (its
deployed image already contains the code), but having it lets the sync
pipeline be tested end-to-end locally.

`type` is `docker` (Cluster A, deployed via `docker pull`) or `apptainer`
(LUIS/KISSKI/PC2, deployed as `apptainer pull` into `project_<tag>.sif`;
after a successful pull every other `project_*.sif` in the home directory
is deleted, so each cluster holds exactly the current image).
A deploy only pulls by default - the image is placed on the cluster, not
started, since on HPC targets a run from `deploy.sh` would land on the
login node. Experiments are started separately (via `sbatch`); pass
`--run` (or tick "run after pull" in `deploy.yml`) to also run it once as
a smoke test. `deploy.sh`/`verify.sh` both read
this file - keep cluster names, `key` and `type` in sync with whatever
`cluster-config/*.sh` actually starts. See `doc/clusters.md` for the real
clusters' connection details and `doc/wp1_proposed_solution.md` §8 for how
to set up and inspect the local Cluster A simulator.

Build the local simulator with (port, user and container name come from
the `cluster-a` entry - any other `"type": "docker"` entry on `localhost`
works the same way):
```
./cluster-config/local-docker.sh cluster-a ~/workshop-keys/runner_key.pub
```

### Adding the SSH key to Cluster A

The `<public-key-file>` argument above **is** how the key gets in - the
script installs it into the container's `~/.ssh/authorized_keys` at
creation time, so this is normally a one-time thing per container.

If the container already exists and you need to add or refresh a key
without rebuilding it (e.g. you generated a new key after already
building the container):
```bash
cat ~/workshop-keys/runner_key.pub | docker exec -i cluster-a sh -c 'mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys'
```

## Placeholder image

`.github/workflows/build.yml` builds and pushes an image independently of
a full deploy run (Actions -> "Build placeholder container" -> Run
workflow, or automatically on every push to `main`), tagged both with the
current Git SHA and a stable `:dummy` tag:

```
ghcr.io/<you>/project:dummy
```

On a push (not a manual run) it then also pulls that `<sha>` image onto
**every `"type": "docker"` cluster in `config/clusters.json`** - one job
per cluster, `deploy.sh` without `--run`, followed by `verify.sh` for
those clusters - so e.g. Cluster A always has the latest commit ready.
Nothing is started. HPC (`apptainer`) clusters are deliberately left
out: an `apptainer pull` on a shared login node per push is too heavy,
and it would replace the `.sif` a running experiment series uses -
deploy those manually via `deploy.yml`.

Useful whenever you need *something* in GHCR to point `deploy.sh`/
`verify.sh` at without waiting on a full `deploy.yml` run. Reuses the same
`GHCR_TOKEN` secret as `deploy.yml` - no extra setup. If you want others
to `docker pull` it without a token, set the GHCR package visibility to
public afterwards (GitHub -> your profile -> Packages -> project ->
Package settings).

## Experiment orchestration (WP3 starter code)

The repo includes starter code for running SMAC benchmarks across
clusters, managed by PyExperimenter as the central experiment database:

1. **`config/experiment_config.yaml`** defines the experiment grid
   (algorithm × dataset × seed). PyExperimenter creates one database
   row per combination.
2. **`src/smac_worker.py`** runs inside each SLURM job - it claims an
   unclaimed row, runs SMAC, and writes the result back.
3. **`src/allocator.py`** reads experiment and cluster state, decides
   how many workers to start on each cluster, and generates SLURM
   scripts from `scripts/job.sh.j2`.
4. **`src/llm_scheduler.py`** (optional) replaces template rendering
   with LLM-generated scripts or wraps the allocator in an agentic loop.

Quick test (no cluster needed):

```bash
python src/allocator.py --plan       # see experiment allocation
python src/cluster_state.py          # see cluster status
python src/smac_worker.py            # run SMAC benchmarks (creates experiments/ dir)
```

See `doc/feasibility_study_smac_agentic_scheduling.md` for four
scheduling approaches with time estimates and a decision table.

## Secrets

Two repo secrets (Settings -> Secrets and variables -> Actions in your
fork), both consumed by the workflows, not committed anywhere:

| Secret | Used for | Required? |
|---|---|---|
| `GHCR_TOKEN` | `docker login` when pushing the build in `deploy.yml`/`build.yml`; optionally reused by `deploy.sh` to log in on the *target* cluster before pulling | Always, for the push. For pulling: only if your GHCR package is **private** - the simplest alternative is making it public, then no pull-side auth is needed at all |
| `SSH_PRIVATE_KEY` | loaded into an `ssh-agent` at the start of every job that needs SSH (deploy, verify, sync) - never written to disk, see `doc/wp1_proposed_solution.md` §5 | Required for CI. For local use, `ssh-add ~/workshop-keys/runner_key` once per shell session does the same job |

Pull-side auth for a private package is needed on **every** cluster,
including the local simulator: it shares the host's `docker.sock`, but
registry credentials belong to the docker *client* inside the container,
so your laptop's `docker login` does **not** carry over. The workflows
handle this by passing `GHCR_USER`/`GHCR_TOKEN` to `deploy.sh`. Locally,
either make the package public (recommended for the workshop) or run
`GHCR_USER=<you> GHCR_TOKEN=<token> ./scripts/deploy.sh ...`.

## Known pitfalls

| Problem | Fix |
|---|---|
| `permission_denied: create_package` on GHCR push | Wrong namespace - push from your own fork (the workflows use its owner) |
| `unauthorized` when running `deploy.sh` locally | Package is private and the simulator has no GHCR login of its own - make the package public, or pass `GHCR_USER`/`GHCR_TOKEN` |
| GHCR login fails with a fine-grained token | Use a classic PAT with `write:packages` (add `repo` only if your fork is private) |
| `docker: permission denied ... docker.sock` | Linux: `sudo usermod -aG docker $USER`, then log out and back in. In the simulator: GID mismatch - `cluster-config/local-docker.sh` fixes this at container start |
| `client version 1.41 is too old` in simulator | Rebuild: `docker rm -f cluster-a && ./cluster-config/local-docker.sh cluster-a ~/workshop-keys/runner_key.pub` |
| YAML workflow: `No event triggers defined in on` | Usually a copy-paste formatting issue - rewrite with `cat > file << 'EOF' ... EOF` |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` when connecting to Cluster A | Rebuilding the simulator generates new host keys. `cluster-config/local-docker.sh` removes the stale entry itself; for an older container run `ssh-keygen -R "[localhost]:2222"` once |
| SSH key auth doesn't work / password prompt | `ssh-add ~/workshop-keys/runner_key` (key not loaded in agent - resets every new terminal) |
| `usermod` not found on macOS | Docker Desktop handles the docker group itself, no setup needed |
| `pip install smac` fails with build error | Install build tools: `brew install swig` (macOS) or `sudo apt install swig g++` (Ubuntu) |
| PyExperimenter `Missing key Database` | Check `config/experiment_config.yaml` uses `Database:` nesting - see the file for correct format |
| PyExperimenter `Keyfield type must be a string` | Quote all `type` and integer `values` in the YAML: `type: "INT"`, values: `- "0"` |
| `smac_worker.py` crashes with codecarbon TypeError | Already fixed: `use_codecarbon=False` in the PyExperimenter constructor |
| `smac_worker.py` crashes with DB locked | SQLite doesn't support concurrent writes - switch to MySQL for multi-cluster |
| LUIS login node kills processes | Only run short tests there; real workloads go through `sbatch`/SLURM |
