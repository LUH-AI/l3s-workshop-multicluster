# WP1: Proposed Solution

A custom multi-cluster deployment pipeline built on GitHub Actions, GHCR,
and SSH-based deployment - rather than adopting a generic automation
framework (that comparison is WP2). This describes the target design;
where the current implementation doesn't yet match it, that's called out
explicitly rather than glossed over.

## 1. Orchestration

GitHub Actions, triggered via `workflow_dispatch`, with manual cluster
selection (Cluster A, Cluster B, LUIS) as checkbox inputs. A run picks
which clusters to touch; each selected cluster gets its own job so one
cluster failing doesn't block the others.

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

Results from every cluster flow through an **SSH reverse tunnel**
(`ssh -R`) into a **single SQLite database on the same hardware the
runner lives on** - no separately hosted database.

**Mechanism:** the runner already opens outbound SSH connections to every
cluster for deployment; the natural fit is to reuse that same
connectivity for the reverse tunnel instead of requiring any new network
path. Run (from the runner, to each cluster):

```bash
ssh -R <forwarded-port>:localhost:<sqlite-server-port> <user>@<cluster-host>
```

Anything on the cluster side connecting to `localhost:<forwarded-port>`
then transparently reaches the runner's local DB - no inbound
connectivity to the runner needed, no outbound internet access needed
from HPC compute nodes beyond the SSH connection that's already required.
This is what resolves the risk flagged in `doc/wp3.md` §Component 2 (a
shared DB reachable from every cluster, including SLURM compute nodes,
being exactly the kind of firewall dependency that caused delays with
LUIS before): the tunnel piggybacks on already-permitted SSH traffic
instead of asking for a new one.

**Two things to get right operationally, not yet decided:**

- **Tunnel lifetime vs. job lifetime.** `sbatch` jobs run asynchronously,
  often well after the runner's deploy-time SSH session has ended. A
  tunnel opened only during `deploy.sh`'s brief SSH call won't still be up
  when the actual job runs later. Given the runner is already a
  persistent `systemd` service (§4), the tunnels should probably be
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
