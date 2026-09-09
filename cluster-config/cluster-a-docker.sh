#!/usr/bin/env bash
# Prepares the local stand-in for Cluster A (see local-docker.sh for how it
# works). Copy this file to cluster-b-docker.sh with a different container
# name/port to get the second local target system - this is deliberately
# left as an exercise rather than duplicated here.
#
# Usage: ./cluster-a-docker.sh <public-key-file>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUBKEY_FILE="${1:?path to an SSH public key required}"

"$SCRIPT_DIR/local-docker.sh" cluster-a 2201 "$PUBKEY_FILE"
