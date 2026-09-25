#!/usr/bin/env bash
# Usage: ./sync.sh [cluster-name]
#
# Rsyncs the repo to one cluster (if given) or to every cluster in
# config/clusters.json that defines a sync_path (if omitted) - meant for
# HPC/Apptainer targets where having raw source on disk is useful (e.g.
# for `pixi install`), not for Docker simulators like cluster-a, whose
# deployed image already contains everything and typically has no
# sync_path at all.
set -euo pipefail

CONFIG_FILE="$(dirname "$0")/../config/clusters.json"

command -v jq &> /dev/null || { echo "ERROR: jq is not installed"; exit 1; }

sync_one() {
  local CLUSTER_NAME="$1"
  local HOST USER REMOTE_PATH
  HOST=$(jq -r ".\"$CLUSTER_NAME\".host" "$CONFIG_FILE")
  USER=$(jq -r ".\"$CLUSTER_NAME\".user" "$CONFIG_FILE")
  REMOTE_PATH=$(jq -r ".\"$CLUSTER_NAME\".sync_path" "$CONFIG_FILE")

  echo "Syncing code to $CLUSTER_NAME ($USER@$HOST:$REMOTE_PATH) ..."

  rsync -avz --delete \
    -e "ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10" \
    --exclude '.git' \
    --exclude '__pycache__' \
    "$(dirname "$0")/../" \
    "${USER}@${HOST}:${REMOTE_PATH}/"

  echo "✓ Sync to $CLUSTER_NAME complete"
}

if [[ $# -ge 1 ]]; then
  CLUSTER_NAME="$1"
  if ! jq -e ".\"$CLUSTER_NAME\"" "$CONFIG_FILE" &> /dev/null; then
    echo "ERROR: cluster '$CLUSTER_NAME' not found in $CONFIG_FILE" >&2
    exit 1
  fi
  SYNC_PATH=$(jq -r ".\"$CLUSTER_NAME\".sync_path // empty" "$CONFIG_FILE")
  if [[ -z "$SYNC_PATH" ]]; then
    echo "ERROR: cluster '$CLUSTER_NAME' has no sync_path configured in $CONFIG_FILE" >&2
    exit 1
  fi
  sync_one "$CLUSTER_NAME"
else
  CLUSTERS=$(jq -r 'to_entries[] | select(.value.sync_path != null) | .key' "$CONFIG_FILE")
  if [[ -z "$CLUSTERS" ]]; then
    echo "No clusters with a sync_path found in $CONFIG_FILE" >&2
    exit 1
  fi
  STATUS=0
  while IFS= read -r CLUSTER_NAME; do
    sync_one "$CLUSTER_NAME" || STATUS=1
  done <<< "$CLUSTERS"
  exit $STATUS
fi
