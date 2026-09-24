# WP3: Cluster Integration & Resource Optimization

Three components, each building on the previous one. Component 1 finishes
wiring the real clusters into the existing deploy pipeline; Component 2
runs actual experiments on top of that; Component 3 is the core
contribution - an AI-assisted scheduler that decides *where* those
experiments should run.

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

## Prerequisites

Before starting WP3 at all - beyond the general WP0/WP1 §0 setup
(Docker, SSH key, runner running):

- **WP1's pipeline already working against Cluster A** -
  `deploy.sh`/`verify.sh`/`preflight.sh` succeed there (see WP1 §8).
  Component 1 extends something that already works to more clusters; it
  doesn't stand on its own.
- **Accounts + SSH access on the additional real clusters**, beyond LUIS
  (already covered by WP0/`doc/clusters.md`):
  - **KISSKI**: an Academic Cloud account, public key uploaded at
    `id.academiccloud.de`, ~10 min propagation wait
  - **PC2**: an *approved project* (`hpc-prf-<acronym>`) via
    PC²-JARDS - this can take real calendar time to get approved, unlike
    the same-day setup for the other clusters, so start it early
- **SLURM/`squeue` access on whichever cluster(s) the Allocator
  (Component 3) will query** - it reads live capacity from `squeue`, so
  this needs to work on at least one real SLURM cluster before the
  allocator can be tested against anything but static `clusters.json`
  config
- **Python 3.10** for anything using SMAC/PyExperimenter (both already in
  `requirements.txt`) - SMAC's own pinned dependencies are most reliably
  compatible with 3.10; newer versions risk dependency resolution
  failures. The `Dockerfile` is already pinned to `python:3.10-slim`
  accordingly - keep any local dev environment for Component 2/3 on 3.10
  too, rather than whatever's newest on your machine.

### How much of this needs real HPC access to test?

Less than it looks like. Most of WP3 can be developed and tested against
**only the Cluster A simulator**, no LUIS/KISSKI/PC2 account required:

- **Component 1** is the exception - its actual point is wiring up the
  real clusters, so genuinely validating it needs those accounts. The
  config mechanics (entries following the `doc/clusters.md` templates,
  the existing `docker`/`apptainer` branching in `deploy.sh`) can be
  prepared without them, just not confirmed working.
- **Component 2**'s worker loop and row-locking can be fully exercised
  with multiple local processes against Cluster A - including the SSH
  reverse tunnel from WP1 §7, which is explicitly supposed to be tried
  there first anyway (§ above). Only SLURM-specific failure modes (e.g. a
  stale lock left behind by an `sbatch` timeout) need a real HPC target.
- **Component 3**: the runtime predictor can be built/tested against
  synthetic historical data (see "Splitting into parallel sub-tasks"
  below); the allocator's assignment logic can be tested against mocked
  capacity numbers. Only the live `squeue` read needs a real SLURM
  cluster - everything upstream of that call doesn't.

---

## Component 1: Cluster Configs

### Scope

Get every target cluster - Cluster A (Docker simulator), LUIS
(Apptainer, already wired), and the two clusters currently listed as "not
yet in `config/clusters.json`" in `doc/clusters.md` (KISSKI, PC2) - into
a state where `deploy.sh`/`verify.sh`/`sync.sh` (or the Ansible/Fabric
alternative from `doc/ansible-hpc-automation.md`) work against all of
them without code changes, only config.

This is largely integration work, not new engineering: the `type: docker`
/ `type: apptainer` branching already exists in `scripts/deploy.sh`, and
`doc/clusters.md` already has ready-to-use `clusters.json` templates for
KISSKI and PC2. What's still open:

- Add the KISSKI and PC2 entries to `config/clusters.json` for real (the
  templates use `<your-username>`/`<acronym>` placeholders - someone needs
  to actually get accounts, test connectivity, and commit working
  entries or a documented per-participant substitution step).
- Decide, now that there are 3+ real HPC targets instead of 1, whether
  one-time environment setup goes through `deploy.sh`'s ad-hoc SSH calls
  or through the Ansible playbook in `doc/ansible-hpc-automation.md`
  (`setup_hpc.yml` already runs against `luis,kisski,pc2` in one command -
  that doc's own guidance is to prefer Ansible once you're managing more
  than two or three clusters regularly, which is now the case).
- Confirm `scripts/preflight.sh` covers all configured clusters (it reads
  `config/clusters.json` generically, so this should be "just add the
  entries," but verify it doesn't silently skip anything).

### Definition of Done

- `config/clusters.json` has working entries for Cluster A, LUIS, KISSKI,
  and PC2 (or a documented reason one is deferred)
- `scripts/preflight.sh` reports all four as reachable
- A smoke deploy (`deploy.sh <cluster> dummy`, or the Ansible
  `setup_hpc.yml` equivalent) succeeds on each real cluster at least once
- Storage-path and login-node-vs-compute-node quirks per cluster are
  captured in `doc/clusters.md` (mostly already done for LUIS/KISSKI/PC2 -
  keep it in sync as entries move from "template" to "working")

---

## Component 2: PyExperimenter Integration

### Scope

The execution layer that runs *after* Component 1's deploy step: inside
the deployed container, on each cluster, a PyExperimenter-managed
experiment grid gets worked off by one or more parallel workers.

- **Parameter management:** the experiment grid (which parameter
  combinations exist, which are open/running/done) lives in
  PyExperimenter's own table structure.
- **Distribution without double execution:** multiple workers - across
  clusters, and multiple per cluster - pull the next open row and mark it
  via PyExperimenter's row-locking, so two workers never grab the same
  experiment. This is PyExperimenter's built-in mechanism, not something
  to build from scratch; the work here is wiring the container's
  entrypoint to actually behave as a PyExperimenter worker loop instead of
  the current one-shot `hello.py`.
- **Results -> central DB (WP1):** finished rows write back to a shared
  database that WP1's side is expected to expose.

### Central DB reachability - proposed approach, not yet validated

The original workshop design (see `README.md` WP6) deliberately used
per-cluster SQLite instead of a shared DB, specifically to avoid requiring
every cluster to reach one network endpoint - the exact kind of firewall
dependency that caused delays with LUIS before. The settled part of the
new design is simple: one DB, running locally on the runner's own
hardware. `doc/wp1_proposed_solution.md` §7 proposes reaching it from each
cluster via an **SSH reverse tunnel** (`ssh -R`) over connectivity that
already exists for deployment - but that mechanism is explicitly
**untested**, not a resolved dependency. Test it against the Cluster A
simulator (WP1 §8) before Component 2 relies on it for real, then again
against an actual HPC login/compute node before assuming it generalizes.

If the tunnel approach doesn't hold up on a real HPC target (see WP1 §7
for why that's plausible - SSH reverse tunnels and SLURM's node allocation
don't necessarily cooperate), don't silently work around it inside
Component 2 - it's a WP1-level fallback decision (e.g. login-node-side
sync instead of a live tunnel), not something to patch over per-worker.

Two more things Component 2 needs once *some* connection path is
validated:

- The connection must be **up before a worker tries to write**, and for
  the whole duration a `sbatch` job might run - not just during
  `deploy.sh`'s brief SSH call (see WP1 §7's tunnel-lifetime note).
- Enable SQLite **WAL journal mode** on the DB before running concurrent
  workers - see WP1 §7. PyExperimenter's row-locking prevents two workers
  claiming the same experiment; it doesn't by itself prevent SQLite
  write-contention on the underlying file.

### Definition of Done

- A PyExperimenter worker runs inside the container image and can be
  started via the same deploy path Component 1 validated
- At least two workers, on two different clusters, process the same
  experiment grid concurrently with zero duplicate executions
- Results are verifiably present in the central DB after a run
- Worker failure (killed mid-experiment, e.g. login node process kill,
  SLURM timeout) doesn't leave an experiment stuck "running" forever -
  document or implement how a stale lock gets released

---

## Component 3: AI-Assisted Scheduling Tool

### Scope

Given a set of open experiments and several clusters with different,
time-varying capacity, decide how compute gets allocated across clusters
- instead of first-come-first-served. Two pieces, both deliberately open
on method:

- **Runtime Predictor:** estimates runtime/resource need for open
  experiments, trained on historical results from Component 2's central
  DB. Needs a cold-start fallback for before enough history exists.
  Model/features not decided yet.
- **Allocator:** given those estimates plus live cluster capacity
  (`config/clusters.json` + `squeue`), decides how much compute to run
  where and generates the `sbatch` configs to start it. Algorithm not
  decided yet.

One structural point worth keeping in mind regardless of method: since
PyExperimenter itself has no concept of clusters (workers just pull
whatever's next from the central DB), the Allocator naturally works one
level above it - controlling how many workers run on each cluster -
rather than assigning individual experiments directly.

### Evaluation

Compare against a **first-come-first-served baseline** (the "do nothing
clever" default) on:

- **Makespan** - total wall-clock time to finish a batch of experiments
- **Cluster utilization** - % of available capacity actually used over
  the run
- **Allocator runtime** - the scheduler's own computational cost; an
  allocator that takes longer to compute than the time it saves is a real
  failure mode, not just a nice-to-know number

### Definition of Done

- Runtime predictor trained on real historical data from Component 2,
  with a documented error metric (e.g. MAE/RMSE on a held-out split) and
  a defined cold-start fallback
- Allocator produces valid, capacity-respecting assignments and generated
  `sbatch` scripts that actually run
- If more than one allocation approach is tried, they're benchmarked
  against each other on allocator runtime specifically, not just solution
  quality
- Evaluation script/notebook reproducibly compares the allocator(s)
  against the FCFS baseline on all three metrics above, on either real or
  synthetic experiment data

---

## Splitting into parallel sub-tasks

The three components are already a natural split - the dependency chain
(1 unblocks 2, 2's data unblocks 3) means later components can *start*
before earlier ones are fully done, as long as the interface between them
is agreed on early:

| Sub-task                                                             | Depends on                                                          | Can start once                                                                     | Notes                                                                                                                                                           |
| -------------------------------------------------------------------- | ------------------------------------------------------------------- | ---------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **1a - Wire remaining clusters**                               | nothing                                                             | immediately                                                                        | KISSKI/PC2 entries in`clusters.json`, per `doc/clusters.md` templates                                                                                       |
| **2a - PyExperimenter worker in the container**                | Component 1 has*one* working cluster                              | as soon as one target deploys reliably                                             | doesn't need all 5 clusters, just 1-2 to develop against                                                                                                        |
| **2b - Central DB reachability validation**                    | none - can run standalone                                           | immediately                                                                        | do this**first**, in parallel with everything else - it's the biggest risk in the whole WP, see the callout above                                         |
| **3a - Runtime predictor**                                     | Component 2 producing real historical rows                          | once there's enough training data (dozens-hundreds of completed runs, not day one) | until then, build/test the pipeline against synthetic historical data so the code is ready when real data exists; model/feature choice is open, see Component 3 |
| **3b - Allocator (first working version) + sbatch generation** | 3a's prediction interface (can be a stub returning fixed estimates) | as soon as 3a's function signature is agreed, before it's actually trained         | integrate with the real predictor last; approach is open, see Component 3                                                                                       |
| **3c - Second allocation approach + evaluation**               | 3b working end-to-end                                               | once 3b is validated                                                               | only worth doing once there's a working baseline to compare against - whether a second approach is even needed is itself open                                   |

If the WP3 group is small, a reasonable 3-way split is one person per
component (1, 2, 3), with component 3's person starting on **3b against a
stubbed predictor** immediately rather than waiting on component 2 to
finish - the predictor's real training data is the only genuinely
sequential dependency in the whole chain; everything else can be
developed against a mock and integrated later.
