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

## Model: everyone forks, Fabric provides the environment

This repo is public. There's no shared infrastructure for individual
development: each contributor **forks** it and pushes to their **own**
GHCR namespace - see Individual setup below. No GitHub Actions runner is
involved: `fabfile.py` builds the runtime **environment** image (Python +
SMAC/PyExperimenter, no project code) on your machine, pushes it to GHCR
and puts it onto every cluster over SSH - Docker or Apptainer per
cluster. Getting the project *code* onto the clusters is a separate step
and not part of this pipeline.

## Architecture

```
Local machine (your laptop)
  fab release:  build (only if Dockerfile/requirements.txt changed) --push--> GHCR (ghcr.io/<you>/project:env-<hash>)
                deploy (only where missing)  --SSH-->  clusters pull from GHCR
                                                                   |
Target clusters                                                    v
  Cluster A (docker, local sim)   LUIS (apptainer, HPC)     runtime per cluster: "type" in clusters.json
                                          |
                                          v
                                    PyExperimenter DB (SQLite / MySQL)
                                    (experiment grid, results, status)
```

## Repo structure

```
multicluster-workshop/
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
├── fabfile.py                   # Fabric: build/deploy/verify the environment image on all clusters (`fab release`)
├── .githooks/                   # post-commit/-merge/-rewrite: auto `fab release` on env changes (`fab install-hooks`)
├── version.txt
├── requirements.txt             # in-container Python deps (smac, py-experimenter, jinja2, etc.)
├── requirements-dev.txt         # local/participant Python deps (fabric, ansible, pyyaml, etc.)
└── Dockerfile                   # environment only: Python 3.10 + swig/g++ + SMAC + PyExperimenter (no project code)
```

## Individual setup

Do this before anything else - none of the tasks or scripts below can
be tested without it. You'll need Docker installed locally.

> **For a more detailed walkthrough, see [`doc/setup.md`](doc/setup.md).**

**Supported platforms:** macOS and Linux. The scripts need `bash`, `jq`,
`rsync`, `ssh` and `docker` (macOS: `brew install jq`; Debian/Ubuntu:
`sudo apt install jq rsync`). Windows works only via **WSL2** with Docker
Desktop's WSL backend - run the scripts and `fab` inside WSL; PowerShell and Git Bash lack `rsync`/`jq`.

1. Fork this repo, clone your fork.
2. Nothing to edit for the image registry: `fabfile.py` pushes to
   `ghcr.io/<your-username>/project`, deriving the owner from your fork's
   `origin` remote (override with `REGISTRY=ghcr.io/<owner>/project` if
   needed). After the first `fab build`, set the package to **public** (GitHub -> your profile ->
   Packages -> project -> Package settings) - otherwise deploying fails
   with `unauthorized` unless you export `GHCR_TOKEN` (see "Secrets" below).
3. Create a classic GitHub PAT with the **`write:packages`** scope (a
   fine-grained token does not reliably work with GHCR; `write:packages`
   already covers pulling too, so `read:packages` isn't needed
   separately). 
4. Generate a dedicated SSH key:
   ```bash
   ssh-keygen -t ed25519 -f ~/workshop-keys/runner_key -N ""
   ```
5. Log in to GHCR with the PAT once (`docker login ghcr.io -u <you>`),
   or export it as `GHCR_TOKEN` (plus `GHCR_USER`) - `fab` then also uses
   it for pulls of a private package on the clusters. Load the SSH key
   once per shell session:
   ```bash
   ssh-add ~/workshop-keys/runner_key
   ```
   (`fab` also falls back to the `key` file from `clusters.json`;
   `scripts/preflight.sh` checks the agent and tells you if nothing's
   loaded.)
6. Once a cluster simulator exists, the **public** key needs to be in
   that container's `~/.ssh/authorized_keys` - see "Adding the SSH key to
   Cluster A" under "Cluster config" below.
7. Install Python dependencies (Python 3.10 required for SMAC compatibility):
   ```bash
   pip install -r requirements.txt
   pip install -r requirements-dev.txt    # fabric (needed for deploying), ansible, jinja2
   ```

**Definition of Done:** `docker ps` works, `docker login ghcr.io` with your
token works, and `fab release --cluster cluster-a` ends with Cluster A
showing ✓.

## Cluster config (`config/clusters.json`)

One entry per cluster, keyed by name:

```json
{
  "cluster-a": { "host": "localhost", "port": 2222, "user": "clustera", "key": "~/workshop-keys/runner_key", "type": "docker", "sync_path": "/home/clustera/workshop" }
}
```

**Personal entries** (your own LUIS username etc.) go into
`config/clusters.local.json` - gitignored, same format, merged per cluster
over `clusters.json` by `fabfile.py` (the bash scripts only read
`clusters.json`). That way a shared repo's config stays untouched:

```json
{
  "luis": { "host": "login.cluster.uni-hannover.de", "user": "<your-username>",
            "key": "~/workshop-keys/runner_key", "type": "apptainer" }
}
```

`sync_path` is optional and only used by `scripts/sync.sh` (code sync -
not part of the Fabric environment pipeline).

`type` is `docker` (Cluster A, deployed via `docker pull`) or `apptainer`
(LUIS/KISSKI/PC2, deployed as `apptainer pull` into `project_<tag>.sif`;
after a successful pull every other `project_*.sif` in the home directory
is deleted, so each cluster holds exactly the current image).
A deploy only pulls by default - the image is placed on the cluster, not
started, since on HPC targets a run from `deploy.sh` would land on the
login node. Experiments are started separately (via `sbatch`); pass
`--run` to `fab deploy` (or `deploy.sh`) to also run it once as
a smoke test. `fabfile.py` and `deploy.sh`/`verify.sh` all read
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

## Providing the environment: Fabric (`fabfile.py`)

The image is only the runtime environment - the Dockerfile installs
`requirements.txt` and copies no project code. Its tag is a hash of
`Dockerfile` + `requirements.txt` (e.g. `env-1de35243e5e8`), so it only
changes when the environment does. From the repo root (`pip install -r
requirements-dev.txt` first):

```bash
fab release                               # build if needed, deploy where needed, verify - all clusters
fab release --cluster cluster-a --run     # one cluster (or a,b,c), plus an environment smoke test
fab verify                                # does every cluster have the current environment?
fab tag                                   # which image/tag the current files map to
fab build / fab deploy                    # the individual steps; --force to redo anyway
```

- `fab build` skips the build if `env-<hash>` is already in GHCR.
- `fab deploy` skips every cluster that already has it (`~/.deployed_tag`
  plus the image/`.sif` actually present), so re-running is cheap and an
  HPC cluster's `.sif` is only replaced when the environment really
  changed.
- The runtime per cluster comes from `"type"` in `config/clusters.json`:
  `docker` -> `docker pull`, `apptainer` -> `apptainer pull
  project_<tag>.sif`. After a successful pull each cluster keeps only the
  current environment (older `.sif` files / older image tags are removed -
  on the Cluster A simulator that's your laptop's Docker, since it shares
  `docker.sock`).
- The code is bound in at run time, e.g. `apptainer exec --bind
  <repo_path>:/app ... python /app/src/smac_worker.py` (see
  `scripts/job.sh.j2`).

GHCR auth: export `GHCR_TOKEN` (and `GHCR_USER`, default = repo owner) for
pulls of a private package - it's sent over SSH stdin for that one pull,
nothing is stored on the cluster; without it pulls run unauthenticated and
the push uses your `docker login`. `fab build` uses a dedicated
multi-arch buildx builder (`multicluster`, created on first use); on plain
Linux Docker install QEMU first (`docker run --privileged --rm
tonistiigi/binfmt --install all`) or pass `--platforms linux/amd64`.

### Automatic: git hooks

```bash
fab install-hooks                                   # once per clone
git config multicluster.autoClusters cluster-a      # optional: which clusters (default cluster-a; "a,b" or "all")
git config multicluster.registry ghcr.io/<you>/project   # optional: only if origin isn't your fork
```

From then on, every commit, `git pull`/merge or rebase that changes
`Dockerfile` or `requirements.txt` (`ENV_FILES` in `fabfile.py`) starts
`fab release` in the background - nothing happens for any other commit.
Output goes to `.fab-release.log` (plus a macOS notification when done).
Only one release runs at a time; a change arriving meanwhile gets a
follow-up run. Uncommitted edits to an environment file skip the run
until they're committed.

HPC clusters are left out by default on purpose: a new `.sif` would
replace the one a running experiment series uses - deploy those with
`fab release --cluster luis` when it suits you, or add them to
`autoClusters`. Hooks run without your shell's exports, so `GHCR_TOKEN`
isn't available there: make the package public, or the automatic pull on
the clusters fails with `unauthorized`. Turn it off with `git config
--unset core.hooksPath`.

`scripts/deploy.sh`/`verify.sh` still work for manual use, but default to
the Git SHA as tag - pass the `env-...` tag from `fab tag` explicitly.

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

Nothing is stored in GitHub. Both credentials stay on your machine:

| Credential | Used for |
|---|---|
| `GHCR_TOKEN` (classic PAT, `write:packages`) - via `docker login ghcr.io` or exported | `fab build`'s push; exported, also pulls of a **private** package on the clusters - the simplest alternative is making the package public, then no pull-side auth is needed at all |
| SSH key (`~/workshop-keys/runner_key`) - `ssh-add` it once per shell session | Every `fab deploy/verify` (and the scripts) |

Pull-side auth for a private package is needed on **every** cluster,
including the local simulator: it shares the host's `docker.sock`, but
registry credentials belong to the docker *client* inside the container,
so your laptop's `docker login` does **not** carry over.

## Known pitfalls

| Problem | Fix |
|---|---|
| `permission_denied: create_package` on GHCR push | Wrong namespace - push from your own fork (the build uses its owner) |
| `unauthorized` when running `deploy.sh` locally | Package is private and the simulator has no GHCR login of its own - make the package public, or pass `GHCR_USER`/`GHCR_TOKEN` |
| GHCR login fails with a fine-grained token | Use a classic PAT with `write:packages` (add `repo` only if your fork is private) |
| `docker: permission denied ... docker.sock` | Linux: `sudo usermod -aG docker $USER`, then log out and back in. In the simulator: GID mismatch - `cluster-config/local-docker.sh` fixes this at container start |
| `client version 1.41 is too old` in simulator | Rebuild: `docker rm -f cluster-a && ./cluster-config/local-docker.sh cluster-a ~/workshop-keys/runner_key.pub` |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` when connecting to Cluster A | Rebuilding the simulator generates new host keys. `cluster-config/local-docker.sh` removes the stale entry itself; for an older container run `ssh-keygen -R "[localhost]:2222"` once |
| SSH key auth doesn't work / password prompt | `ssh-add ~/workshop-keys/runner_key` (key not loaded in agent - resets every new terminal) |
| `usermod` not found on macOS | Docker Desktop handles the docker group itself, no setup needed |
| `pip install smac` fails with build error | Install build tools: `brew install swig` (macOS) or `sudo apt install swig g++` (Ubuntu) |
| PyExperimenter `Missing key Database` | Check `config/experiment_config.yaml` uses `Database:` nesting - see the file for correct format |
| PyExperimenter `Keyfield type must be a string` | Quote all `type` and integer `values` in the YAML: `type: "INT"`, values: `- "0"` |
| `smac_worker.py` crashes with codecarbon TypeError | Already fixed: `use_codecarbon=False` in the PyExperimenter constructor |
| `smac_worker.py` crashes with DB locked | SQLite doesn't support concurrent writes - switch to MySQL for multi-cluster |
| LUIS login node kills processes | Only run short tests there; real workloads go through `sbatch`/SLURM |
