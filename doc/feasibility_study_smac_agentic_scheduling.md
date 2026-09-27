# SMAC Benchmarking and AI-Assisted Multi-Cluster Scheduling

This document explains the problem you'll be working on in WP3
Components 2 and 3, the approaches you can take, and what starter code
is already in place for you. Read it before the session so you can jump
straight into implementation.

---

## 1. Why SMAC, and why does it need multiple clusters?

SMAC (Sequential Model-based Algorithm Configuration) evaluates many
algorithm configurations across datasets and random seeds. A typical
benchmarking campaign for a paper — say 5 algorithm variants × 20
datasets × 10 seeds — produces 1,000 independent jobs, each needing a
few CPU cores for minutes to hours. That easily adds up to 10,000–20,000
CPU hours.

No single cluster allocation covers that. Your available resources look
roughly like this:

| Cluster | Approx. budget | Constraints |
|---|---|---|
| LUIS (LUH) | ~6,500 h (≈ 1/3) | 5-node limit per user, `/bigwork/` storage |
| PC2 (Paderborn) | ~6,500 h (≈ 1/3) | Project-based allocation (`hpc-prf-*`) |
| KISSKI (HLRN) | ~7,000 h (≈ 1/3) | Academic Cloud auth, `/scratch/usr/` storage |

So you have to split work across clusters. Today that means manually
partitioning experiments, writing separate scripts, and re-balancing
when one cluster finishes early and another is stuck in a queue. Your
job is to automate that.

### What's already in place

The starter code gives you a working (but stubbed) pipeline:

- **`src/smac_worker.py`** — a PyExperimenter worker that claims an
  unclaimed experiment row from the database, runs SMAC on it, and
  writes the result back. Currently uses a synthetic Branin function;
  you'll replace it with real benchmarks.
- **`config/experiment_config.yaml`** — defines the experiment grid
  (algorithm × dataset × seed × budget). PyExperimenter creates one
  database row per combination.
- **`src/cluster_state.py`** — SSHes into clusters and queries SLURM
  (`sinfo`/`squeue`) to report idle nodes and queue depth.
- **`src/allocator.py`** — reads the experiment grid state and cluster
  capacity, decides how many workers to start on each cluster, renders
  SLURM scripts from `templates/job.sh.j2`, and submits them.
- **`src/llm_scheduler.py`** — optional layer that replaces template
  rendering with LLM-generated scripts or wraps the whole allocator in
  an agentic loop.

All Python files have a `TODO` checklist at the top. Start by running
the allocator against the Cluster A simulator to see the shape of the
output:

```bash
python src/allocator.py --plan
```

Then progressively replace stubs with real implementations.

---

## 2. How PyExperimenter coordinates workers

The central question is: when you have workers running on LUIS, KISSKI,
and PC2 simultaneously, how do they avoid duplicating work?

PyExperimenter uses a shared database table. Before any jobs run, you
call `experimenter.fill()` and it creates one row per experiment:

```
| id  | algorithm | dataset | seed | status  | incumbent_cost |
|-----|-----------|---------|------|---------|----------------|
| 1   | branin    | synth   | 0    | open    | NULL           |
| 2   | branin    | synth   | 1    | open    | NULL           |
| 3   | branin    | synth   | 2    | open    | NULL           |
```

When a worker starts (inside a SLURM job on any cluster), it calls
`experimenter.execute()`. PyExperimenter atomically claims an "open"
row (sets it to "running"), passes its keyfields to your function, and
when you're done, marks it "done" with your results. Two workers on
different clusters hitting the database at the same time get different
rows — no coordination code needed.

**For single-cluster or local testing**, SQLite works (the default in
`experiment_config.yaml`). **For multi-cluster**, you need MySQL or
MariaDB so all clusters can reach the same database. The config has a
commented-out MySQL block — uncomment it and fill in your DB host.

---

## 3. Approaches you can take

You don't need to build all of these. Pick the one that matches your
team's skills and the time you have left. They're ordered from most
practical to most ambitious.

### Approach A: Rule-based allocator + LLM script generation

**What you build.** The allocation logic is a simple algorithm
(proportional to idle capacity — already implemented in
`allocator.py`). But instead of rendering SLURM scripts from a Jinja2
template, you ask an LLM to generate them. You pass the cluster profile
as context and the LLM produces a correct `sbatch` script for that
specific cluster.

**Why this is interesting.** SLURM scripts are notoriously
cluster-specific — partition names, module loads, memory syntax, and
Apptainer invocation all differ. An LLM that sees the cluster profile
can generate correct scripts for any cluster without maintaining
separate templates. This is the approach demonstrated by Maple
(arXiv:2510.08842), which showed LLM-based script generation reaching
high success rates across heterogeneous HPC systems.

**Where to start.** `src/llm_scheduler.py` has the `--generate` mode
already stubbed. Connect `llm_chat()` to a real endpoint (Ollama
running locally is the easiest: `ollama run llama3.1:8b`, then point
`LLM_BASE_URL` at `http://localhost:11434/v1`). Generate a script, diff
it against the Jinja2 output, and see where the LLM gets it right or
wrong.

**What to watch out for.** Validate generated scripts before
submitting. At minimum check for `#!/bin/bash` and the required
`#SBATCH` directives. If the cluster supports it, `sbatch --test-only`
will parse the script without actually submitting.

**Time estimate:** 1–2 hours.

---

### Approach C: Conventional allocator + learned runtime predictor

**What you build.** No LLM. A scheduling algorithm (bin-packing,
shortest-job-first, or a simple linear program) allocates experiments
to clusters, informed by a predictor that estimates how long each
experiment will take.

**Why this is interesting.** It's the most predictable and auditable
approach. You can inspect the allocation decisions, the predictor's
feature importances, and the final schedule. It's also what WP3
Component 3's specification originally describes.

**Where to start.** The allocator's `allocate_proportional()` function
is already working. To add a runtime predictor:

1. Generate synthetic historical data — a CSV with columns
   `(algorithm, dataset, seed, n_trials, runtime_seconds)` and
   plausible runtime values.
2. Train a simple model (scikit-learn `RandomForestRegressor` or
   `GradientBoostingRegressor`) on it.
3. Use the predicted runtimes in the allocator to solve a packing
   problem: minimize total makespan subject to per-cluster budget
   caps.

The allocator doesn't need an accurate predictor to demonstrate the
pipeline — it needs any predictor that returns a number. Swap in real
historical data from PyExperimenter later.

**What to watch out for.** Cold-start: you have no historical data at
the beginning. Synthetic data is fine for the demo. Also, if all
experiments take roughly the same time, the proportional allocator
already does well and a predictor adds no value — that's a valid
finding too.

**Time estimate:** 1.5–2 hours.

---

### Approach B: LLM agent with tool use (stretch goal)

**What you build.** A full agentic loop where the LLM is the
decision-maker. It has access to tools: query the experiment grid,
check cluster capacity, generate scripts, submit jobs, and monitor
progress. It reasons about what to do, calls tools, observes results,
and iterates.

**Why this is interesting.** It handles dynamic re-allocation
naturally — if LUIS's queue is backed up, the agent notices and shifts
work to KISSKI. It also provides a natural language interface: you tell
it "run the remaining benchmarks, prioritize whichever cluster has the
shortest queue" and it figures out the rest.

**Where to start.** `src/llm_scheduler.py` has the `--agent` mode with
tool definitions (`AGENT_TOOLS`) and a dispatch function
(`handle_tool_call`). Wire `handle_tool_call` to the real functions in
`cluster_state.py` and `allocator.py`. Then connect `llm_chat()` to a
model that supports tool calling (Llama 3.1 70B+ or Qwen 2.5 72B are
strong candidates; 7B models may struggle with multi-step reasoning).

**What to watch out for.** The agent has SSH access to real clusters
via the tools you give it. Add guardrails: only allow `sbatch`, never
arbitrary commands. Test against the Cluster A simulator first. Budget
your time — debugging an agentic loop that touches real infrastructure
can eat hours.

**Time estimate:** 2–3 hours (likely fills the session).

---

### Approach D: Hybrid — conventional allocator, LLM for exceptions

**What you build.** Start with Approach C's conventional allocator for
the steady state. Add an LLM that handles exceptions: a cluster goes
down, a new experiment type appears with no runtime history, or you
want to reprioritize mid-campaign.

**Why this is interesting.** It limits the LLM's blast radius to
situations the conventional system can't handle, while keeping routine
allocation predictable and fast.

**Where to start.** Build Approach C first. Then add a thin wrapper
that detects anomalies (a cluster returning `reachable: false`, a
batch of failures, queue pressure above a threshold) and prompts the
LLM with the situation. The LLM suggests a re-allocation; the
conventional system validates it before executing.

**Time estimate:** 2–3 hours (builds on Approach C).

---

## 4. How to choose

| If your team is... | Start with | Stretch to |
|---|---|---|
| Comfortable with Python, new to LLMs | Approach C | Add Approach D's anomaly handler |
| Interested in LLM code generation | Approach A | Compare LLM output vs Jinja2 templates |
| Experienced with agents / tool calling | Approach B | Wire to real clusters |
| Short on time / want a working demo fast | Approach A or C | Either is demable in 1.5 hours |

**In all cases**, build against the Cluster A simulator first. Add
two more entries to `config/clusters.json` with different ports to
simulate a multi-cluster setup locally. Once it works there, test
against a real cluster.

---

## 5. Relevant tools and prior work

| Resource | What it gives you |
|---|---|
| [Maple](https://arxiv.org/abs/2510.08842) | Multi-agent LLM system for portable HPC scripts; demonstrated across 9 machines |
| [DREAMS](https://arxiv.org/abs/2507.14267) | LLM agent with SLURM tool use for materials simulation |
| [ADEPT](https://github.com/pnnl/adept-agentic) | PNNL's multi-agent HPC system: planner → HPC agent → validator |
| [PyExperimenter](https://github.com/tornede/py_experimenter) | DB-backed experiment grid — already in `requirements.txt` |
| [SMAC3](https://github.com/automl/SMAC3) | The benchmark workload; ask-and-tell interface enables external orchestration |
| [smolagents](https://github.com/huggingface/smolagents) | Lightweight agent framework with tool calling; minimal dependencies |
| [Ollama](https://ollama.com) | Run open-source LLMs locally; easiest way to get a working endpoint |

---

## 6. What "done" looks like

By the end of the session, your demo should show:

1. An experiment grid populated in the database (PyExperimenter).
2. The allocator querying cluster state and producing a plan
   (`python src/allocator.py --plan`).
3. Generated SLURM scripts in `generated/` that are valid for the
   target cluster.
4. At least one submitted job that claims a row, runs SMAC (even on
   the synthetic function), and writes the result back.

If you get to multi-cluster fan-out, LLM-generated scripts, or a
working agent loop, that's a bonus — show it in the demo and document
what worked and what didn't.
