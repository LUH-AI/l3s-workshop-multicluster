#!/usr/bin/env bash
# Creates cluster B: a small SLURM + Apptainer cluster made of Docker containers.
# Run ./cluster-b/create.sh --help for details.
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash: do not rewrite /paths passed to docker.exe

usage() {
    cat <<'EOF'
Usage: ./cluster-b/create.sh [options]

Creates cluster B: a small SLURM + Apptainer cluster made of Docker containers.

Builds one image (SLURM 23.11 + munge + Apptainer on Ubuntu 24.04) and starts:

    slurmctld          controller (1 CPU, 1g)
    node3 .. nodeN     --nodes compute nodes in partition "calc" (numbering
                       continues after cluster A's node1/node2)

All containers are privileged, sit on the Docker network "cluster-b" and share
the volume "cluster-b-shared" at /shared (images/, jobs/, results/).
slurm.conf and docker-compose.yml are generated from slurm.conf.template and
docker-compose.template.yml into cluster-b/generated/.

Safe to re-run: running containers are left alone, stopped ones are started.
Changing --nodes/--cpus/--memory on a re-run reconfigures the cluster in place
(containers are recreated, /shared is kept). --recreate removes the containers
and network first. Neither touches /shared; use delete.sh for that.

Options:
  --nodes N                compute nodes (default 2: node3, node4)
  --cpus N                 CPUs per compute node: Docker CPU limit and CPUs= in
                           slurm.conf (default 1)
  --memory SIZE            memory limit per compute node, e.g. 2g or 1536m;
                           slurm.conf gets RealMemory = 90% of it (default 2g)
  --apptainer-version V    Apptainer release from GitHub (default 1.5.4)
  --recreate               remove existing containers and network first
  --skip-smoke-test        skip the hostname and Apptainer test jobs
  -h, --help               show this help

Examples:
  ./cluster-b/create.sh
  ./cluster-b/create.sh --nodes 3 --memory 3g
  ./cluster-b/create.sh --recreate --skip-smoke-test
EOF
}

NODES=2
CPUS=1
MEMORY=2g
APPTAINER_VERSION=1.5.4
RECREATE=0
SKIP_SMOKE_TEST=0

IMAGE=cluster-b-slurm:latest
CONTROLLER=slurmctld
FIRST_NODE=3            # cluster A owns node1/node2
PARTITION=calc
SMOKE_IMAGE=busybox:latest
SMOKE_SIF=/shared/images/smoke.sif
COMPOSE_FILE=generated/docker-compose.yml

step() { printf '\n\033[36m==> %s\033[0m\n' "$*"; }
die()  { printf '\n\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# Runs a command and stops the script with a readable message if it fails.
run() { "$@" || die "'$*' failed with exit code $?"; }

# Runs a command on the controller; output has CRs stripped (docker.exe on Windows).
ctl() { docker exec "$CONTROLLER" "$@" | tr -d '\r'; }

# Submits a test job and prints its job ID. --no-requeue makes a launch failure
# fail the job instead of holding it forever.
submit() {
    local out
    out=$(ctl sbatch --parsable --no-requeue --partition="$PARTITION" "$@") || die "sbatch $* failed"
    tail -n 1 <<<"$out" | cut -d';' -f1
}

# Waits (at most 3 minutes) until none of the given jobs is pending or running.
# Polls squeue instead of using sbatch --wait, which only checks every ~10 s.
wait_jobs() {
    local ids deadline=$(( SECONDS + 180 ))
    ids=$(IFS=,; echo "$*")
    while [ -n "$(ctl squeue -h -j "$ids" 2>/dev/null)" ]; do
        (( SECONDS < deadline )) || die "test jobs $ids did not finish within 3 minutes: $(ctl squeue -j "$ids")"
        sleep 1
    done
}

# Prints a finished job's output file, or stops with the job's state.
job_output() {
    local file=$1 job_id=$2
    ctl cat "$file" 2>/dev/null \
        || die "job $job_id wrote no $file ($(ctl scontrol show job "$job_id" | grep -o 'JobState=[A-Z_]*' | sort -u | tr '\n' ' ')). See 'docker logs' of the nodes."
}

while [ $# -gt 0 ]; do
    case "$1" in
        --nodes)             NODES=${2:?--nodes needs a value}; shift 2 ;;
        --cpus)              CPUS=${2:?--cpus needs a value}; shift 2 ;;
        --memory)            MEMORY=${2:?--memory needs a value}; shift 2 ;;
        --apptainer-version) APPTAINER_VERSION=${2:?--apptainer-version needs a value}; shift 2 ;;
        --recreate)          RECREATE=1; shift ;;
        --skip-smoke-test)   SKIP_SMOKE_TEST=1; shift ;;
        -h|--help)           usage; exit 0 ;;
        *)                   usage >&2; die "unknown option: $1" ;;
    esac
done

[[ $NODES =~ ^[1-9]$ ]]                        || die "--nodes must be 1..9"
[[ $CPUS =~ ^[0-9]+$ ]] && (( CPUS >= 1 && CPUS <= 16 )) || die "--cpus must be 1..16"
[[ $MEMORY =~ ^([0-9]+)([mg])$ ]]              || die "--memory must look like 2g or 1536m"
[[ $APPTAINER_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "--apptainer-version must look like 1.5.4"

memory_mb=${MEMORY%[mg]}
if [[ $MEMORY == *g ]]; then memory_mb=$(( memory_mb * 1024 )); fi
(( memory_mb >= 512 )) || die "--memory must be at least 512m"
real_memory=$(( memory_mb * 9 / 10 ))
def_mem_per_cpu=$(( real_memory / CPUS ))

nodes=()
for (( i = FIRST_NODE; i < FIRST_NODE + NODES; i++ )); do nodes+=("node$i"); done

# Work from the script's directory so relative paths mean the same thing to
# bash and to docker.exe on Windows.
cd "$(dirname "$0")"
started=$SECONDS

step "Checking tools"
command -v docker > /dev/null || die "docker was not found on PATH"
docker info --format '{{.ServerVersion}}' > /dev/null 2>&1 \
    || die "Docker is not running. Start Docker Desktop and try again."
docker compose version > /dev/null 2>&1 || die "'docker compose' (Compose v2) is not available"
echo "docker and docker compose found; Docker is running"

if (( RECREATE )); then
    step "Removing existing cluster B containers and network (--recreate, /shared is kept)"
    ./delete.sh --keep-data || die "delete.sh failed"
fi

step "Building image $IMAGE (Apptainer $APPTAINER_VERSION)"
# No provenance attestation: it makes every (cached) build a new image ID, which
# would make compose recreate the containers on every re-run.
build_opts=()
docker buildx version > /dev/null 2>&1 && build_opts+=(--provenance=false)
run docker build "${build_opts[@]}" -t "$IMAGE" --build-arg "APPTAINER_VERSION=$APPTAINER_VERSION" .

step "Generating slurm.conf and docker-compose.yml for ${nodes[*]} ($CPUS CPU / $MEMORY each)"
mkdir -p generated

node_lines=""
node_services=""
for n in "${nodes[@]}"; do
    node_lines+="NodeName=$n CPUs=$CPUS RealMemory=$real_memory State=UNKNOWN"$'\n'
    node_services+="  $n:
    <<: *slurm
    container_name: $n
    hostname: $n
    command: [\"slurmd\"]
    cpus: $CPUS
    mem_limit: $MEMORY
    depends_on: [$CONTROLLER]
"$'\n'
done
node_list=$(IFS=,; echo "${nodes[*]}")

header="# GENERATED by create.sh (--nodes $NODES --cpus $CPUS --memory $MEMORY) - do not edit."
conf=$(tr -d '\r' < slurm.conf.template | sed '/^## /d')
conf=${conf//@NODE_LINES@/${node_lines%$'\n'}}
conf=${conf//@NODE_LIST@/$node_list}
conf=${conf//@DEF_MEM_PER_CPU@/$def_mem_per_cpu}
printf '%s\n%s\n' "$header" "$conf" > generated/slurm.conf
conf_sha=$(sha256sum generated/slurm.conf | cut -d' ' -f1)

compose=$(tr -d '\r' < docker-compose.template.yml | sed '/^## /d')
compose=${compose//@NODE_SERVICES@/${node_services%$'\n'}}
compose=${compose//@SLURM_CONF_SHA@/$conf_sha}
printf '%s\n%s\n' "$header" "$compose" > "$COMPOSE_FILE"
echo "Wrote cluster-b/generated/slurm.conf"
echo "Wrote cluster-b/$COMPOSE_FILE"

step "Starting containers (network cluster-b, volume cluster-b-shared)"
run docker compose -f "$COMPOSE_FILE" up -d --remove-orphans

step "Waiting for all nodes to be idle in sinfo"
deadline=$(( SECONDS + 180 ))
while :; do
    sinfo_out=$(ctl sinfo -h -N -o '%N %T' 2>/dev/null || true)
    missing=()
    for n in "${nodes[@]}"; do
        grep -qx "$n idle" <<<"$sinfo_out" || missing+=("$n")
    done
    (( ${#missing[@]} == 0 )) && break
    for c in "$CONTROLLER" "${nodes[@]}"; do
        state=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null | tr -d '\r' || true)
        [ "$state" = running ] || die "container $c is '${state:-missing}'. See 'docker logs $c'."
    done
    (( SECONDS < deadline )) || die "timed out waiting for ${missing[*]}. sinfo says: $(echo $sinfo_out). See 'docker logs $CONTROLLER' and 'docker logs ${missing[0]}'."
    sleep 2
done
echo "All ${#nodes[@]} nodes are idle"

if (( SKIP_SMOKE_TEST )); then
    step "Skipping smoke test (--skip-smoke-test)"
else
    step "Smoke test 1/3: sbatch 'hostname' pinned to each node"
    ids=()
    for n in "${nodes[@]}"; do
        ids+=("$(submit --job-name=smoke-hostname --nodelist="$n" \
            --output=/shared/results/smoke-hostname-%j.out --wrap=hostname)")
    done
    wait_jobs "${ids[@]}"
    for i in "${!nodes[@]}"; do
        out=$(job_output "/shared/results/smoke-hostname-${ids[$i]}.out" "${ids[$i]}")
        [ "$out" = "${nodes[$i]}" ] || die "job ${ids[$i]} pinned to ${nodes[$i]} printed '$out'"
        echo "  ${nodes[$i]} -> $out"
    done

    # Two tasks per CPU slot: the first wave fills every node, so each must show up.
    tasks=$(( ${#nodes[@]} * CPUS * 2 ))
    step "Smoke test 2/3: array job with $tasks tasks over partition $PARTITION (no --nodelist)"
    array_id=$(submit --job-name=smoke-array --array="0-$(( tasks - 1 ))" \
        --output="/shared/results/smoke-array-%A_%a.out" --wrap='sleep 3; hostname')
    wait_jobs "$array_id"
    used=$(ctl sh -c "cat /shared/results/smoke-array-${array_id}_*.out" | sort | uniq -c)
    [ "$(awk '{s += $1} END {print s}' <<<"$used")" = "$tasks" ] \
        || die "array job $array_id: expected $tasks outputs, got: $used"
    echo "$used" | sed 's/^ */  /; s/ \([^ ]*\)$/ tasks on \1/'
    for n in "${nodes[@]}"; do
        grep -qw "$n" <<<"$used" || die "no array task ran on $n"
    done

    step "Smoke test 3/3: apptainer exec under SLURM on ${nodes[0]}"
    if docker exec "$CONTROLLER" test -s "$SMOKE_SIF"; then
        echo "Using cached $SMOKE_SIF"
    else
        docker image inspect "$SMOKE_IMAGE" > /dev/null 2>&1 || run docker pull "$SMOKE_IMAGE"
        echo "Copying $SMOKE_IMAGE into $CONTROLLER"
        docker save "$SMOKE_IMAGE" | docker exec -i "$CONTROLLER" sh -c 'cat > /tmp/smoke.tar' \
            || die "could not copy $SMOKE_IMAGE into $CONTROLLER"
        run docker exec "$CONTROLLER" apptainer build --force "$SMOKE_SIF" docker-archive:///tmp/smoke.tar
        docker exec "$CONTROLLER" rm -f /tmp/smoke.tar
    fi
    id=$(submit --job-name=smoke-apptainer --nodelist="${nodes[0]}" \
        --output=/shared/results/smoke-apptainer-%j.out \
        --wrap="apptainer exec $SMOKE_SIF sh -c 'echo apptainer-ok host=\$(hostname) \$(busybox | head -n 1)'")
    wait_jobs "$id"
    out=$(job_output "/shared/results/smoke-apptainer-$id.out" "$id")
    [[ $out == "apptainer-ok host=${nodes[0]} BusyBox"* ]] || die "Apptainer job printed '$out'"
    echo "  ${nodes[0]} -> $out"
    echo "Smoke test passed"
fi

step "Cluster B is ready (took $(( SECONDS - started ))s)"
ctl sinfo
echo
ctl sinfo -N -o '%N %P %c %m %T'
echo
echo "Submit a job:  docker exec $CONTROLLER sbatch --nodelist=${nodes[0]} --output=/shared/results/%j.out --wrap 'hostname'"
echo "Shell:         docker exec -it $CONTROLLER bash"
