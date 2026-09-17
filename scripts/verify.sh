#!/usr/bin/env bash
set -uo pipefail  # kein -e: ein fehlgeschlagenes Cluster soll die anderen nicht abbrechen

CONFIG_FILE="$(dirname "$0")/../config/clusters.json"
REGISTRY="ghcr.io/evavormschlag/project"
EXPECTED_TAG="${1:-$(git rev-parse --short HEAD)}"

if ! command -v jq &> /dev/null; then
  echo "Fehler: jq ist nicht installiert (brew install jq)"
  exit 1
fi

echo "Erwarteter Tag (aktueller Git-Commit): $EXPECTED_TAG"
echo ""
printf "%-12s %-15s %s\n" "CLUSTER" "LAUFENDER TAG" "STATUS"
printf "%-12s %-15s %s\n" "-------" "-------------" "------"

OVERALL_STATUS=0

for CLUSTER_NAME in $(jq -r 'keys[]' "$CONFIG_FILE"); do
  HOST=$(jq -r ".\"$CLUSTER_NAME\".host" "$CONFIG_FILE")
  PORT=$(jq -r ".\"$CLUSTER_NAME\".port" "$CONFIG_FILE")
  USER=$(jq -r ".\"$CLUSTER_NAME\".user" "$CONFIG_FILE")
  KEY=$(jq -r ".\"$CLUSTER_NAME\".key" "$CONFIG_FILE" | sed "s|~|$HOME|")
  TYPE=$(jq -r ".\"$CLUSTER_NAME\".type" "$CONFIG_FILE")

  # Erreichbarkeit zuerst prüfen, separat von "outdated"
  if ! ssh -p "$PORT" -i "$KEY" -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
       "${USER}@${HOST}" "echo ok" &> /dev/null; then
    printf "%-12s %-15s %s\n" "$CLUSTER_NAME" "-" "UNREACHABLE ✗"
    OVERALL_STATUS=1
    continue
  fi

  if [[ "$TYPE" == "docker" ]]; then
    RUNNING_TAG=$(ssh -p "$PORT" -i "$KEY" "${USER}@${HOST}" \
      "docker images --format '{{.Repository}}:{{.Tag}}\t{{.CreatedAt}}' | grep '^${REGISTRY}:' | sort -k2 -r | head -1 | cut -f1 | cut -d: -f2" 2>/dev/null)
  elif [[ "$TYPE" == "apptainer" ]]; then
    LATEST_SIF=$(ssh -p "$PORT" -i "$KEY" "${USER}@${HOST}" \
      "ls -t ~/project_*.sif 2>/dev/null | head -1" 2>/dev/null)
    RUNNING_TAG=$(echo "$LATEST_SIF" | sed -E 's/.*project_(.+)\.sif/\1/')
  else
    RUNNING_TAG=""
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
  echo "Alle Cluster auf dem aktuellen Stand."
else
  echo "Mindestens ein Cluster ist nicht aktuell oder nicht erreichbar."
fi

exit $OVERALL_STATUS