# Multicluster Workshop

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
```

## Repo structure

```
multicluster-workshop/
├── .github/workflows/
│   ├── build.yml            # pushes ghcr.io/<you>/project:dummy - a placeholder image, independent of a full deploy
│   ├── deploy.yml            # workflow_dispatch: build + deploy to Cluster A
│   ├── health.yml            # manual verify run (no deploy)
│   ├── sync_luis.yml         # on push to main: rsync code to LUIS
│   └── test_runner.yml       # minimal smoke test for your self-hosted runner
├── config/
│   └── clusters.json         # cluster-name -> {host, port, user, key, type, ...}
├── scripts/
│   ├── deploy.sh             # ./scripts/deploy.sh <cluster-name> <image-tag>
│   ├── verify.sh             # ./scripts/verify.sh [tag] - expected vs. actual per cluster
│   ├── sync.sh                # ./scripts/sync.sh <cluster-name> - rsync source (default: luis)
│   ├── preflight.sh           # local tooling + SSH reachability checks
│   └── create-deployment-info.sh  # optional: commit/tag/timestamp JSON (not wired into CI)
├── cluster-config/
│   ├── local-docker.sh        # generic local Docker "cluster" node (sshd + docker CLI)
│   ├── cluster-a-docker.sh    # spin up Cluster A (port 2222, user clustera)
│   └── luis-apptainer.sh      # test pull+run on a real LUIS login node
├── doc/
│   ├── wp1_proposed_solution.md
│   ├── wp2_alternative_solutions.md
│   ├── wp3.md
│   ├── clusters.md
│   └── ansible-hpc-automation.md
├── src/hello.py                # placeholder workload (WP3 Component 2 replaces this with PyExperimenter)
├── deploy.sh                    # wrapper -> scripts/deploy.sh (so `./deploy.sh ...` works too)
├── version.txt
├── requirements.txt
└── Dockerfile
```

## Individual setup

Do this before anything else - none of the scripts or workflows below can
be tested without it. You'll need Docker installed locally.

1. Fork this repo, clone your fork.
2. In `scripts/deploy.sh` and `scripts/verify.sh`, change
   `REGISTRY="ghcr.io/<org>/project"` to your own GitHub username - skip
   this and pushes fail with `permission_denied: create_package` (you'd be
   creating a package under someone else's namespace).
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

**Definition of Done:** `docker ps` works, `docker login ghcr.io` with your
token works, a test push to `ghcr.io/<you>/project:test` works, the runner
shows "Idle", and `.github/workflows/test_runner.yml` runs successfully.

## Cluster config (`config/clusters.json`)

One entry per cluster, keyed by name:

```json
{
  "cluster-a": { "host": "localhost", "port": 2222, "user": "clustera", "key": "~/workshop-keys/runner_key", "type": "docker" }
}
```

`type` is `docker` (Cluster A, deployed via `docker pull && docker run`)
or `apptainer` (LUIS/KISSKI/PC2, deployed as `apptainer pull` into
`project_<tag>.sif` + `apptainer run`). `deploy.sh`/`verify.sh` both read
this file - keep cluster names, `key` and `type` in sync with whatever
`cluster-config/*.sh` actually starts. See `doc/clusters.md` for the real
clusters' connection details and `doc/wp1_proposed_solution.md` §8 for how
to set up and inspect the local Cluster A simulator.

Build the local simulator with:
```
./cluster-config/cluster-a-docker.sh ~/workshop-keys/runner_key.pub
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

Useful whenever you need *something* in GHCR to point `deploy.sh`/
`verify.sh` at without waiting on a full `deploy.yml` run. Reuses the same
`GHCR_TOKEN` secret as `deploy.yml` - no extra setup. If you want others
to `docker pull` it without a token, set the GHCR package visibility to
public afterwards (GitHub -> your profile -> Packages -> project ->
Package settings).

## Secrets

Two repo secrets (Settings -> Secrets and variables -> Actions in your
fork), both consumed by the workflows, not committed anywhere:

| Secret | Used for | Required? |
|---|---|---|
| `GHCR_TOKEN` | `docker login` when pushing the build in `deploy.yml`/`build.yml`; optionally reused by `deploy.sh` to log in on the *target* cluster before pulling | Always, for the push. For pulling: only if your GHCR package is **private** - the simplest alternative is making it public, then no pull-side auth is needed at all |
| `SSH_PRIVATE_KEY` | loaded into an `ssh-agent` at the start of every job that needs SSH (deploy, verify, sync) - never written to disk, see `doc/wp1_proposed_solution.md` §5 | Required for CI. For local use, `ssh-add ~/workshop-keys/runner_key` once per shell session does the same job |

The local Docker simulator (Cluster A) never needs pull-side auth: it
shares the host's `docker.sock`, so it inherits whatever `docker login` you
already ran on your laptop. A genuinely separate remote cluster (a real
Cluster A, or LUIS/KISSKI/PC2) does need it if its package is private.

## Known pitfalls

| Problem | Fix |
|---|---|
| `permission_denied: create_package` on GHCR push | Wrong namespace - set `REGISTRY`/fork owner to your own username |
| GHCR login fails with a fine-grained token | Use a classic PAT with `write:packages` (add `repo` only if your fork is private) |
| `docker: permission denied ... docker.sock` in the simulator | GID mismatch between host socket and container group - `cluster-config/local-docker.sh` fixes this at container start |
| YAML workflow: `No event triggers defined in on` | Usually a copy-paste formatting issue - rewrite with `cat > file << 'EOF' ... EOF` |
| SSH key auth doesn't work | Check permissions: `chmod 700 ~/.ssh`, `chmod 600 ~/.ssh/authorized_keys` |
| `usermod` not found on macOS | Docker Desktop handles the docker group itself, no setup needed |
| LUIS login node kills processes | Only run short tests there; real workloads go through `sbatch`/SLURM |
