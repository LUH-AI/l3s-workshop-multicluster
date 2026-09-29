# Word-count services

Word count, split across the two clusters. Python standard library only.

| Service | Runs on | What it does |
|---|---|---|
| `gateway/` | cluster A, node1 (Kubernetes pod) | Entry point. Takes the text, splits it into chunks, sends them to the slurm-agent. |
| `slurm-agent/` | cluster B, `slurmctld` (plain `python3`) | The only way into cluster B. Submits one SLURM array task per chunk and reports progress. |
| `mapper/` | cluster B, node3 / node4 (SLURM job, Apptainer) | Counts the words in one chunk. |
| `reducer/` | cluster A, node2 (Kubernetes pod) | Adds up the counts of all chunks and serves the answer. |

```text
client ──POST text──► gateway (A/node1) ──chunks──► slurm-agent (B/slurmctld)
                                                        │ sbatch --array
                                                        ▼
                                              mapper tasks on node3, node4
                                                        │ result-NNN.json in /shared
client ◄──GET /jobs/<id>── gateway ◄── reducer (A/node2) ◄──results──┘
```

Only HTTP crosses between the clusters: gateway → slurm-agent and reducer → slurm-agent.

## API

| Call | Answer |
|---|---|
| `POST /jobs?chunks=4` on the gateway, text as the body | `202 {"job_id": "wc-1a2b3c4d", "chunks": 4, "status_url": "/jobs/wc-1a2b3c4d", "gateway_node": ...}` |
| `GET /jobs/<id>?top=10` on the gateway | while running: `{"state": "running", "done": 2, "chunks": 4, "per_chunk": [...]}`; when done also `total_words`, `unique_words`, `top: [["the", 4321], ...]` |
| `GET /health` on any service | `{"service": ..., "status": "ok", "node": ...}` |

`per_chunk` lists, for each chunk, the node that counted it, its word count and seconds.

The slurm-agent's own API (used by gateway and reducer): `POST /jobs {"chunks": [...]}`,
`GET /jobs/<id>` (state `running` / `done` / `failed` plus each chunk's result).

## Configuration

| Service | Variable | Default |
|---|---|---|
| all | `PORT` | 8080 (slurm-agent: 8090) |
| gateway | `SLURM_AGENT_URL`, `REDUCER_URL` | `http://slurm-agent:8090`, `http://reducer:8080` |
| reducer | `SLURM_AGENT_URL` | `http://slurm-agent:8090` |
| slurm-agent | `SHARED_DIR` | `/shared` (job files in `/shared/jobs/<id>/`) |
| slurm-agent | `EXECUTOR` | `slurm`; `local` runs `mapper.py` directly (no SLURM) |

On cluster B each chunk runs `slurm-agent/wordcount.sbatch`: 1 CPU, 256 MB,
5 minutes, `apptainer exec /shared/images/mapper.sif python /app/mapper.py ...`.

## Try it on the laptop (no clusters)

Starts all services locally, sends a generated text, and checks the counts:

```bash
python services/run_local.py
```

With your own text split into 8 chunks:

```bash
python services/run_local.py book.txt 8
```

It ends with `OK: counts match a direct count`.

## Build the images

```bash
docker build -t gateway services/gateway/
```

```bash
docker build -t reducer services/reducer/
```

```bash
docker build -t mapper services/mapper/
```

The slurm-agent has no image: it runs with the `python3` already on `slurmctld`.
The mapper image is only used to build `mapper.sif` for Apptainer.

Deploying to the clusters is step 2 (a `deploy.sh`, not written yet).
