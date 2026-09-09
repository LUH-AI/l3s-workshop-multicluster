#!/usr/bin/env bash
# Usage: ./sync.sh <cluster-name> <remote-path>
#
# Optional rsync of src/ to a cluster, for cases where you need source code
# directly on the target machine (e.g. quick debugging). Kept deliberately
# separate from the image-based deploy.sh logic - do not call this from
# deploy.sh, and do not fold deploy.sh's docker/apptainer logic in here.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLUSTERS_FILE="$REPO_ROOT/config/clusters.json"

usage() { echo "Usage: $0 <cluster-name> <remote-path>" >&2; exit 1; }
[[ $# -eq 2 ]] || usage

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required" >&2; exit 1; }

CLUSTER_NAME="$1"
REMOTE_PATH="$2"

CLUSTER_JSON="$(jq -e --arg name "$CLUSTER_NAME" '.clusters[] | select(.name == $name)' "$CLUSTERS_FILE")" \
  || { echo "ERROR: unknown cluster '$CLUSTER_NAME'" >&2; exit 2; }

HOST="$(jq -r '.host' <<<"$CLUSTER_JSON")"
PORT="$(jq -r '.port // 22' <<<"$CLUSTER_JSON")"
USER_NAME="$(jq -r '.user' <<<"$CLUSTER_JSON")"

rsync -avz --delete \
  -e "ssh -p $PORT -o StrictHostKeyChecking=accept-new" \
  "$REPO_ROOT/src/" "${USER_NAME}@${HOST}:${REMOTE_PATH}/"
