#!/usr/bin/env bash
# Creates cluster A: a multi-node Kubernetes cluster (minikube, Docker driver).
#
# One control-plane node, tainted so no workloads run on it, plus worker nodes
# labelled multi-cluster/node=node1..nodeN. Every node is also labelled
# multi-cluster/cluster=<name>. Pin a workload to a worker with:
#
#     nodeSelector:
#       multi-cluster/node: node1
#
# Safe to re-run: an existing cluster is started if stopped and left alone if
# running; the taint and labels are applied again either way. Use --recreate to
# delete it and build it again (needed to change nodes, CPUs or memory).
#
# Runs in Git Bash on Windows, WSL or Linux. Run ./cluster-a/create.sh --help.
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash: don't rewrite "/..." arguments to Windows paths

NAME=cluster-a
WORKERS=2
CPUS=2
MEMORY=2g
K8S_VERSION=
RECREATE=false

NODE_LABEL=multi-cluster/node
CLUSTER_LABEL=multi-cluster/cluster

usage() {
    cat <<EOF
Usage: $0 [options]

Creates (or starts) cluster A: 1 control-plane node + N labelled workers.

Options:
  --name NAME            minikube profile and kubectl context (default: $NAME)
  --workers N            worker nodes, control plane comes on top (default: $WORKERS)
  --cpus N               CPUs per node; below 2 adds minikube's --force (default: $CPUS)
  --memory SIZE          memory per node, e.g. 2g or 2048mb (default: $MEMORY)
  --k8s-version VERSION  Kubernetes version, e.g. v1.34.0 (default: minikube's)
  --recreate             delete the cluster first and build it again
  -h, --help             show this help

Examples:
  $0
  $0 --workers 3 --memory 3g --recreate
EOF
}

step() { printf '\n\033[36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mWARNING: %s\033[0m\n' "$*" >&2; }
die()  { printf '\n\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

need_value() { [[ $# -ge 2 && -n $2 ]] || die "$1 needs a value (see --help)"; }

while [[ $# -gt 0 ]]; do
    case $1 in
        --name)        need_value "$@"; NAME=$2; shift 2 ;;
        --workers)     need_value "$@"; WORKERS=$2; shift 2 ;;
        --cpus)        need_value "$@"; CPUS=$2; shift 2 ;;
        --memory)      need_value "$@"; MEMORY=$2; shift 2 ;;
        --k8s-version) need_value "$@"; K8S_VERSION=$2; shift 2 ;;
        --recreate)    RECREATE=true; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             die "unknown option '$1' (see --help)" ;;
    esac
done

[[ $NAME =~ ^[a-z0-9][a-z0-9-]*$ ]]   || die "--name must be lowercase letters, digits and '-'"
[[ $WORKERS =~ ^[1-9]$ ]]             || die "--workers must be 1-9"
[[ $CPUS =~ ^[0-9]+$ && $CPUS -ge 1 && $CPUS -le 16 ]] || die "--cpus must be 1-16"
[[ ${MEMORY,,} =~ ^[0-9]+([mg]b?)?$ ]] || die "--memory must look like 2g or 2048mb"

# Memory size in MB, for comparing with an existing cluster.
to_mb() {
    local size=${1,,} n=${1//[!0-9]/}
    [[ $size == *g* ]] && echo $((n * 1024)) || echo "$n"
}

# Prints the status of a minikube profile (OK, Running, Stopped, ...), or nothing.
profile_status() {
    minikube profile list -o json 2>/dev/null | tr -d '\r' \
        | grep -o "\"Name\":\"$1\",\"Status\":\"[^\"]*\"" \
        | sed 's/.*"Status":"\([^"]*\)"/\1/' || true
}

# Prints a numeric field (CPUs, Memory) from the profile's saved config.
profile_config() {
    grep -o "\"$2\": *[0-9]*" "$3" | head -n 1 | grep -o '[0-9]*$' || true
}

# Deletes a profile, retrying because on Windows a file in the profile folder can
# be briefly locked (e.g. by antivirus), which makes minikube delete fail.
delete_profile() {
    local attempt
    for attempt in 1 2 3; do
        minikube delete -p "$1" && return 0
        (( attempt < 3 )) && { warn "minikube delete failed, retrying in 5s"; sleep 5; }
    done
    die "could not delete '$1'; run 'minikube delete -p $1' and try again"
}

# Prints the names of nodes matching a label selector, one per line, sorted.
node_names() {
    kubectl --context "$NAME" get nodes -l "$1" -o jsonpath='{.items[*].metadata.name}' \
        | tr -d '\r' | tr ' ' '\n' | sed '/^$/d' | sort
}

step "Checking tools"
for tool in docker minikube kubectl; do
    command -v "$tool" >/dev/null || die "$tool was not found on PATH"
done
docker info --format '{{.ServerVersion}}' >/dev/null 2>&1 \
    || die "Docker is not running. Start Docker Desktop and try again."
echo "docker, minikube and kubectl found; Docker is running"

NODES=$((WORKERS + 1))
CONFIG_FILE="${MINIKUBE_HOME:-$HOME/.minikube}/profiles/$NAME/config.json"
STATUS=$(profile_status "$NAME")
EXISTS=false
[[ -n $STATUS || -f $CONFIG_FILE ]] && EXISTS=true

if $EXISTS && $RECREATE; then
    step "Deleting existing cluster '$NAME' (--recreate)"
    delete_profile "$NAME"
    EXISTS=false
fi

if $EXISTS; then
    if [[ -f $CONFIG_FILE ]]; then
        have_nodes=$(grep -c '"ControlPlane":' "$CONFIG_FILE" || true)
        have_cpus=$(profile_config "$NAME" CPUs "$CONFIG_FILE")
        have_mb=$(profile_config "$NAME" Memory "$CONFIG_FILE")
        want_mb=$(to_mb "$MEMORY")
        if [[ $have_nodes != "$NODES" || $have_cpus != "$CPUS" || $have_mb != "$want_mb" ]]; then
            warn "'$NAME' already exists with $have_nodes nodes, $have_cpus CPUs and $have_mb MB per node;" \
                 "you asked for $NODES nodes, $CPUS CPUs and $want_mb MB. Keeping the existing cluster." \
                 "Re-run with --recreate to rebuild it."
        fi
    fi
    if [[ $STATUS == OK || $STATUS == Running ]]; then
        step "Cluster '$NAME' is already running"
    else
        step "Starting existing cluster '$NAME' (status: ${STATUS:-unknown})"
        minikube start -p "$NAME"
    fi
else
    step "Creating cluster '$NAME': 1 control plane + $WORKERS workers, $CPUS CPU / $MEMORY each"
    start_args=(start -p "$NAME" --driver=docker --nodes="$NODES" --cpus="$CPUS" --memory="$MEMORY")
    [[ -n $K8S_VERSION ]] && start_args+=(--kubernetes-version="$K8S_VERSION")
    if (( CPUS < 2 )); then
        warn "minikube requires 2 CPUs per node; adding --force. The control plane may be slow."
        start_args+=(--force)
    fi
    minikube "${start_args[@]}"
fi

step "Waiting for all nodes to be Ready"
kubectl --context "$NAME" wait --for=condition=Ready node --all --timeout=300s

step "Keeping workloads off the control plane"
for node in $(node_names node-role.kubernetes.io/control-plane); do
    kubectl --context "$NAME" taint nodes "$node" \
        node-role.kubernetes.io/control-plane:NoSchedule --overwrite
done

step "Labelling nodes"
kubectl --context "$NAME" label nodes --all "$CLUSTER_LABEL=$NAME" --overwrite
i=1
for node in $(node_names '!node-role.kubernetes.io/control-plane'); do
    kubectl --context "$NAME" label nodes "$node" "$NODE_LABEL=node$i" --overwrite
    i=$((i + 1))
done

kubectl config use-context "$NAME"

step "Cluster '$NAME' is ready"
kubectl --context "$NAME" get nodes -L "$NODE_LABEL" -L "$CLUSTER_LABEL"
echo
echo "kubectl now points at '$NAME'. Pin a workload with nodeSelector '$NODE_LABEL: node1'."
