# WP3: Cluster Integration & Resource Optimization

Three components, each building on the one before it:

```
Component 1                Component 2                 Component 3
Cluster Configs   ----->   PyExperimenter    ----->    AI Scheduling
(wire up targets)          (run + collect)             (decide placement)
       |                          |                            |
config/clusters.json     central DB (WP1) +          historical runs from
+ deploy/sync/verify      per-cluster workers          the central DB
                                                        -> Runtime Predictor
                                                        -> Allocator
                                                        -> generated sbatch configs
```

- **Component 1** connects the real clusters (LUIS, KISSKI) to the
  existing deploy pipeline.
- **Component 2** runs real experiments on top of that, using
  PyExperimenter to distribute work across clusters without double
  execution.
- **Component 3** is the core contribution: a small AI-assisted
  scheduler that decides how compute gets allocated across clusters,
  instead of first-come-first-served.

## Prerequisites

- Individual setup done, and WP1's pipeline already working against Cluster A
  (`deploy.sh`/`verify.sh`/`preflight.sh` succeed there).
- A KISSKI account (Academic Cloud, public key uploaded at
  `id.academiccloud.de`, ~10 min propagation wait).
- Python 3.10 for anything touching SMAC/PyExperimenter - both are
  already in `requirements.txt`, and the `Dockerfile` is already pinned
  to `python:3.10-slim` for the same reason.

**What's realistic in 3-4h:** most of this only needs the local
Cluster A simulator, not real HPC access.

- Component 1: wire up LUIS and KISSKI if the accounts are ready - only
  Cluster A is in `config/clusters.json` so far; `doc/clusters.md` has
  ready-to-use entries for the others.
- Component 2: the worker loop and row-locking can be fully tested
  against Cluster A alone.
- Component 3: run on **synthetic data** from the start - a real,
  trained predictor needs way more historical runs than a few hours can
  produce. A working pipeline you could later point at real data is the
  actual goal here, not a finished model.

---

## Component 1: Cluster Configs

### Scope

Get `deploy.sh`/`verify.sh`/`sync.sh` (or the Ansible playbook in
`doc/ansible-hpc-automation.md`) working against every target cluster,
using only config changes - the `docker`/`apptainer` branching already
exists in `scripts/deploy.sh`, and `doc/clusters.md` has ready-to-use
`clusters.json` templates.

- Add a working KISSKI entry to `config/clusters.json`.
- Make sure `scripts/preflight.sh` picks it up.
- Add an `sbatch` job template so real workloads run as an actual SLURM
  job, not on the login node (`deploy.sh <cluster> <tag> --run` only
  covers a login-node smoke test).

### Definition of Done

- `config/clusters.json` has working entries for Cluster A, LUIS, and
  KISSKI
- `scripts/preflight.sh` reports all of them as reachable
- A smoke deploy (`deploy.sh <cluster> dummy`) succeeds on each real
  cluster at least once
- An `sbatch` job template runs the container as a real (non-login-node)
  job on at least one SLURM cluster

---

## Component 2: PyExperimenter Integration

### Scope

Inside the deployed container, on each cluster, a PyExperimenter-managed
experiment grid gets worked off by one or more parallel workers.

- The experiment grid (which parameter combinations exist, which are
  open/running/done) lives in PyExperimenter's own table.
- Multiple workers - across clusters, and multiple per cluster - pull
  the next open row and claim it via PyExperimenter's built-in
  row-locking, so two workers never grab the same experiment. The work
  here is wiring the container's entrypoint to run as a PyExperimenter
  worker loop instead of the current one-shot `hello.py`.
- Finished rows write back to a shared database on the runner's own
  hardware (see `doc/wp1_proposed_solution.md` §7).

### Getting results back to the central DB

Don't block Component 2 on WP1 finishing the live tunnel - build against
a safe default first, upgrade later if there's time:

- **Default: write results locally, sync them back.** Each worker writes
  to a local file on the cluster; something pulls it back to the central
  DB afterwards (same pattern as `sync.sh`). Not elegant, but it works
  with whatever WP1 has finished so far, and it's enough to satisfy the
  Definition of Done below on its own.
- **Upgrade, if the WP1 group gets it working in time:** the SSH reverse
  tunnel (`ssh -R`) described in `doc/wp1_proposed_solution.md` §7 gives
  workers direct, live writes instead of a batch sync. Worth trying
  against the Cluster A simulator if there's time - but treat it as a
  nice-to-have you swap in later, not something Component 2 waits on.

Either way:

- Turn on SQLite's **WAL journal mode** before running concurrent
  workers - PyExperimenter's row-locking stops two workers claiming the
  same experiment, but it doesn't prevent SQLite write-contention on the
  file itself.
- If using the live tunnel, it needs to stay up for as long as a job
  might run, not just during `deploy.sh`'s brief SSH call.

### Definition of Done

- A PyExperimenter worker runs inside the container and starts via the
  same deploy path Component 1 validated
- At least two workers, on two different clusters, process the same
  experiment grid concurrently with zero duplicate executions
- Results are verifiably present in the central DB after a run - via
  local sync or a live tunnel, either counts
- A worker killed mid-experiment (login node kill, SLURM timeout)
  doesn't leave that experiment stuck "running" forever

---

## Component 3: AI-Assisted Scheduling Tool

### Scope

- **Runtime Predictor:** estimates runtime/resource need for open
  experiments, trained on historical results from Component 2's central
  DB. Needs a fallback for before enough history exists. Model and
  features are open - not decided yet.
- **Allocator:** given those estimates plus live cluster capacity
  (`config/clusters.json` + `squeue`), decides how much compute to run
  where, and generates the `sbatch` configs to start it. Algorithm is
  open too.

One thing to keep in mind either way: PyExperimenter itself has no
concept of clusters - workers just pull whatever's next from the central
DB. So the Allocator naturally works one level above it, by controlling
how many workers run on each cluster, rather than assigning individual
experiments.

### Evaluation

Compare against a first-come-first-served baseline on:

- **Makespan** - total time to finish a batch of experiments
- **Cluster utilization** - how much of the available capacity actually
  gets used
- **Allocator runtime** - the scheduler's own cost; an allocator slower
  than the time it saves is a real failure mode

### Definition of Done

- Runtime predictor trained on real historical data, with a documented
  error metric (e.g. MAE/RMSE) and a defined fallback for the cold-start
  case
- Allocator produces valid, capacity-respecting assignments and
  generated `sbatch` scripts that actually run
- Evaluation script/notebook compares the allocator against the FCFS
  baseline on all three metrics above, on real or synthetic data

---

## Splitting into parallel sub-tasks

Later components can start before earlier ones are fully done, as long
as the interface between them is agreed early:

| Sub-task                                     | Depends on                               | Can start                                                                                       |
| -------------------------------------------- | ---------------------------------------- | ----------------------------------------------------------------------------------------------- |
| **1a - Configs for HPCs**              | nothing                                  | immediately                                                                                     |
| **2a - PyExperimenter worker**         | one working cluster                      | as soon as one target deploys reliably - build against the local-sync default, don't wait on 2b |
| **2b - Live tunnel, optional upgrade** | WP1's tunnel work                        | whenever WP1 has it ready - not a blocker for 2a                                                |
| **3a - Runtime predictor**             | some historical data (real or synthetic) | immediately, against synthetic data                                                             |
| **3b - Allocator + sbatch generation** | 3a's interface (a stub is enough)        | as soon as 3a's input/output shape is agreed                                                    |
| **3c - Evaluation**                    | 3b working end-to-end                    | once 3b is validated                                                                            |

For a small group, one person per component works well - with
Component 3's person starting on **3b against a stubbed predictor**
right away rather than waiting on Component 2. The predictor's need for
real training data is the only hard sequential dependency; everything
else can be built against a mock and wired up later.
