#!/usr/bin/env bash
set -uo pipefail

CONFIG_FILE="$(dirname "$0")/../config/clusters.json"
REGISTRY="ghcr.io/evavormschlag/project"
EXPECTED_TAG="${1:-$(git rev-parse --short HEAD)}"
# Optional: check only this cluster instead of every entry in clusters.json.
ONLY_CLUSTER="${2:-}"

if ! command -v jq &> /dev/null; then
  echo "ERROR: jq is not installed (macOS: brew install jq, Debian/Ubuntu: sudo apt install jq)"
  exit 1
fi

if [[ -n "$ONLY_CLUSTER" ]]; then
  if ! jq -e --arg c "$ONLY_CLUSTER" 'has($c)' "$CONFIG_FILE" &> /dev/null; then
    echo "ERROR: cluster '$ONLY_CLUSTER' not found in $CONFIG_FILE"
    exit 1
  fi
  CLUSTERS="$ONLY_CLUSTER"
else
  CLUSTERS=$(jq -r 'keys[]' "$CONFIG_FILE")
fi

echo "Expected tag (current git commit): $EXPECTED_TAG"
echo ""
printf "%-12s %-15s %s\n" "CLUSTER" "RUNNING TAG" "STATUS"
printf "%-12s %-15s %s\n" "-------" "-------------" "------"

OVERALL_STATUS=0

for CLUSTER_NAME in $CLUSTERS; do
  HOST=$(jq -r ".\"$CLUSTER_NAME\".host" "$CONFIG_FILE")
  PORT=$(jq -r ".\"$CLUSTER_NAME\".port // 22" "$CONFIG_FILE")
  USER=$(jq -r ".\"$CLUSTER_NAME\".user" "$CONFIG_FILE")
  TYPE=$(jq -r ".\"$CLUSTER_NAME\".type" "$CONFIG_FILE")

  if ! ssh -p "$PORT" -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
       "${USER}@${HOST}" "echo ok" &> /dev/null; then
    printf "%-12s %-15s %s\n" "$CLUSTER_NAME" "-" "UNREACHABLE ✗"
    OVERALL_STATUS=1
    continue
  fi

  # Written by deploy.sh after each successful pull (see MARK_DEPLOYED there).
  RUNNING_TAG=$(ssh -p "$PORT" "${USER}@${HOST}" "cat ~/.deployed_tag 2>/dev/null" 2>/dev/null)

  # Fallback for apptainer clusters deployed before the marker existed: the
  # tag is part of the .sif filename.
  if [[ -z "$RUNNING_TAG" && "$TYPE" == "apptainer" ]]; then
    LATEST_SIF=$(ssh -p "$PORT" "${USER}@${HOST}" \
      "ls -t ~/project_*.sif 2>/dev/null | head -1" 2>/dev/null)
    RUNNING_TAG=$(echo "$LATEST_SIF" | sed -E 's/.*project_(.+)\.sif/\1/')
  fi

  if [[ -z "$RUNNING_TAG" ]]; then
    printf "%-12s %-15s %s\n" "$CLUSTER_NAME" "-" "NO DEPLOYMENT ✗"
    OVERALL_STATUS=1
  elif [[ "$RUNNING_TAG" == "$EXPECTED_TAG" ]]; then
    printf "%-12s %-15s %s\n" "$CLUSTER_NAME" "$RUNNING_TAG" "✓"
  else
    printf "%-12s %-15s %s\n" "$CLUSTER_NAME" "$RUNNING_TAG" "OUTDATED ✗"
    OVERALL_STATUS=1
  fi
done

echo ""
if [[ $OVERALL_STATUS -eq 0 ]]; then
  echo "All clusters up to date."
else
  echo "At least one cluster is outdated or unreachable."
fi

exit $OVERALL_STATUS