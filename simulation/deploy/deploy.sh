#!/usr/bin/env bash
# Deploys the word-count services to both clusters.
#
#   cluster A (Kubernetes): gateway on node1, reducer on node2
#   cluster B (SLURM):      /shared/images/mapper.sif, slurm-agent on slurmctld:8090
#
# Safe to re-run: images are rebuilt and reloaded, pods restarted, the
# slurm-agent restarted. Run ./deploy/deploy.sh --help for the options.
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash: don't rewrite "/..." arguments to Windows paths

CLUSTER_A=cluster-a
CONTROLLER=slurmctld
AGENT_DIR=/opt/slurm-agent
ONLY=all
BUILD=true
CHECK=true

usage() {
    cat <<EOF
Usage: $0 [options]

Deploys the word-count services: gateway + reducer to cluster A,
mapper.sif + slurm-agent to cluster B. Both clusters must be running.

Options:
  --only a|b      deploy to one cluster only (default: both)
  --skip-build    use the existing Docker images instead of rebuilding
  --skip-check    skip the quick check at the end of each cluster
  -h, --help      show this help

Examples:
  $0
  $0 --only b
EOF
}

step() { printf '\n\033[36m==> %s\033[0m\n' "$*"; }
die()  { printf '\n\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case $1 in
        --only)       [[ ${2:-} == a || ${2:-} == b ]] || die "--only needs 'a' or 'b'"; ONLY=$2; shift 2 ;;
        --skip-build) BUILD=false; shift ;;
        --skip-check) CHECK=false; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            die "unknown option '$1' (see --help)" ;;
    esac
done

cd "$(dirname "$0")/.."   # repo root, so services/ and deploy/ paths work

deploy_a() {
    kubectl --context "$CLUSTER_A" get nodes > /dev/null 2>&1 \
        || die "cluster A is not running. Start it with ./cluster-a/create.sh"

    if $BUILD; then
        step "Cluster A: building gateway and reducer images"
        docker build -q -t gateway:latest services/gateway/
        docker build -q -t reducer:latest services/reducer/
    fi

    step "Cluster A: loading the images into minikube"
    minikube -p "$CLUSTER_A" image load gateway:latest reducer:latest

    step "Cluster A: starting gateway (node1) and reducer (node2)"
    kubectl --context "$CLUSTER_A" apply -f deploy/k8s/
    # Restart so the pods use the images just loaded (the tag stays :latest).
    kubectl --context "$CLUSTER_A" rollout restart deployment/gateway deployment/reducer
    kubectl --context "$CLUSTER_A" rollout status deployment/gateway --timeout=120s
    kubectl --context "$CLUSTER_A" rollout status deployment/reducer --timeout=120s
    kubectl --context "$CLUSTER_A" get pods -o wide -l 'app in (gateway,reducer)'

    if $CHECK; then
        step "Cluster A check: gateway pod calls the reducer"
        kubectl --context "$CLUSTER_A" exec deploy/gateway -- python -c \
            "import urllib.request as u; print(u.urlopen('http://reducer:8080/health', timeout=10).read().decode())"
    fi
}

deploy_b() {
    [[ $(docker inspect -f '{{.State.Running}}' "$CONTROLLER" 2>/dev/null | tr -d '\r') == true ]] \
        || die "cluster B is not running. Start it with ./cluster-b/create.sh"

    if $BUILD; then
        step "Cluster B: building the mapper image"
        docker build -q -t mapper:latest services/mapper/
    fi

    step "Cluster B: building /shared/images/mapper.sif with Apptainer"
    docker save mapper:latest | docker exec -i "$CONTROLLER" sh -c 'cat > /tmp/mapper.tar'
    docker exec "$CONTROLLER" sh -c \
        'apptainer build --force /shared/images/mapper.sif docker-archive:///tmp/mapper.tar > /tmp/mapper-build.log 2>&1 \
         || { cat /tmp/mapper-build.log; exit 1; }; rm -f /tmp/mapper.tar; ls -lh /shared/images/mapper.sif'

    step "Cluster B: starting slurm-agent on $CONTROLLER:8090"
    docker exec "$CONTROLLER" sh -c \
        "[ -f /run/slurm-agent.pid ] && kill \$(cat /run/slurm-agent.pid) 2>/dev/null; sleep 1; rm -rf $AGENT_DIR; mkdir -p $AGENT_DIR"
    docker cp services/slurm-agent/. "$CONTROLLER:$AGENT_DIR/"
    docker exec -d "$CONTROLLER" sh -c \
        "echo \$\$ > /run/slurm-agent.pid; exec python3 $AGENT_DIR/slurm_agent.py >> /var/log/slurm-agent.log 2>&1"
    for _ in $(seq 1 20); do
        docker exec "$CONTROLLER" python3 -c \
            "import urllib.request as u; print(u.urlopen('http://localhost:8090/health', timeout=2).read().decode())" \
            2>/dev/null && break
        sleep 1
    done || true
    docker exec "$CONTROLLER" python3 -c \
        "import urllib.request as u; u.urlopen('http://localhost:8090/health', timeout=2)" 2>/dev/null \
        || die "slurm-agent did not start. See: docker exec $CONTROLLER cat /var/log/slurm-agent.log"

    if $CHECK; then
        step "Cluster B check: a 2-chunk word count through the slurm-agent"
        docker exec -i "$CONTROLLER" python3 - <<'EOF'
import json, time, urllib.request as u
opener = u.build_opener(u.ProxyHandler({}))
def call(method, path, body=None):
    data = json.dumps(body).encode() if body else None
    req = u.Request("http://localhost:8090" + path, data=data, method=method,
                    headers={"Content-Type": "application/json"})
    return json.loads(opener.open(req, timeout=10).read())
job = call("POST", "/jobs", {"chunks": ["hello world hello", "slurm and apptainer say hello"]})
print(f"submitted {job['job_id']} as SLURM job {job['slurm_job_id']}")
for _ in range(120):
    status = call("GET", "/jobs/" + job["job_id"])
    if status["state"] != "running":
        break
    time.sleep(1)
for r in status["results"]:
    print(f"  {r['chunk']}: {r['words']} words on {r['node']} ({r['seconds']}s)")
if status["state"] != "done":
    raise SystemExit(f"job {status['state']}: {status.get('error')}")
EOF
    fi
}

[[ $ONLY == all || $ONLY == a ]] && deploy_a
[[ $ONLY == all || $ONLY == b ]] && deploy_b

step "Deployed"
cat <<EOF
Cluster A:  kubectl get pods -o wide
Cluster B:  docker exec slurmctld squeue
Agent log:  docker exec slurmctld tail /var/log/slurm-agent.log

If the clusters aren't connected yet (first deploy, or cluster B recreated):
            ./deploy/connect.sh
EOF
