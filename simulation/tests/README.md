# Tests

## Big MapReduce test

`big-text.txt` is a generated text of 5,000,000 made-up words (about 40 MB).
Words follow Zipf's law like real language: a few are very common, most are rare.
`big-text.expected.txt` holds the correct answer (total, different words, top 20).

Generate it (same file every time; takes a few seconds):

```bash
python tests/make_big_text.py
```

Smaller or different text (`--words`, `--vocabulary`, `--seed`, `--out`):

```bash
python tests/make_big_text.py --words 1000000
```

## Run the MapReduce test

Checks that the multi-cluster setup does the map-reduce work correctly. Both
clusters must be up, deployed and connected (see the [top-level README](../README.md)).
Run from the repo root in Git Bash, with **two terminals**: one to run the job,
one to watch the clusters.

In each Git Bash terminal, first stop Git Bash from rewriting paths like
`/shared` into Windows paths:

```bash
export MSYS_NO_PATHCONV=1
```

### 1. Check that both clusters are ready

Cluster A (Kubernetes): `gateway` on `cluster-a-m02` and `reducer` on
`cluster-a-m03`, both `Running`:

```bash
kubectl get pods -o wide
```

Cluster B (SLURM): `node3` and `node4` both `idle`:

```bash
docker exec slurmctld sinfo -N
```

### 2. Watch cluster B (terminal 2)

Shows the SLURM queue every second; stop it with Ctrl+C. The chunks wait as
`PD` (pending) and run as `R` on node3 and node4:

```bash
while true; do clear; docker exec slurmctld squeue; sleep 1; done
```

On WSL/Linux you can use `watch` instead (Git Bash doesn't have it):

```bash
watch -n 1 docker exec slurmctld squeue
```

### 3. Run the job (terminal 1)

```bash
./wordcount.sh --chunks 16 --top 20 tests/big-text.txt
```

What happens:

- **Split:** the gateway on cluster A (node1) cuts the 5 million words into 16 chunks.
- **Map:** SLURM on cluster B runs one mapper job per chunk, spread over node3 and node4.
- **Reduce:** the reducer on cluster A (node2) adds the 16 partial counts together.

It takes about 70 seconds.

### 4. Check the result

```bash
cat tests/big-text.expected.txt
```

It worked if:

- **Totals:** `5,000,000 words, 20,000 different words`, the same as the expected file.
- **Top words:** the 20 words and counts match the expected file line for line,
  starting with `ruvoneju 478,435`.
- **Chunks:** 16 lines alternating between `node3` and `node4`, about 312,500 words each.
- **Last line:** gateway on `cluster-a-m02`, mappers on `node3, node4`, reducer on
  `cluster-a-m03`, so both clusters took part.

### 5. Optional: look at what the map step wrote

The files stay on cluster B's shared storage. Newest job ID:

```bash
docker exec slurmctld sh -c 'ls -t /shared/jobs | head -1'
```

Its files (replace `<JOB_ID>` with the ID from the last command):

```bash
docker exec slurmctld ls /shared/jobs/<JOB_ID>
```

- `chunk-000.txt` … `chunk-015.txt`: the input chunks
- `result-000.json` …: each mapper's word counts and the node it ran on
- `task-*.log`: each SLURM task's log
- `job.sbatch`: the job script that ran

## Timing

Measured with 16 chunks: 71 s in total, ~0.12 s of counting per chunk. Almost all
of the time is SLURM scheduling: each node has 1 CPU, so the 16 tasks run in 8
waves of two, and each wave waits a few seconds for the scheduler.

Stay under about 8 million words: the gateway accepts at most 50 MB of text.
