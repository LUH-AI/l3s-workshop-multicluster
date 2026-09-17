#!/usr/bin/env bash
# Prepares the local stand-in for Cluster B (see local-docker.sh for how it
# works). Port/user here must match the "cluster-b" entry in
# config/clusters.json. See cluster-a-docker.sh for Cluster A.
#
# Usage: ./cluster-b-docker.sh <public-key-file>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUBKEY_FILE="${1:?path to an SSH public key required}"

"$SCRIPT_DIR/local-docker.sh" cluster-b 2223 clusterb "$PUBKEY_FILE"
