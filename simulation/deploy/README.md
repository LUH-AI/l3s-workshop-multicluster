# Deploy

Puts the word-count services (see [services/README.md](../services/README.md))
on the two clusters.

| Cluster | What gets deployed | Where |
|---|---|---|
| A (Kubernetes) | `gateway` pod + NodePort Service 30080 | node1 (`cluster-a-m02`) |
| A (Kubernetes) | `reducer` pod + Service `reducer:8080` | node2 (`cluster-a-m03`) |
| B (SLURM) | `/shared/images/mapper.sif` (Apptainer image) | shared by node3, node4 |
| B (SLURM) | `slurm-agent` (python3 process, port 8090) | `slurmctld`, code in `/opt/slurm-agent` |

Both clusters must be running (`./cluster-a/create.sh`, `./cluster-b/create.sh`).

## Run

From the repo root in Git Bash (or WSL/Linux):

```bash
./deploy/deploy.sh
```

| Option | Meaning |
|---|---|
| `--only a` / `--only b` | deploy to one cluster only |
| `--skip-build` | use the existing Docker images |
| `--skip-check` | skip the quick check at the end |
| `-h`, `--help` | show the options |

It takes about a minute. Safe to re-run after changing a service: images are
rebuilt and reloaded, pods restarted, the slurm-agent restarted.

At the end it checks each cluster once: the gateway pod calls the reducer, and
a 2-chunk word count runs through the slurm-agent as a SLURM array job (one
chunk on node3, one on node4).

## Connect the clusters

The clusters sit on separate Docker networks (`cluster-a`, `cluster-b`). This
creates the only link between them:

```bash
./deploy/connect.sh
```

It attaches the `slurmctld` container to cluster A's network and creates a
Kubernetes Service `slurm-agent` (a Service without a selector plus an
EndpointSlice with slurmctld's address). Pods in cluster A then reach the agent
as `http://slurm-agent:8090`. It ends by calling the agent from the gateway pod.

Run it once after the first deploy, and again whenever cluster B's containers are
recreated (slurmctld may get a new address). Safe to re-run.

```text
cluster A (network cluster-a)                     cluster B (network cluster-b)
  gateway pod ──► Service slurm-agent ──► 192.168.58.x:8090 = slurmctld ──► node3, node4
                                         (slurmctld is on both networks)
```

## See what's running

Cluster A:

```bash
kubectl get pods -o wide
```

Cluster B (jobs, then the agent's log):

```bash
docker exec slurmctld squeue
```

```bash
docker exec slurmctld tail /var/log/slurm-agent.log
```

## Notes

- The slurm-agent is a plain process in the `slurmctld` container, not part of
  the image. It stops when the container restarts; run `./deploy/deploy.sh --only b`
  to start it again.
- If `POST /jobs` on the gateway says "cannot reach", the clusters aren't
  connected or the agent isn't running: run `./deploy/deploy.sh --only b`, then
  `./deploy/connect.sh`.
