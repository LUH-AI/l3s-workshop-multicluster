#!/usr/bin/env bash
# Prepares/tests the LUIS target. Unlike Cluster A/B, LUIS isn't simulated
# via a local Docker container here: Apptainer needs real Linux user
# namespaces that don't nest well inside Docker. Run this directly on a
# LUIS login node to test the pull (and `--run` smoke-test) steps deploy.sh
# performs remotely over SSH (see WP5).
#
# Uses the same REGISTRY convention as scripts/deploy.sh/verify.sh - update
# <org> below to your own GitHub username - and the same project_<tag>.sif
# naming, so verify.sh can find what this script deployed.
#
# Usage: ./luis-apptainer.sh <image-tag>
set -euo pipefail

REGISTRY="ghcr.io/<org>/project"

IMAGE_TAG="${1:?image tag required, e.g. dummy or a git sha}"
SIF_PATH="$HOME/project_${IMAGE_TAG}.sif"
IMAGE="${REGISTRY}:${IMAGE_TAG}"

command -v apptainer >/dev/null 2>&1 || { echo "ERROR: apptainer not found in PATH" >&2; exit 1; }

echo "==> Pulling ${IMAGE} as ${SIF_PATH}"
apptainer pull --force "$SIF_PATH" "docker://${IMAGE}"

echo "==> Running ${SIF_PATH}"
apptainer run "$SIF_PATH"
