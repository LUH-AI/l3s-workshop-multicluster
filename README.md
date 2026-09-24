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
  the remaining/ongoing work: wiring up the rest of the real clusters,
  running real experiments via PyExperimenter, and an AI-assisted
  scheduler (LightGBM + ILP) that decides where they run.

See also `doc/clusters.md` (per-cluster connection details for
LUIS/KISSKI/PC2) and `doc/ansible-hpc-automation.md` (the Ansible/Fabric
tooling referenced in WP2).

## Model: everyone forks, everyone runs their own runner

This repo is public. There's no shared infrastructure for individual
development: each contributor **forks** it, runs their **own**
self-hosted GitHub Actions runner, and pushes to their **own** GHCR
namespace - see WP0 below. `doc/wp1_proposed_solution.md` §4 describes
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

## WP0: individual setup

Do this before anything else - none of the scripts or workflows below can
be tested without it. See `doc/wp1_proposed_solution.md` §0 for the short
version of what must be true; this is the step-by-step.

1. Fork this repo, clone your fork
2. In `scripts/deploy.sh` and `scripts/verify.sh`, change
   `REGISTRY="ghcr.io/<org>/project"` to your own GitHub username - skip
   this and pushes fail with `permission_denied: create_package` (you'd be
   creating a package under someone else's namespace)
3. Create a classic GitHub PAT with `write:packages` + `repo` scopes (a
   fine-grained token does not reliably work with GHCR) and store it as the
   `GHCR_TOKEN` secret in your fork's repo settings (Settings -> Secrets and
   variables -> Actions)
4. Generate a dedicated SSH key: `ssh-keygen -t ed25519 -f ~/workshop-keys/runner_key -N ""` -
   store its **private** key content as the `SSH_PRIVATE_KEY` secret too (every
   workflow writes it to `~/workshop-keys/runner_key` at the start of each
   run, so this works even on a freshly set up runner - see
   `doc/wp1_proposed_solution.md` §5 for why that's a temporary state, not
   the target design)
5. Register a self-hosted runner in your fork (Settings -> Actions ->
   Runners) and keep it running (`./run.sh`, or install it as a service)

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
| `SSH_PRIVATE_KEY` | written to `~/workshop-keys/runner_key` at the start of every job that needs SSH (deploy, verify, sync) | Recommended, so the workflow doesn't depend on that file already existing on whatever machine runs your runner. `doc/wp1_proposed_solution.md` §5 describes the target design (RAM-only via `ssh-agent`, never written to disk) - not yet implemented |

The local Docker simulator (Cluster A) never needs pull-side auth: it
shares the host's `docker.sock`, so it inherits whatever `docker login` you
already ran on your laptop. A genuinely separate remote cluster (a real
Cluster A, or LUIS/KISSKI/PC2) does need it if its package is private.

## Known pitfalls

| Problem | Fix |
|---|---|
| `permission_denied: create_package` on GHCR push | Wrong namespace - set `REGISTRY`/fork owner to your own username |
| GHCR login fails with a fine-grained token | Use a classic PAT with `write:packages` + `repo` |
| `docker: permission denied ... docker.sock` in the simulator | GID mismatch between host socket and container group - `cluster-config/local-docker.sh` fixes this at container start |
| YAML workflow: `No event triggers defined in on` | Usually a copy-paste formatting issue - rewrite with `cat > file << 'EOF' ... EOF` |
| SSH key auth doesn't work | Check permissions: `chmod 700 ~/.ssh`, `chmod 600 ~/.ssh/authorized_keys` |
| `usermod` not found on macOS | Docker Desktop handles the docker group itself, no setup needed |
| LUIS login node kills processes | Only run short tests there; real workloads go through `sbatch`/SLURM |
