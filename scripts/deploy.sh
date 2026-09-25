#!/usr/bin/env bash
# Usage: ./deploy.sh <cluster-name> <image-tag> [--run]
#
# Default is pull-only: the image (docker) or project_<tag>.sif (apptainer)
# is placed on the cluster but not started. On HPC targets a run from here
# would execute on the login node, which kills real workloads - experiments
# are started later via sbatch. --run additionally starts it once right
# after the pull, as a smoke test.
set -euo pipefail

CLUSTER_NAME="${1:-}"
IMAGE_TAG="${2:-}"
RUN_AFTER_PULL=false
CONFIG_FILE="$(dirname "$0")/../config/clusters.json"
# Derived from the repo's origin remote (github.com/<owner>/<repo>), so a
# fork pulls its own image without editing anything - the same owner the
# workflows push to via github.repository_owner. GHCR needs it lowercase.
# Set REGISTRY in the environment to override.
if [[ -z "${REGISTRY:-}" ]]; then
  ORIGIN_URL=$(git -C "$(dirname "$0")" remote get-url origin 2>/dev/null || true)
  OWNER=$(sed -E 's#^(https://|git@)github\.com[:/]([^/]+)/.*#\2#' <<< "$ORIGIN_URL" | tr '[:upper:]' '[:lower:]')
  if [[ -z "$OWNER" || "$OWNER" == "$ORIGIN_URL" ]]; then
    echo "ERROR: can't derive the GHCR owner from git remote 'origin' ('$ORIGIN_URL') - set REGISTRY=ghcr.io/<owner>/project"
    exit 1
  fi
  REGISTRY="ghcr.io/${OWNER}/project"
fi

if [[ -z "$CLUSTER_NAME" || -z "$IMAGE_TAG" ]]; then
  echo "Usage: ./deploy.sh <cluster-name> <image-tag> [--run]"
  exit 1
fi

case "${3:-}" in
  "") ;;
  --run) RUN_AFTER_PULL=true ;;
  *) echo "ERROR: unknown option '$3' (only --run is supported)"; exit 1 ;;
esac

if ! command -v jq &> /dev/null; then
  echo "ERROR: jq is not installed (macOS: brew install jq, Debian/Ubuntu: sudo apt install jq)"
  exit 1
fi

if ! jq -e ".\"$CLUSTER_NAME\"" "$CONFIG_FILE" &> /dev/null; then
  echo "ERROR: cluster '$CLUSTER_NAME' not found in $CONFIG_FILE"
  exit 1
fi

HOST=$(jq -r ".\"$CLUSTER_NAME\".host" "$CONFIG_FILE")
PORT=$(jq -r ".\"$CLUSTER_NAME\".port // 22" "$CONFIG_FILE")
USER=$(jq -r ".\"$CLUSTER_NAME\".user" "$CONFIG_FILE")
TYPE=$(jq -r ".\"$CLUSTER_NAME\".type" "$CONFIG_FILE")

# No -i <key> here on purpose: auth comes from whatever's loaded into a
# running ssh-agent (ssh-add ~/workshop-keys/runner_key locally, or the
# "Set up SSH agent" workflow step in CI). See doc/wp1_proposed_solution.md
# §5. The "key" field in clusters.json is documentation of which key a
# cluster expects, not something these scripts read.

# Optional: authenticate against a private GHCR package before pulling.
# Needed on every cluster whose package is private - including the local
# simulator: it shares the host's docker.sock, but registry credentials
# live with the docker *client* (inside the container), so your laptop's
# `docker login` does not carry over. The workflows pass GHCR_USER/
# GHCR_TOKEN; locally, either export them or make the package public. If
# they aren't set, this is skipped entirely.
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

if [[ "$RUN_AFTER_PULL" == true ]]; then
  echo "Deploying $REGISTRY:$IMAGE_TAG to $CLUSTER_NAME ($TYPE) at $HOST:$PORT (pull + run) ..."
else
  echo "Deploying $REGISTRY:$IMAGE_TAG to $CLUSTER_NAME ($TYPE) at $HOST:$PORT (pull only) ..."
fi

# Records which tag was deployed, only after a successful pull. This is
# what verify.sh reads - image timestamps are no reliable signal (builds
# from cache share one CreatedAt), and on the simulator the shared host
# Docker also holds images the runner built itself.
MARK_DEPLOYED="echo '${IMAGE_TAG}' > ~/.deployed_tag"

if [[ "$TYPE" == "docker" ]]; then
  REMOTE_CMD="docker pull ${REGISTRY}:${IMAGE_TAG} && ${MARK_DEPLOYED}"
  [[ "$RUN_AFTER_PULL" == true ]] && REMOTE_CMD+=" && docker run --rm ${REGISTRY}:${IMAGE_TAG}"
elif [[ "$TYPE" == "apptainer" ]]; then
  # Only after a successful pull, drop every other project_*.sif so the
  # home quota doesn't fill up with one .sif per push - the cluster keeps
  # exactly the current one (verify.sh reads the tag from its filename).
  REMOTE_CMD="apptainer pull --force project_${IMAGE_TAG}.sif docker://${REGISTRY}:${IMAGE_TAG}"
  REMOTE_CMD+=" && find . -maxdepth 1 -name 'project_*.sif' ! -name 'project_${IMAGE_TAG}.sif' -print -delete"
  REMOTE_CMD+=" && ${MARK_DEPLOYED}"
  [[ "$RUN_AFTER_PULL" == true ]] && REMOTE_CMD+=" && apptainer run project_${IMAGE_TAG}.sif"
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