#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${1:-}"
IMAGE_TAG="${2:-}"
CONFIG_FILE="$(dirname "$0")/../config/clusters.json"
REGISTRY="ghcr.io/evavormschlag/project"

if [[ -z "$CLUSTER_NAME" || -z "$IMAGE_TAG" ]]; then
  echo "Usage: ./deploy.sh <cluster-name> <image-tag>"
  exit 1
fi

if ! command -v jq &> /dev/null; then
  echo "Fehler: jq ist nicht installiert (brew install jq)"
  exit 1
fi

if ! jq -e ".\"$CLUSTER_NAME\"" "$CONFIG_FILE" &> /dev/null; then
  echo "Fehler: Cluster '$CLUSTER_NAME' nicht in $CONFIG_FILE gefunden"
  exit 1
fi

HOST=$(jq -r ".\"$CLUSTER_NAME\".host" "$CONFIG_FILE")
PORT=$(jq -r ".\"$CLUSTER_NAME\".port" "$CONFIG_FILE")
USER=$(jq -r ".\"$CLUSTER_NAME\".user" "$CONFIG_FILE")
KEY=$(jq -r ".\"$CLUSTER_NAME\".key" "$CONFIG_FILE" | sed "s|~|$HOME|")
TYPE=$(jq -r ".\"$CLUSTER_NAME\".type" "$CONFIG_FILE")

echo "Deploying $REGISTRY:$IMAGE_TAG to $CLUSTER_NAME ($TYPE) at $HOST:$PORT ..."

if [[ "$TYPE" == "docker" ]]; then
  REMOTE_CMD="docker pull ${REGISTRY}:${IMAGE_TAG} && docker run --rm ${REGISTRY}:${IMAGE_TAG}"
elif [[ "$TYPE" == "apptainer" ]]; then
  REMOTE_CMD="apptainer pull --force project_${IMAGE_TAG}.sif docker://${REGISTRY}:${IMAGE_TAG} && apptainer run project_${IMAGE_TAG}.sif"
else
  echo "Fehler: Unbekannter Typ '$TYPE' für Cluster '$CLUSTER_NAME'"
  exit 1
fi

if ssh -p "$PORT" -i "$KEY" -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
   "${USER}@${HOST}" "$REMOTE_CMD"; then
  echo "✓ Deployment auf $CLUSTER_NAME erfolgreich"
  exit 0
else
  echo "✗ Deployment auf $CLUSTER_NAME fehlgeschlagen"
  exit 1
fi