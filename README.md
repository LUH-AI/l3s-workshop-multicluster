# Multicluster Workshop

Seamless ML experiment deployment from laptop to HPC clusters. A 3-4 hour
hands-on workshop where small groups build a lightweight, modular pipeline
that builds a container image, pushes it to GHCR, and deploys it to two
local Docker "clusters" plus (optionally) a real HPC cluster (LUIS, via
Apptainer).

## Model: everyone forks, everyone runs their own runner

This repo is public for the duration of the workshop. There's no shared
infrastructure: each participant **forks** it, runs their **own**
self-hosted GitHub Actions runner on their own laptop, and pushes to their
**own** GHCR namespace. Nobody shares credentials or namespaces with anyone
else - see WP0 below.

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
  Cluster A (Docker, local sim)   Cluster B (Docker, local sim)   LUIS (Apptainer, HPC)
```

## Repo structure

```
multicluster-workshop/
├── .github/workflows/
│   ├── deploy.yml          # workflow_dispatch: build + deploy to Cluster A/B
│   ├── health.yml          # manual verify run (no deploy)
│   ├── sync_luis.yml       # on push to main: rsync code to LUIS (WP5)
│   └── test_runner.yml     # minimal smoke test for your self-hosted runner
├── config/
│   └── clusters.json       # cluster-name -> {host, port, user, key, type, ...}
├── scripts/
│   ├── deploy.sh           # ./scripts/deploy.sh <cluster-name> <image-tag>
│   ├── verify.sh           # ./scripts/verify.sh [tag] - expected vs. actual per cluster
│   ├── sync.sh             # ./scripts/sync.sh <cluster-name> - rsync source (default: luis)
│   ├── preflight.sh        # local tooling + SSH reachability checks
│   └── create-deployment-info.sh  # optional: commit/tag/timestamp JSON (not wired into CI)
├── cluster-config/
│   ├── local-docker.sh     # generic local Docker "cluster" node (sshd + docker CLI)
│   ├── cluster-a-docker.sh # spin up Cluster A (port 2222, user clustera)
│   ├── cluster-b-docker.sh # spin up Cluster B (port 2223, user clusterb)
│   └── luis-apptainer.sh   # test pull+run on a real LUIS login node
├── src/hello.py             # placeholder workload (WP6 replaces this with PyExperimenter)
├── deploy.sh                 # wrapper -> scripts/deploy.sh (so `./deploy.sh ...` works too)
├── version.txt
├── requirements.txt
└── Dockerfile
```

## WP0: individual setup (do this before group work starts)

Not a group task - everyone does this on their own first, otherwise nobody
can test anything.

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
   run, so this works even on a freshly set up runner)
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

`type` is `docker` (Cluster A/B, deployed via `docker pull && docker run`)
or `apptainer` (LUIS, deployed as `apptainer pull` into
`project_<tag>.sif` + `apptainer run`). `deploy.sh`/`verify.sh` both read
this file - keep cluster names, `key` and `type` in sync with whatever
`cluster-config/*.sh` actually starts.

Build the two local simulators with:
```
./cluster-config/cluster-a-docker.sh ~/workshop-keys/runner_key.pub
./cluster-config/cluster-b-docker.sh ~/workshop-keys/runner_key.pub
```

## Secrets

Two repo secrets (Settings -> Secrets and variables -> Actions in your
fork), both consumed by the workflows, not committed anywhere:

| Secret | Used for | Required? |
|---|---|---|
| `GHCR_TOKEN` | `docker login` when pushing the build in `deploy.yml`; optionally reused by `deploy.sh` to log in on the *target* cluster before pulling | Always, for the push. For pulling: only if your GHCR package is **private** - the simplest alternative is making it public, then no pull-side auth is needed at all |
| `SSH_PRIVATE_KEY` | written to `~/workshop-keys/runner_key` at the start of every job that needs SSH (deploy, verify, sync) | Recommended, so the workflow doesn't depend on that file already existing on whatever machine runs your runner |

The local Docker simulators (Cluster A/B) never need pull-side auth: they
share the host's `docker.sock`, so they inherit whatever `docker login` you
already ran on your laptop. A genuinely separate remote cluster (a real
Cluster A/B, or LUIS) does need it if its package is private.

## Work packages & Definition of Done

| WP | Owns | Scope |
|---|---|---|
| WP0 | everyone | individual setup (see above) - prerequisite, no group scope |
| WP1 | `.github/workflows/deploy.yml` | `workflow_dispatch` with per-cluster checkboxes + build toggle, independent `if:` jobs, merges WP2-WP4 into one workflow |
| WP2 | `Dockerfile` | image build, Git-SHA + digest tagging, GHCR push, Docker-vs-Apptainer write-up |
| WP3 | `scripts/deploy.sh` | SSH-based deploy to Cluster A/B, optional `scripts/sync.sh` |
| WP4 | `scripts/verify.sh` | compares Git commit vs. what's actually running per cluster |
| WP5 | LUIS/Apptainer | same deploy logic as WP3 but Apptainer + `sbatch`, tested on each member's own LUIS account |
| WP6 (stretch) | PyExperimenter | replaces `hello.py` with a real parameterized workload, per-cluster SQLite (no shared DB - see below) |

**WP1 DoD:** checkboxes for Cluster A/B + build toggle defined (LUIS is
deliberately not in this workflow); each cluster has its own `if:` job;
jobs call `deploy.sh`/`verify.sh` with agreed parameters; a failure in one
cluster job doesn't block the other; runs end-to-end at least once on your
own runner; summary shows per-cluster success/failure; no secrets in
plaintext.

**WP2 DoD:** `docker build` succeeds locally; image tagged with Git SHA
(not just `latest`); push to `ghcr.io/<you>/project:<sha>` works from the
Action; digest readable via `docker inspect --format='{{index .RepoDigests 0}}'`
and documented; container runs locally with visible output; short
Docker-vs-Apptainer write-up (daemon/root, image format, execution
model/SLURM); classic-PAT pitfall documented.

**WP3 DoD:** dedicated SSH key used (not your personal one);
`deploy.sh cluster-a <tag>` and `deploy.sh cluster-b <tag>` succeed against
the local simulators; exit code unambiguous (0/success, ≠0/failure);
restricted SSH access discussed (`command=` restriction, even if not
implemented in the simulator); Docker-socket GID mismatch pitfall
documented (see `cluster-config/local-docker.sh` for one fix); unreachable
cluster / missing image produce a clear error instead of a crash.

**WP4 DoD:** `verify.sh` with no argument uses `git rev-parse --short HEAD`
as the comparison value; `verify.sh <tag>` compares against an explicit
tag; three states distinguished (✓ up to date / OUTDATED / UNREACHABLE -
unreachable ≠ outdated); works when only some clusters are deployed;
exit code reflects overall status; tested against Cluster A including a
deliberately triggered OUTDATED case.

**WP5 DoD:** `deploy.sh luis <tag>` pulls and converts to `.sif` on the
login node; `sync.sh luis` transfers code to `/bigwork/<you>/...`; the
push-triggered `sync_luis.yml` syncs on every commit, tested by at least
two group members on their own accounts; an `sbatch` template runs the
container as a real (non-login-node) job; login-node-vs-compute-node is
documented; setup steps are clear enough for someone outside the group to
follow on their own account; at least two members verified the full flow
end-to-end individually.

**WP6 DoD (optional):** minimal PyExperimenter setup runs inside the
container on at least one cluster; results go to a local SQLite file per
cluster, **not** a shared MySQL instance (a shared DB reachable from
Cluster A, B *and* LUIS reintroduces the exact firewall/network dependency
that caused delays with LUIS); a small script pulls results back per
cluster (reuse the `sync.sh` pattern); documented why a shared DB was
avoided.

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

## Suggested timeline (3.5h)

| Time | Activity |
|---|---|
| 0:00-0:15 | Kick-off, confirm WP0 done, assign WP1-WP5 |
| 0:15-1:15 | Group work using local Cluster A/B simulators (WP1-WP4) or own LUIS account (WP5) |
| 1:15-1:30 | Break + sync (interface mismatches between `deploy.sh`/`verify.sh` params) |
| 1:30-2:30 | Integration: wire WP1-WP4 together, test end-to-end against Cluster A |
| 2:30-3:00 | Harden: add Cluster B, integrate WP5, error handling |
| 3:00-3:30 | Demo + retrospective |
