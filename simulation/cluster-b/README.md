# Cluster B: SLURM + Apptainer

A small SLURM cluster where each "machine" is a Docker container. Every
container has SLURM, munge, Apptainer and python3 installed (Ubuntu 24.04).
Jobs run their programs with Apptainer from `.sif` images on shared storage.

| Container | Role | CPUs | Memory |
|---|---|---|---|
| `slurmctld` | controller and login node (you run SLURM commands here) | 1 | 1g |
| `node3` | compute node in partition `calc` | 1 | 2g |
| `node4` | compute node in partition `calc` | 1 | 2g |

All containers share the Docker network `cluster-b` and a volume mounted at
`/shared` (`images/`, `jobs/`, `results/`). Partition `calc` has a 10-minute
time limit.

## Create

Run from the repo root in Git Bash (or WSL/Linux):

```bash
./cluster-b/create.sh
```

| Option | Default | Meaning |
|---|---|---|
| `--nodes N` | `2` | compute nodes (`node3`, `node4`, ...) |
| `--cpus N` | `1` | CPUs per compute node |
| `--memory SIZE` | `2g` | memory per compute node (`2g`, `1536m`) |
| `--apptainer-version V` | `1.5.4` | Apptainer release to install |
| `--recreate` | off | remove the containers and network first (keeps `/shared`) |
| `--skip-smoke-test` | off | skip the test jobs at the end |
| `-h`, `--help` | | show the options |

The script builds the image, writes `slurm.conf` and `docker-compose.yml` into
`cluster-b/generated/`, starts the containers, waits for the nodes to be idle,
and runs a quick test (a job on each node, an array job, and an Apptainer job).
It is safe to re-run.

```bash
./cluster-b/create.sh --nodes 3 --memory 3g
```

## Log in to the cluster

On a real HPC system you SSH to a login node and type SLURM commands there. Here
the controller container plays the login node:

```bash
docker exec -it slurmctld bash
```

All commands below are typed at that prompt (`root@slurmctld:/#`). Type `exit`
to leave.

## SLURM commands (the kubectl equivalents)

| You want | Cluster A (kubectl) | Cluster B (SLURM) |
|---|---|---|
| Is the cluster up? | `kubectl cluster-info` | `scontrol ping` |
| List nodes | `kubectl get nodes` | `sinfo -N` |
| Nodes with details | `kubectl get nodes -o wide` | `sinfo -N -l` |
| One node in detail | `kubectl describe node cluster-a-m02` | `scontrol show node node3` |
| Node CPU/memory usage | `kubectl top nodes` | `sinfo -N -o "%N %C %e %O %T"` |
| Groups of nodes | `kubectl get namespaces` (loosely) | `sinfo -s` (partitions) |
| One partition in detail | | `scontrol show partition calc` |
| List workloads | `kubectl get pods` | `squeue` |
| Workloads with nodes | `kubectl get pods -o wide` | `squeue -o "%.6i %.10j %.9T %.8M %N"` |
| Include finished ones | `kubectl get pods -A` | `squeue -t all` (finished jobs stay 5 min) |
| One workload in detail | `kubectl describe pod NAME` | `scontrol show job JOBID` |
| Workload output | `kubectl logs NAME` | `cat /shared/results/JOBID.out` (the job's `--output` file) |
| Stop a workload | `kubectl delete pod NAME` | `scancel JOBID` |
| Cluster configuration | `kubectl config view` | `scontrol show config` |
| Version | `kubectl version` | `scontrol --version` |

### Examples

List the nodes and their state (`idle`, `alloc` = busy, `down`):

```bash
sinfo -N
```

```text
NODELIST   NODES PARTITION STATE
node3          1     calc* idle
node4          1     calc* idle
```

CPU and memory per node. `CPUS(A/I/O/T)` = allocated / idle / other / total:

```bash
sinfo -N -o "%N %C %e %O %T"
```

```text
NODELIST CPUS(A/I/O/T) FREE_MEM CPU_LOAD STATE
node3 0/1/0/1 7588 0.46 idle
node4 0/1/0/1 7588 0.46 idle
```

Everything about one node:

```bash
scontrol show node node3
```

Jobs waiting (`PD`) or running (`R`), and on which node:

```bash
squeue
```

```text
JOBID PARTITION     NAME     USER ST       TIME  NODES NODELIST(REASON)
   12      calc     wrap     root  R       0:05      1 node3
```

Everything about one job (state, node, time limit, output file):

```bash
scontrol show job 12
```

A few lines of the configuration:

```bash
scontrol show config | grep -E "ClusterName|SlurmctldHost|SelectType|SLURM_VERSION"
```

The configuration file itself (the same file is in every container):

```bash
cat /etc/slurm/slurm.conf
```

## Submit a job

Still inside `docker exec -it slurmctld bash`.

Run `hostname` on node3 and read the output:

```bash
sbatch --nodelist=node3 --output=/shared/results/%j.out --wrap 'hostname'
```

```bash
cat /shared/results/*.out
```

An array job of 4 tasks, spread over node3 and node4 (one task per node at a time):

```bash
sbatch --array=0-3 --output=/shared/results/array-%a.out --wrap 'echo task $SLURM_ARRAY_TASK_ID on $SLURMD_NODENAME'
```

Run a program with Apptainer inside a job. The `.sif` image must be in
`/shared/images`; the smoke test in `create.sh` builds `smoke.sif` (busybox):

```bash
sbatch --nodelist=node3 --output=/shared/results/%j.out --wrap 'apptainer exec /shared/images/smoke.sif hostname'
```

### Without logging in

Any command above can also be run from Git Bash on the laptop by prefixing it
with `docker exec slurmctld`. Set this once per Git Bash terminal so paths like
`/shared` aren't rewritten:

```bash
export MSYS_NO_PATHCONV=1
```

```bash
docker exec slurmctld sinfo -N
```

## Stop, start, delete

```bash
docker compose -f cluster-b/generated/docker-compose.yml stop
```

Stops the containers and frees their memory; `./cluster-b/create.sh` starts them again.

```bash
./cluster-b/delete.sh
```

Removes the containers, network and `/shared` volume. Add `--keep-data` to keep
`/shared`. The image `cluster-b-slurm:latest` is kept so the next create is fast.

## Troubleshooting

The SLURM daemons log to the container output (run from Git Bash):

```bash
docker logs --tail 50 slurmctld
```

```bash
docker logs --tail 50 node3
```

The generated files `create.sh` used:

```bash
cat cluster-b/generated/slurm.conf
```

## Notes

- Docker containers stand in for machines. On a real HPC cluster these would be
  servers with SLURM and Apptainer installed, and no Docker.
- The containers are privileged so Apptainer can mount `.sif` images inside them.
- Each node has 1 CPU, so it runs one job at a time; extra jobs wait in the queue.
- There is no job accounting database, so `sacct` doesn't work; `squeue -t all`
  shows finished jobs for 5 minutes.
