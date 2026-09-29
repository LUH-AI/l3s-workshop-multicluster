# Cluster A: Kubernetes (minikube)

A multi-node Kubernetes cluster on the minikube Docker driver: one control-plane
node, tainted so no workloads run there, plus worker nodes labelled `node1`,
`node2`, ... so services can be pinned to a node.

| Node | Role | Labels |
|---|---|---|
| `cluster-a` | control plane (`NoSchedule` taint) | `multi-cluster/cluster=cluster-a` |
| `cluster-a-m02` | worker | `multi-cluster/node=node1` |
| `cluster-a-m03` | worker | `multi-cluster/node=node2` |

## Create

Run from the repo root in Git Bash (or WSL/Linux):

```bash
./cluster-a/create.sh
```

| Option | Default | Meaning |
|---|---|---|
| `--name NAME` | `cluster-a` | minikube profile and kubectl context |
| `--workers N` | `2` | worker nodes (the control plane comes on top) |
| `--cpus N` | `2` | CPUs per node (below 2 adds minikube's `--force`) |
| `--memory SIZE` | `2g` | memory per node (`2g`, `2048mb`) |
| `--k8s-version V` | minikube default | e.g. `v1.34.0` |
| `--recreate` | off | delete the cluster first and build it again |
| `-h`, `--help` | | show the options |

The script is safe to re-run: a running cluster is kept, a stopped one is
started, and the taint and labels are applied again. To change the node count,
CPUs or memory of an existing cluster, add `--recreate`. A fresh build takes
about 3–4 minutes.

```bash
./cluster-a/create.sh --workers 3 --memory 3g --recreate
```

At the end kubectl points at the cluster (`kubectl config use-context cluster-a`).

## Pin a workload to a node

```yaml
spec:
  nodeSelector:
    multi-cluster/node: node1
```

Images built locally are not pulled from a registry; load them into the cluster
and set `imagePullPolicy: Never`:

```bash
minikube -p cluster-a image load gateway:latest
```

## Stop, start, delete

```bash
minikube stop -p cluster-a
```

Stops the cluster and frees its memory; `./cluster-a/create.sh` starts it again.

```bash
./cluster-a/delete.sh
```

Removes it completely (`--name NAME` for another profile).

## Notes

- `Failing to connect to https://registry.k8s.io/` during start is expected on
  this network and harmless: cluster images come from minikube's cache and our
  own images are loaded locally.
- `kubectl.exe is version 1.36.1, which may have incompatibilities` is also
  harmless for what we do.
- The nodes report all of the laptop's CPUs to Kubernetes even though Docker caps
  each node at `--cpus`. Keep pod CPU limits per node within that cap.
- On Windows, `minikube delete` sometimes fails because a file in the profile
  folder is briefly locked (antivirus scanning it). Both scripts retry 3 times.
