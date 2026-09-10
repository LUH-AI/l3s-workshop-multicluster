#!/usr/bin/env bash
# Usage: ./verify.sh [expected-image-tag]
#
# Reads config/clusters.json and checks, for every cluster, which image tag
# is actually running vs. the expected tag (default: current git commit
# short-sha). Prints a status table and sets the exit code to reflect the
# overall result - so Group 1's workflow can mark a run as failed.
#
# NOTE on "same code, same environment": this compares the image *tag*,
# which is convenient but mutable in principle. For a stronger guarantee,
# compare digests instead - see README.md ("Digest vs. Tag").
#
# Exit code: 0 = all clusters OK, 1 = at least one mismatch/unreachable/missing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLUSTERS_FILE="$REPO_ROOT/config/clusters.json"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required" >&2; exit 1; }
[[ -f "$CLUSTERS_FILE" ]] || { echo "ERROR: cluster config not found: $CLUSTERS_FILE" >&2; exit 1; }

EXPECTED_TAG="${1:-$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)}"

SSH_KEY="${SSH_KEY:-}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
[[ -n "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY")

echo "Expected (current git commit): ${EXPECTED_TAG}"
echo
printf '%-12s %-10s %-15s %s\n' "CLUSTER" "TYPE" "RUNNING" "STATUS"

OVERALL_STATUS=0

while IFS=$'\t' read -r NAME TYPE HOST PORT USER_NAME; do
  TARGET_OPTS=("${SSH_OPTS[@]}" -p "$PORT")

  if ! ssh "${TARGET_OPTS[@]}" "${USER_NAME}@${HOST}" true 2>/dev/null; then
    printf '%-12s %-10s %-15s %s\n' "$NAME" "$TYPE" "-" "UNREACHABLE"
    OVERALL_STATUS=1
    continue
  fi

  case "$TYPE" in
    docker)
      CONTAINER_NAME="$(jq -r --arg n "$NAME" '.clusters[] | select(.name==$n) | .container_name // "multicluster-workshop"' "$CLUSTERS_FILE")"
      RUNNING_IMAGE="$(ssh "${TARGET_OPTS[@]}" "${USER_NAME}@${HOST}" \
        "docker inspect --format='{{.Config.Image}}' '$CONTAINER_NAME' 2>/dev/null" || true)"
      ;;
    apptainer)
      SIF_PATH="$(jq -r --arg n "$NAME" '.clusters[] | select(.name==$n) | .sif_path // "~/multicluster-workshop.sif"' "$CLUSTERS_FILE")"
      RUNNING_IMAGE="$(ssh "${TARGET_OPTS[@]}" "${USER_NAME}@${HOST}" \
        "apptainer inspect --json '$SIF_PATH' 2>/dev/null" \
        | jq -r '.data.attributes.deffile // empty' \
        | grep -o 'From: docker://[^ ]*' | sed 's#From: docker://##' || true)"
      ;;
    *)
      RUNNING_IMAGE=""
      ;;
  esac

  RUNNING_TAG="${RUNNING_IMAGE##*:}"

  if [[ -z "$RUNNING_IMAGE" ]]; then
    printf '%-12s %-10s %-15s %s\n' "$NAME" "$TYPE" "-" "NOT DEPLOYED"
    OVERALL_STATUS=1
  elif [[ "$RUNNING_TAG" == "$EXPECTED_TAG" ]]; then
    printf '%-12s %-10s %-15s %s\n' "$NAME" "$TYPE" "$RUNNING_TAG" "OK"
  else
    printf '%-12s %-10s %-15s %s\n' "$NAME" "$TYPE" "$RUNNING_TAG" "OUTDATED (expected $EXPECTED_TAG)"
    OVERALL_STATUS=1
  fi
done < <(jq -r '.clusters[] | [.name, .type, .host, (.port // 22), .user] | @tsv' "$CLUSTERS_FILE")

exit $OVERALL_STATUS
