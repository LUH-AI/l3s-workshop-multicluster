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

- WP0 done, and WP1's pipeline already working against Cluster A
  (`deploy.sh`/`verify.sh`/`preflight.sh` succeed there).
- A KISSKI account (Academic Cloud, public key uploaded at
  `id.academiccloud.de`, ~10 min propagation wait).
- Python 3.10 for anything touching SMAC/PyExperimenter - both are
  already in `requirements.txt`, and the `Dockerfile` is already pinned
  to `python:3.10-slim` for the same reason.

**What's realistic in 3-4h:** most of this only needs the local
Cluster A simulator, not real HPC access.

- Component 1: wire up KISSKI if the account is ready; Cluster A and
  LUIS are already wired.
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
  job, not on the login node (`cluster-config/luis-apptainer.sh` only
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

The plan is an SSH reverse tunnel (`ssh -R`) from each cluster back to
the runner, reusing the SSH connection that deployment already needs
(details in `doc/wp1_proposed_solution.md` §7). **This hasn't been
tested yet.** Try it against the Cluster A simulator first - cheap, no
HPC access needed - before assuming it works on a real cluster.

Two things to get right once it's working:

- The tunnel needs to stay up for as long as a job might run, not just
  during `deploy.sh`'s brief SSH call.
- Turn on SQLite's **WAL journal mode** before running concurrent
  workers - PyExperimenter's row-locking stops two workers claiming the
  same experiment, but it doesn't prevent SQLite write-contention on the
  file itself.

If the tunnel doesn't work on a real cluster, that's a WP1-level
decision to make (e.g. sync results after the fact instead of a live
tunnel) - don't patch around it inside this component.

### Definition of Done

- A PyExperimenter worker runs inside the container and starts via the
  same deploy path Component 1 validated
- At least two workers, on two different clusters, process the same
  experiment grid concurrently with zero duplicate executions
- Results are verifiably present in the central DB after a run
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

| Sub-task | Depends on | Can start |
|---|---|---|
| **1a - Wire KISSKI** | nothing | immediately |
| **2a - PyExperimenter worker** | one working cluster | as soon as one target deploys reliably |
| **2b - DB reachability test** | nothing | immediately - do this first, it's the biggest risk in the WP |
| **3a - Runtime predictor** | some historical data (real or synthetic) | immediately, against synthetic data |
| **3b - Allocator + sbatch generation** | 3a's interface (a stub is enough) | as soon as 3a's input/output shape is agreed |
| **3c - Evaluation** | 3b working end-to-end | once 3b is validated |

For a small group, one person per component works well - with
Component 3's person starting on **3b against a stubbed predictor**
right away rather than waiting on Component 2. The predictor's need for
real training data is the only hard sequential dependency; everything
else can be built against a mock and wired up later.
