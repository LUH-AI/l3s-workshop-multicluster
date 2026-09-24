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
                                                        -> LightGBM predictor
                                                        -> Allocator (greedy/ILP)
                                                        -> generated sbatch configs
```

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
time-varying capacity, decide which experiment runs where - instead of
first-come-first-served. Two stages:

**1. Runtime Predictor**

- Input: an open experiment's parameters (+ whatever metadata is
  available before it runs).
- Output: predicted runtime / resource need.
- Model: LightGBM regression, trained on historical PyExperimenter
  results from Component 2's central DB - so this component has a hard
  data dependency on Component 2 actually having produced enough
  completed runs to train on. Cold-start (no history yet) needs a
  fallback (e.g. a fixed estimate, or FCFS until enough data exists).

**2. Allocator**

- Input: the predictor's estimates for all open experiments + live
  cluster capacity (`config/clusters.json` for what's configured, `squeue`
  for what's actually free right now on SLURM-based clusters).
- Output: an experiment -> cluster assignment, from which `sbatch`
  configs are generated automatically (reusing the `sbatch` template
  pattern already established for LUIS-style deploys).
- MVP: a greedy heuristic (e.g. assign the longest/most demanding
  predicted job to the currently-least-loaded cluster first).
- Optimized variant: formulate as an ILP (decision variables = experiment
  -> cluster assignment, objective = minimize makespan or maximize
  utilization, constraints = per-cluster capacity) and compare against
  the greedy MVP.

### Evaluation

Compare against a **first-come-first-served baseline** (the "do nothing
clever" default) on:

- **Makespan** - total wall-clock time to finish a batch of experiments
- **Cluster utilization** - % of available capacity actually used over
  the run
- **Allocator runtime** - the scheduler's own computational cost; an ILP
  that takes longer to solve than the time it saves is a real failure
  mode, not just a nice-to-know number

### Definition of Done

- Runtime predictor trained on real historical data from Component 2,
  with a documented error metric (e.g. MAE/RMSE on a held-out split) and
  a defined cold-start fallback
- Greedy allocator produces valid, capacity-respecting assignments and
  generated `sbatch` scripts that actually run
- ILP variant implemented and benchmarked against the greedy one on
  allocator runtime specifically, not just solution quality
- Evaluation script/notebook reproducibly compares FCFS vs. greedy vs. ILP
  on all three metrics above, on either real or synthetic experiment data

---

## Splitting into parallel sub-tasks

The three components are already a natural split - the dependency chain
(1 unblocks 2, 2's data unblocks 3) means later components can *start*
before earlier ones are fully done, as long as the interface between them
is agreed on early:

| Sub-task                                                | Depends on                                                          | Can start once                                                                     | Notes                                                                                                                   |
| ------------------------------------------------------- | ------------------------------------------------------------------- | ---------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| **1a - Wire remaining clusters**                  | nothing                                                             | immediately                                                                        | KISSKI/PC2 entries in`clusters.json`, per `doc/clusters.md` templates                                               |
| **1b - Ansible/Fabric setup vs. current scripts** | 1a's entries exist                                                  | immediately, in parallel with 1a                                                   | decide once, don't build both paths long-term                                                                           |
| **2a - PyExperimenter worker in the container**   | Component 1 has*one* working cluster                              | as soon as one target deploys reliably                                             | doesn't need all 5 clusters, just 1-2 to develop against                                                                |
| **2b - Central DB reachability validation**       | none - can run standalone                                           | immediately                                                                        | do this**first**, in parallel with everything else - it's the biggest risk in the whole WP, see the callout above |
| **3a - Runtime predictor**                        | Component 2 producing real historical rows                          | once there's enough training data (dozens-hundreds of completed runs, not day one) | until then, build/test the pipeline against synthetic historical data so the code is ready when real data exists        |
| **3b - Greedy allocator + sbatch generation**     | 3a's prediction interface (can be a stub returning fixed estimates) | as soon as 3a's function signature is agreed, before it's actually trained         | integrate with the real predictor last                                                                                  |
| **3c - ILP variant + evaluation**                 | 3b working end-to-end                                               | once greedy is validated                                                           | stretch goal - only meaningful once there's a working baseline to compare against                                       |

If the WP3 group is small, a reasonable 3-way split is one person per
component (1, 2, 3), with component 3's person starting on **3b against a
stubbed predictor** immediately rather than waiting on component 2 to
finish - the predictor's real training data is the only genuinely
sequential dependency in the whole chain; everything else can be
developed against a mock and integrated later.
