#!/usr/bin/env bash
# Usage: ./deploy.sh <cluster-name> <image-tag>
#
# Pulls ghcr.io/${GHCR_ORG}/${GHCR_PROJECT}:<image-tag> on the given cluster
# and (re)starts it - via Docker on cluster-a/cluster-b, via Apptainer on
# luis. Cluster type/connection info comes from config/clusters.json.
#
# Exit codes:
#   0 = success
#   1 = usage / local config error (e.g. jq missing, clusters.json missing)
#   2 = unknown cluster name or unknown cluster type
#   3 = cluster not reachable via SSH
#   4 = remote deploy command failed
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLUSTERS_FILE="$REPO_ROOT/config/clusters.json"

GHCR_ORG="${GHCR_ORG:-org}"
GHCR_PROJECT="${GHCR_PROJECT:-project}"

usage() {
  echo "Usage: $0 <cluster-name> <image-tag>" >&2
  exit 1
}

[[ $# -eq 2 ]] || usage
CLUSTER_NAME="$1"
IMAGE_TAG="$2"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required" >&2; exit 1; }
[[ -f "$CLUSTERS_FILE" ]] || { echo "ERROR: cluster config not found: $CLUSTERS_FILE" >&2; exit 1; }

CLUSTER_JSON="$(jq -e --arg name "$CLUSTER_NAME" '.clusters[] | select(.name == $name)' "$CLUSTERS_FILE")" \
  || { echo "ERROR: unknown cluster '$CLUSTER_NAME' (see config/clusters.json)" >&2; exit 2; }

TYPE="$(jq -r '.type' <<<"$CLUSTER_JSON")"
HOST="$(jq -r '.host' <<<"$CLUSTER_JSON")"
PORT="$(jq -r '.port // 22' <<<"$CLUSTER_JSON")"
USER_NAME="$(jq -r '.user' <<<"$CLUSTER_JSON")"

SSH_KEY="${SSH_KEY:-}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -p "$PORT")
[[ -n "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY")

IMAGE="ghcr.io/${GHCR_ORG}/${GHCR_PROJECT}:${IMAGE_TAG}"

echo "==> Deploying ${IMAGE} to ${CLUSTER_NAME} (${TYPE}) at ${USER_NAME}@${HOST}:${PORT}"

if ! ssh "${SSH_OPTS[@]}" "${USER_NAME}@${HOST}" true 2>/dev/null; then
  echo "ERROR: cluster '${CLUSTER_NAME}' (${HOST}) is not reachable via SSH" >&2
  exit 3
fi

# Optional: authenticate the target against the private GHCR package.
# GHCR_PULL_TOKEN is piped over the SSH session's stdin, never embedded in
# the remote command string, so it never shows up in a `ps` listing.
remote_ghcr_login() {
  if [[ -n "${GHCR_PULL_TOKEN:-}" ]]; then
    ssh "${SSH_OPTS[@]}" "${USER_NAME}@${HOST}" \
      "docker login ghcr.io -u '${GHCR_PULL_USER:-$GHCR_ORG}' --password-stdin" <<<"$GHCR_PULL_TOKEN"
  fi
}

case "$TYPE" in
  docker)
    CONTAINER_NAME="$(jq -r '.container_name // "multicluster-workshop"' <<<"$CLUSTER_JSON")"
    remote_ghcr_login
    if ! ssh "${SSH_OPTS[@]}" "${USER_NAME}@${HOST}" bash -s -- "$IMAGE" "$CONTAINER_NAME" <<'REMOTE'
set -euo pipefail
IMAGE="$1"
NAME="$2"
docker pull "$IMAGE"
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" --restart unless-stopped "$IMAGE"
REMOTE
    then
      echo "ERROR: docker deploy failed on ${CLUSTER_NAME}" >&2
      exit 4
    fi
    ;;
  apptainer)
    SIF_PATH="$(jq -r '.sif_path // "~/multicluster-workshop.sif"' <<<"$CLUSTER_JSON")"
    if ! ssh "${SSH_OPTS[@]}" "${USER_NAME}@${HOST}" bash -s -- "$IMAGE" "$SIF_PATH" <<'REMOTE'
set -euo pipefail
IMAGE="$1"
SIF="$2"
apptainer pull --force "$SIF" "docker://$IMAGE"
apptainer run "$SIF"
REMOTE
    then
      echo "ERROR: apptainer deploy failed on ${CLUSTER_NAME}" >&2
      exit 4
    fi
    ;;
  *)
    echo "ERROR: unknown cluster type '${TYPE}' for ${CLUSTER_NAME}" >&2
    exit 2
    ;;
esac

echo "==> ${CLUSTER_NAME}: deploy OK (${IMAGE})"
