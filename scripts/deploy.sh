#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${1:-}"
IMAGE_TAG="${2:-}"
CONFIG_FILE="$(dirname "$0")/../config/clusters.json"
REGISTRY="ghcr.io/<org>/project"

if [[ -z "$CLUSTER_NAME" || -z "$IMAGE_TAG" ]]; then
  echo "Usage: ./deploy.sh <cluster-name> <image-tag>"
  exit 1
fi

if ! command -v jq &> /dev/null; then
  echo "ERROR: jq is not installed (brew install jq)"
  exit 1
fi

if ! jq -e ".\"$CLUSTER_NAME\"" "$CONFIG_FILE" &> /dev/null; then
  echo "ERROR: cluster '$CLUSTER_NAME' not found in $CONFIG_FILE"
  exit 1
fi

HOST=$(jq -r ".\"$CLUSTER_NAME\".host" "$CONFIG_FILE")
PORT=$(jq -r ".\"$CLUSTER_NAME\".port" "$CONFIG_FILE")
USER=$(jq -r ".\"$CLUSTER_NAME\".user" "$CONFIG_FILE")
TYPE=$(jq -r ".\"$CLUSTER_NAME\".type" "$CONFIG_FILE")

# No -i <key> here on purpose: auth comes from whatever's loaded into a
# running ssh-agent (ssh-add ~/workshop-keys/runner_key locally, or the
# "Set up SSH agent" workflow step in CI). See doc/wp1_proposed_solution.md
# §5. The "key" field in clusters.json is documentation of which key a
# cluster expects, not something these scripts read.

# Optional: authenticate against a private GHCR package before pulling.
# Only needed on a real, separate cluster - the local Docker simulators
# share the host's docker.sock, so they inherit whatever `docker login` you
# already did on your laptop. If GHCR_USER/GHCR_TOKEN aren't set (e.g. your
# package is public), this is skipped entirely.
if [[ -n "${GHCR_TOKEN:-}" && -n "${GHCR_USER:-}" ]]; then
  echo "==> Logging in to ghcr.io on $CLUSTER_NAME as $GHCR_USER"
  if [[ "$TYPE" == "docker" ]]; then
    ssh -p "$PORT" -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
      "${USER}@${HOST}" "docker login ghcr.io -u '${GHCR_USER}' --password-stdin" <<<"$GHCR_TOKEN"
  elif [[ "$TYPE" == "apptainer" ]]; then
    # Apptainer's registry login is modeled after `docker login`; verify
    # --password-stdin is supported by the apptainer version on your target
    # if this fails.
    ssh -p "$PORT" -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
      "${USER}@${HOST}" "apptainer registry login --username '${GHCR_USER}' --password-stdin docker://ghcr.io" <<<"$GHCR_TOKEN"
  fi
fi

echo "Deploying $REGISTRY:$IMAGE_TAG to $CLUSTER_NAME ($TYPE) at $HOST:$PORT ..."

if [[ "$TYPE" == "docker" ]]; then
  REMOTE_CMD="docker pull ${REGISTRY}:${IMAGE_TAG} && docker run --rm ${REGISTRY}:${IMAGE_TAG}"
elif [[ "$TYPE" == "apptainer" ]]; then
  REMOTE_CMD="apptainer pull --force project_${IMAGE_TAG}.sif docker://${REGISTRY}:${IMAGE_TAG} && apptainer run project_${IMAGE_TAG}.sif"
else
  echo "ERROR: unknown type '$TYPE' for cluster '$CLUSTER_NAME'"
  exit 1
fi

if ssh -p "$PORT" -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
   "${USER}@${HOST}" "$REMOTE_CMD"; then
  echo "✓ Deployment to $CLUSTER_NAME succeeded"
  exit 0
else
  echo "✗ Deployment to $CLUSTER_NAME failed"
  exit 1
fi