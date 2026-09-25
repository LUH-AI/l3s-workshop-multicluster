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
  local HOST PORT USER REMOTE_PATH
  HOST=$(jq -r ".\"$CLUSTER_NAME\".host" "$CONFIG_FILE")
  PORT=$(jq -r ".\"$CLUSTER_NAME\".port // 22" "$CONFIG_FILE")
  USER=$(jq -r ".\"$CLUSTER_NAME\".user" "$CONFIG_FILE")
  REMOTE_PATH=$(jq -r ".\"$CLUSTER_NAME\".sync_path" "$CONFIG_FILE")

  echo "Syncing code to $CLUSTER_NAME ($USER@$HOST:$PORT:$REMOTE_PATH) ..."

  # Explicit if/else, not just relying on `set -e`: this function runs
  # under `sync_one ... || STATUS=1` in the multi-cluster loop below, and
  # bash suspends -e for the whole function body in that context - without
  # this check, a failed rsync would still fall through to the "success"
  # echo and report a passing sync.
  if rsync -avz --delete \
    -e "ssh -p $PORT -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10" \
    --exclude '.git' \
    --exclude '__pycache__' \
    "$(dirname "$0")/../" \
    "${USER}@${HOST}:${REMOTE_PATH}/"; then
    echo "✓ Sync to $CLUSTER_NAME complete"
    return 0
  else
    echo "✗ Sync to $CLUSTER_NAME failed" >&2
    return 1
  fi
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
  # Not an error: a config with only Docker simulators (no sync_path) is
  # valid, and the on-push workflow must not fail just because there is
  # nothing to sync yet.
  if [[ -z "$CLUSTERS" ]]; then
    echo "No clusters with a sync_path found in $CONFIG_FILE - nothing to sync"
    exit 0
  fi
  STATUS=0
  while IFS= read -r CLUSTER_NAME; do
    sync_one "$CLUSTER_NAME" || STATUS=1
  done <<< "$CLUSTERS"
  exit $STATUS
fi
