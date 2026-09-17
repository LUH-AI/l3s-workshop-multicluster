#!/usr/bin/env bash
# Prepares the local stand-in for Cluster A (see local-docker.sh for how it
# works). Port/user here must match the "cluster-a" entry in
# config/clusters.json. See cluster-b-docker.sh for Cluster B.
#
# Usage: ./cluster-a-docker.sh <public-key-file>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUBKEY_FILE="${1:?path to an SSH public key required}"

"$SCRIPT_DIR/local-docker.sh" cluster-a 2222 clustera "$PUBKEY_FILE"
