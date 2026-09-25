#!/usr/bin/env bash
# Prepares the local stand-in for Cluster A - the only example/simulator
# cluster (see local-docker.sh for how it works). Port/user here must
# match the "cluster-a" entry in config/clusters.json.
#
# Usage: ./cluster-a-docker.sh <public-key-file>
#
# Installs <public-key-file> into the container's ~/.ssh/authorized_keys
# at creation time - that's the normal way the key gets there. To add or
# refresh a key on an already-running container instead of rebuilding it,
# see "Adding the SSH key to Cluster A" in README.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUBKEY_FILE="${1:?path to an SSH public key required}"

"$SCRIPT_DIR/local-docker.sh" cluster-a 2222 clustera "$PUBKEY_FILE"
