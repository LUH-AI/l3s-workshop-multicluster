# WP1: Proposed Solution

A custom multi-cluster deployment pipeline built on GitHub Actions, GHCR,
and SSH-based deployment - rather than adopting a generic automation
framework (that comparison is WP2). This describes the target design;
where the current implementation doesn't yet match it, that's called out
explicitly rather than glossed over.

## 0. Prerequisites

Nothing below works until these are actually in place - not just
installed, but running:

- **Docker installed** on the runner hardware. Needed both for the
  workflow's own `docker build`/`docker push` steps (§2) and, for the
  Cluster A simulator specifically, via the host socket it bind-mounts in
  (§8) - so this is the same Docker install serving both roles, not two
  separate ones.
- **A dedicated SSH key pair created**, not a personal key:
  ```bash
  ssh-keygen -t ed25519 -f ~/workshop-keys/runner_key -N ""
  ```
  Its private half becomes the `SSH_PRIVATE_KEY` GitHub secret (§5); its
  public half has to be installed on every target this pipeline deploys
  to - the Cluster A simulator (`cluster-config/cluster-a-docker.sh`
  takes it as an argument) and every real cluster's `authorized_keys`.
- **The self-hosted runner registered *and* running**, not just
  installed - registered against the repo under Settings -> Actions ->
  Runners, and started as the `systemd` service described in §4. A
  `workflow_dispatch` run just sits queued with nothing happening if no
  runner is online to pick it up; this is the single most common reason a
  run silently does nothing.

Also needed but usually already present on a normal dev machine: `git`,
`jq` (all of `deploy.sh`/`verify.sh`/`preflight.sh` parse
`config/clusters.json` with it), and a `GHCR_TOKEN` secret (classic PAT,
`write:packages` + `repo`) for the push step in §2. The full step-by-step
for all of the above is the README's WP0 section - this list is "what
must be true," not "how to get there."

## 1. Orchestration

GitHub Actions, triggered via `workflow_dispatch`, with manual cluster
selection (Cluster A, LUIS) as checkbox inputs. A run picks which
clusters to touch; each selected cluster gets its own job so one cluster
failing doesn't block the others.

## 2. Container

Reproducible Docker images, tagged with the Git SHA (never `latest`), built
once and pushed to GHCR. The tag is the single source of truth for "what
code is this" - every later step (deploy, verify) refers to the same SHA.

## 3. Transport

SSH-based deployment: `deploy.sh <cluster> <sha>`. Critically, **clusters
pull the image directly from GHCR themselves** (`docker pull`/`apptainer
pull` executed on the target over SSH) - the runner never streams or
proxies the image. The runner's SSH call just tells the remote host what
to pull and run; the actual image transfer is target-to-GHCR, not
target-to-runner-to-GHCR. This keeps the runner from becoming a transfer
bottleneck and means image size is bounded only by the target's own link
to GHCR, not by the runner's upload bandwidth.

## 4. Runner hosting

The self-hosted runner runs **permanently on dedicated local hardware** -
a physical machine, registered as a `systemd` service - rather than a VM
or a GitHub-hosted runner. Two reasons this isn't just a convenience
choice:

- It needs to reach targets a GitHub-hosted runner structurally can't:
  `localhost`-bound local cluster simulators, and HPC login nodes that
  often only accept connections from known source IPs.
- A runner with Docker socket access is effectively root on whatever it
  runs on. Dedicated hardware (not shared with other workloads, not a VM
  someone else also uses) bounds that blast radius instead of extending
  it to unrelated systems.

`systemd` (`svc.sh install && svc.sh start`, or an equivalent unit file)
instead of a foreground `./run.sh` in a terminal is what makes "permanently"
actually true - it survives reboots and doesn't depend on a logged-in
session staying open.

## 5. Secrets

SSH deploy keys live in GitHub Actions secrets and are loaded **only at
runtime, into RAM via `ssh-agent`** - never written to disk on the runner
hardware, even temporarily.

**Current implementation gap:** the workflows as they exist today
(`deploy.yml`, `health.yml`, `sync_luis.yml`) write the key to a file
(`~/workshop-keys/runner_key`) at the start of each job. That's not what
this section describes and should be replaced with an agent-based flow,
roughly:

```bash
eval "$(ssh-agent -s)"
ssh-add - <<< "${SSH_PRIVATE_KEY}"     # key content never touches a file
```

...then dropping every script's `-i "$KEY"` argument in favor of letting
`ssh`/`rsync` pick up the running agent via `SSH_AUTH_SOCK`. This also
means `config/clusters.json`'s `key` field stops being a filesystem path
and becomes unnecessary for auth (SSH just uses whatever the agent
offers) - worth deciding whether to drop that field or keep it purely as
documentation of which key a cluster expects.

## 6. Verification

Same three-way comparison as before, now framed as part of WP1 rather than
a separate work package: Git commit ↔ deployed container tag ↔ the
version actually observed running on each cluster. Three distinguishable
outcomes per cluster (up to date / outdated / unreachable) - see
`scripts/verify.sh`.

## 7. Central data storage

The core idea is simple and is the settled part: **one database, running
locally on the same hardware as the runner** - not a separately hosted DB
service, and not per-cluster databases that need aggregating afterwards.
Every cluster's results end up in that one local DB.

**How results from a remote cluster actually reach it is not yet
validated** and needs to be tested before anything is built on top of it.
The current candidate approach:

**SSH reverse tunnel (`ssh -R`), proposed, untested:** the runner already
opens outbound SSH connections to every cluster for deployment - the idea
is to reuse that same connectivity for a reverse tunnel instead of
standing up any new network path:

```bash
ssh -R <forwarded-port>:localhost:<sqlite-server-port> <user>@<cluster-host>
```

In theory, anything on the cluster side connecting to
`localhost:<forwarded-port>` would then transparently reach the runner's
local DB, with no inbound connectivity to the runner and no outbound
internet access needed from HPC compute nodes beyond the SSH connection
already required for deploy - which would sidestep the risk flagged in
`doc/wp3.md` §Component 2 (a shared DB reachable from every cluster,
including SLURM compute nodes, being exactly the kind of firewall
dependency that can cause delays with HPCs).

That's the theory, not a demonstrated result. Before Component 2 relies
on it, it needs an actual test: bring up the tunnel against the Cluster A
simulator (§8) first (cheap, no HPC access needed), confirm a process on
the "cluster" side can really write to the runner's DB through it, and
only then attempt it against a real HPC login node / compute node, where
SSH reverse tunnels are more likely to hit surprises (allowed at all?
survives a `sbatch` job's node allocation, which may differ from the
login node the tunnel was opened from?). If it doesn't hold up, fall back
options include: workers write results locally and a login-node-side sync
step forwards them later (same shape as `sync.sh`), or a VPN/known-IP
allowlist if the cluster's network policy permits one.

**Two more things to get right once the tunnel approach is validated (or
replaced):**

- **Tunnel lifetime vs. job lifetime.** `sbatch` jobs run asynchronously,
  often well after the runner's deploy-time SSH session has ended. A
  tunnel opened only during `deploy.sh`'s brief SSH call won't still be up
  when the actual job runs later. Given the runner is already a
  persistent `systemd` service (§4), the tunnels would probably need to be
  persistent too - one long-lived `autossh`-managed (or systemd-unit-managed)
  reverse tunnel per cluster, independent of any single deploy invocation,
  rather than something `deploy.sh` opens and closes per run.
- **SQLite under concurrent writers.** Component 2 of WP3 explicitly wants
  multiple parallel workers, across multiple clusters, writing results at
  the same time. SQLite's default locking serializes writers and can throw
  `database is locked` under contention; **WAL journal mode**
  (`PRAGMA journal_mode=WAL`) is the standard mitigation and should be
  enabled from the start rather than discovered as a bug later.
  PyExperimenter's row-locking (WP3 §Component 2) prevents two workers
  from claiming the same experiment - it doesn't by itself prevent SQLite
  write contention on the underlying file, which is a separate concern.

## 8. Setting up and inspecting the example cluster (Cluster A)

Before touching any real HPC target, the whole pipeline can be exercised
against one local "cluster" stand-in - useful for developing/demoing WP1
without needing LUIS/KISSKI/PC2 access at all. There is deliberately only
one example cluster; a real second target is a genuinely different HPC
system (LUIS et al.), not a second local simulator.

### Setup

```bash
ssh-keygen -t ed25519 -f ~/workshop-keys/runner_key -N ""   # once
./cluster-config/cluster-a-docker.sh ~/workshop-keys/runner_key.pub
```

The script (via `cluster-config/local-docker.sh`) builds a small Debian
image with `openssh-server` + the `docker` CLI, creates a `clustera` OS
user, installs the given public key into that user's `authorized_keys`,
and starts it as a container listening on `127.0.0.1:2222`. It also
bind-mounts the **host's** `/var/run/docker.sock` in, and - since the
image's own `docker` group GID won't automatically match whatever GID
owns that socket - patches the user's group membership against the live
socket GID right after start (see §4's runner-hardware rationale for why
Docker-socket access is sensitive in the first place). This container is
exactly what `config/clusters.json`'s `cluster-a` entry points at.

### Verifying it's up, and that a deploy actually landed

- **Direct SSH check** (does the simulator even accept the key):
  ```bash
  ssh -p 2222 -i ~/workshop-keys/runner_key clustera@127.0.0.1
  ```
- **`scripts/preflight.sh`** - loops over every entry in
  `config/clusters.json` and reports plain reachability (SSH connects at
  all), independent of whether anything's been deployed yet.
- **`scripts/verify.sh [tag]`** - the real check: SSHes in and asks the
  simulator's Docker (see below) what the newest matching image actually
  is, then compares it against the current Git commit (or an explicit
  `<tag>`). Reports `✓` (matches), `OUTDATED` (something's there, wrong
  commit), or `UNREACHABLE` - the three states this is designed to keep
  distinct.
- **Manual inspection**, if `verify.sh` says something unexpected:
  ```bash
  ssh -p 2222 -i ~/workshop-keys/runner_key clustera@127.0.0.1 docker images
  ssh -p 2222 -i ~/workshop-keys/runner_key clustera@127.0.0.1 docker ps -a
  ```

### What's actually stored there (and the catch)

The simulator container itself holds almost nothing: just `sshd`, the
Docker CLI binary, and the `clustera` user with its `authorized_keys`.
**No image or container data lives inside it.**

That's because `deploy.sh`'s remote command is
`docker pull ... && docker run --rm ...` executed against the *shared*,
bind-mounted host socket - so the pulled image and any (briefly) running
container are actually stored in the **host machine's own Docker Engine**
(its normal image/container storage, e.g. `/var/lib/docker` on Linux, or
the Docker Desktop VM's disk on macOS), exactly as if you'd run
`docker pull`/`docker run` on the host directly. `--rm` removes the
*container* the moment `hello.py` exits, so nothing running persists
either way - what actually persists, and what `verify.sh` inspects, is
the **pulled image** sitting in that shared image cache (`docker images`,
newest tag matching the registry prefix).

Worth keeping in mind precisely because it's a shared socket: Cluster A's
simulator doesn't have its own isolated Docker state - `docker images`/
`docker ps` run against it shows whatever is on the host's Docker engine
in general, not something scoped to "this cluster." Fine for exercising
`deploy.sh cluster-a ...` in isolation; not a real multi-tenancy
boundary if this ever gets extended.
