#!/usr/bin/env bash
# Deletes cluster B. Run ./cluster-b/delete.sh --help for details.
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash: do not rewrite /paths passed to docker.exe

usage() {
    cat <<'EOF'
Usage: ./cluster-b/delete.sh [--keep-data]

Deletes cluster B: its containers, the "cluster-b" network and the volume
"cluster-b-shared" (/shared). Works from Docker labels, so it does not need
cluster-b/generated/. The image cluster-b-slurm:latest is kept so the next
create.sh is fast (docker rmi cluster-b-slurm:latest removes it).

Options:
  --keep-data   keep the /shared volume (SIF images, job scripts, results)
  -h, --help    show this help
EOF
}

PROJECT=cluster-b
NETWORK=cluster-b
VOLUME=cluster-b-shared
KEEP_DATA=0

step() { printf '\n\033[36m==> %s\033[0m\n' "$*"; }
die()  { printf '\n\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
run()  { "$@" || die "'$*' failed with exit code $?"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --keep-data) KEEP_DATA=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *)           usage >&2; die "unknown option: $1" ;;
    esac
done

docker info --format '{{.ServerVersion}}' > /dev/null 2>&1 \
    || die "Docker is not running. Start Docker Desktop and try again."

step "Removing cluster B containers"
ids=$(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT" | tr -d '\r')
if [ -n "$ids" ]; then
    # shellcheck disable=SC2086
    run docker rm -f $ids
else
    echo "No containers"
fi

step "Removing network $NETWORK"
if docker network inspect "$NETWORK" > /dev/null 2>&1; then
    run docker network rm "$NETWORK"
else
    echo "No network"
fi

if (( KEEP_DATA )); then
    step "Keeping volume $VOLUME (--keep-data)"
else
    step "Removing volume $VOLUME"
    if docker volume inspect "$VOLUME" > /dev/null 2>&1; then
        run docker volume rm "$VOLUME"
    else
        echo "No volume"
    fi
fi

step "Cluster B deleted"
