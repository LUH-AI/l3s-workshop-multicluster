#!/usr/bin/env bash
# Connects the two clusters: the only link between them.
#
#   1. Attaches the slurmctld container (cluster B) to cluster A's Docker
#      network, so cluster A's nodes can reach it.
#   2. Creates a Kubernetes Service "slurm-agent" in cluster A that points at
#      slurmctld's address on that network, port 8090. Pods then reach the
#      slurm-agent as http://slurm-agent:8090 like any other service.
#
# Safe to re-run; run it again after cluster B's containers are recreated,
# because slurmctld may get a new address.
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash: don't rewrite "/..." arguments to Windows paths

CLUSTER_A=cluster-a
NETWORK_A=cluster-a        # minikube names the Docker network after the profile
CONTROLLER=slurmctld
AGENT_PORT=8090
CHECK=true

usage() {
    cat <<EOF
Usage: $0 [--skip-check]

Connects cluster B's slurm-agent to cluster A: attaches $CONTROLLER to the
Docker network "$NETWORK_A" and adds the Kubernetes Service "slurm-agent".

Options:
  --skip-check   don't test the connection from the gateway pod
  -h, --help     show this help
EOF
}

step() { printf '\n\033[36m==> %s\033[0m\n' "$*"; }
die()  { printf '\n\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-check) CHECK=false; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            die "unknown option '$1' (see --help)" ;;
    esac
done

kubectl --context "$CLUSTER_A" get nodes > /dev/null 2>&1 \
    || die "cluster A is not running. Start it with ./cluster-a/create.sh"
[[ $(docker inspect -f '{{.State.Running}}' "$CONTROLLER" 2>/dev/null | tr -d '\r') == true ]] \
    || die "cluster B is not running. Start it with ./cluster-b/create.sh"

# Prints the container's IP address on a Docker network (empty if not attached).
ip_on() {
    docker inspect -f "{{with index .NetworkSettings.Networks \"$2\"}}{{.IPAddress}}{{end}}" "$1" | tr -d '\r'
}

step "Attaching $CONTROLLER to Docker network $NETWORK_A"
if [[ -n $(ip_on "$CONTROLLER" "$NETWORK_A") ]]; then
    echo "Already attached"
else
    docker network connect "$NETWORK_A" "$CONTROLLER"
fi
AGENT_IP=$(ip_on "$CONTROLLER" "$NETWORK_A")
[[ -n $AGENT_IP ]] || die "could not find $CONTROLLER's address on $NETWORK_A"
echo "$CONTROLLER is $AGENT_IP on $NETWORK_A (and still on cluster-b)"

step "Creating Service slurm-agent -> $AGENT_IP:$AGENT_PORT in cluster A"
# A Service without a selector plus a hand-made EndpointSlice: the standard
# way to give something outside the cluster a name inside it.
kubectl --context "$CLUSTER_A" apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: slurm-agent
spec:
  ports:
    - name: http
      port: $AGENT_PORT
      targetPort: $AGENT_PORT
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: slurm-agent
  labels:
    kubernetes.io/service-name: slurm-agent
addressType: IPv4
ports:
  - name: http
    port: $AGENT_PORT
    protocol: TCP
endpoints:
  - addresses: ["$AGENT_IP"]
EOF

if $CHECK; then
    step "Check: gateway pod (cluster A) calls the slurm-agent (cluster B)"
    # Retries for ~10 s: right after the Service is created, Kubernetes briefly
    # refuses connections until it has picked up the EndpointSlice.
    kubectl --context "$CLUSTER_A" exec deploy/gateway -- python -c "
import time, urllib.request as u
for attempt in range(10):
    try:
        print(u.urlopen('http://slurm-agent:$AGENT_PORT/health', timeout=5).read().decode()); break
    except OSError as e:
        error = e; time.sleep(1)
else:
    raise SystemExit(f'cannot reach http://slurm-agent:$AGENT_PORT: {error}')" \
        || die "the gateway cannot reach the slurm-agent. Is it running? ./deploy/deploy.sh --only b"
fi

step "Clusters connected"
echo "Pods in cluster A reach the slurm-agent on cluster B at http://slurm-agent:$AGENT_PORT"
