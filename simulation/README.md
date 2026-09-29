# Multi-cluster word count

A concept for running one application across two different kinds of cluster on a
single laptop:

- **Cluster A: Kubernetes** (minikube): always-on web services.
- **Cluster B: SLURM + Apptainer**: batch jobs that wait in a queue.

The application is word count, the "hello world" of distributed computing.

```text
laptop ──text──► gateway (A, node1) ──chunks──► slurm-agent (B, slurmctld)
                                                     │ sbatch --array
                                                     ▼
                                           mapper jobs on node3, node4 (Apptainer)
laptop ◄─result── gateway ◄── reducer (A, node2) ◄──results──┘
```

| Folder | What |
|---|---|
| [cluster-a/](cluster-a/README.md) | create/delete cluster A (control plane + node1, node2; 2 CPU each) |
| [cluster-b/](cluster-b/README.md) | create/delete cluster B (slurmctld + node3, node4; 1 CPU each), SLURM commands |
| [services/](services/README.md) | gateway, reducer, slurm-agent, mapper (Python standard library) |
| [deploy/](deploy/README.md) | deploy the services and connect the clusters |
| `wordcount.sh` | count the words of a book using both clusters |

## Run everything

From the repo root in Git Bash (or WSL/Linux), in this order.

Create cluster A (about 3–4 minutes):

```bash
./cluster-a/create.sh
```

Create cluster B:

```bash
./cluster-b/create.sh
```

Deploy the services to both clusters (about 1 minute):

```bash
./deploy/deploy.sh
```

Connect the clusters (the only link between them):

```bash
./deploy/connect.sh
```

Count the words of *Pride and Prejudice* (downloaded once into `data/`):

```bash
./wordcount.sh
```

It shows the SLURM queue while the chunks run, then the top words and which node
counted each chunk. Options: `--chunks N` (default 8), `--top N` (default 10),
or give your own text file:

```bash
./wordcount.sh --chunks 4 --top 20 my-book.txt
```

## Watch it work

While `./wordcount.sh` runs, in another terminal:

```bash
kubectl get pods -o wide
```

```bash
docker exec slurmctld squeue
```

## Stop and clean up

Free the memory but keep everything:

```bash
minikube stop -p cluster-a
```

```bash
docker compose -f cluster-b/generated/docker-compose.yml stop
```

Start again later with `./cluster-a/create.sh`, `./cluster-b/create.sh`,
`./deploy/deploy.sh --only b` (the slurm-agent doesn't survive a restart) and
`./deploy/connect.sh`.

Delete both clusters:

```bash
./cluster-a/delete.sh
```

```bash
./cluster-b/delete.sh
```
