#!/usr/bin/env bash
# Prepares/tests the LUIS target. Unlike Cluster A/B, LUIS isn't simulated
# via a local Docker container here: Apptainer needs real Linux user
# namespaces that don't nest well inside Docker. Run this directly on a
# machine that has Apptainer installed (e.g. a LUIS login node) to test the
# pull+run steps deploy.sh will later perform remotely over SSH.
#
# Usage: ./luis-apptainer.sh <image-tag> [sif-path]
set -euo pipefail

GHCR_ORG="${GHCR_ORG:-org}"
GHCR_PROJECT="${GHCR_PROJECT:-project}"

IMAGE_TAG="${1:?image tag required, e.g. dummy or a git sha}"
SIF_PATH="${2:-$HOME/multicluster-workshop.sif}"
IMAGE="ghcr.io/${GHCR_ORG}/${GHCR_PROJECT}:${IMAGE_TAG}"

command -v apptainer >/dev/null 2>&1 || { echo "ERROR: apptainer not found in PATH" >&2; exit 1; }

echo "==> Pulling ${IMAGE} as ${SIF_PATH}"
apptainer pull --force "$SIF_PATH" "docker://${IMAGE}"

echo "==> Running ${SIF_PATH}"
apptainer run "$SIF_PATH"
