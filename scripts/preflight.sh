#!/usr/bin/env bash
# Sanity checks to run before a workshop session: local tooling present, and
# every cluster in config/clusters.json reachable via SSH.
#
# Exit code: 0 = all checks passed, 1 = at least one check failed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLUSTERS_FILE="$REPO_ROOT/config/clusters.json"

STATUS=0

check() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "OK   - $desc"
  else
    echo "FAIL - $desc"
    STATUS=1
  fi
}

echo "== Local tooling =="
check "docker installed" command -v docker
check "jq installed" command -v jq
check "ssh installed" command -v ssh
check "git installed" command -v git
check "ssh-agent has a key loaded (ssh-add ~/workshop-keys/runner_key if not)" \
  ssh-add -l

echo
echo "== Cluster reachability (config/clusters.json) =="
if [[ -f "$CLUSTERS_FILE" ]]; then
  for CLUSTER_NAME in $(jq -r 'keys[]' "$CLUSTERS_FILE"); do
    HOST=$(jq -r ".\"$CLUSTER_NAME\".host" "$CLUSTERS_FILE")
    PORT=$(jq -r ".\"$CLUSTER_NAME\".port // 22" "$CLUSTERS_FILE")
    USER_NAME=$(jq -r ".\"$CLUSTER_NAME\".user" "$CLUSTERS_FILE")

    check "$CLUSTER_NAME reachable (${USER_NAME}@${HOST}:${PORT})" \
      ssh -p "$PORT" -o BatchMode=yes -o ConnectTimeout=5 \
          -o StrictHostKeyChecking=accept-new "${USER_NAME}@${HOST}" true
  done
else
  echo "FAIL - cluster config not found: $CLUSTERS_FILE"
  STATUS=1
fi

exit $STATUS
