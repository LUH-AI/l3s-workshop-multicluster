#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${1:-luis}"
CONFIG_FILE="$(dirname "$0")/../config/clusters.json"

if ! command -v jq &> /dev/null; then
  echo "ERROR: jq is not installed"
  exit 1
fi

HOST=$(jq -r ".\"$CLUSTER_NAME\".host" "$CONFIG_FILE")
USER=$(jq -r ".\"$CLUSTER_NAME\".user" "$CONFIG_FILE")
KEY=$(jq -r ".\"$CLUSTER_NAME\".key" "$CONFIG_FILE" | sed "s|~|$HOME|")
REMOTE_PATH=$(jq -r ".\"$CLUSTER_NAME\".sync_path" "$CONFIG_FILE")

echo "Syncing code to $CLUSTER_NAME ($USER@$HOST:$REMOTE_PATH) ..."

rsync -avz --delete \
  -e "ssh -i $KEY -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10" \
  --exclude '.git' \
  --exclude '__pycache__' \
  "$(dirname "$0")/../" \
  "${USER}@${HOST}:${REMOTE_PATH}/"

echo "✓ Sync to $CLUSTER_NAME complete"