#!/usr/bin/env bash
# Sanity checks to run before a workshop session: local tooling present, and
# every cluster in config/clusters.json reachable via SSH.
#
# Exit code: 0 = all checks passed, 1 = at least one check failed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLUSTERS_FILE="$REPO_ROOT/config/clusters.json"

STATUS=0
SSH_KEY="${SSH_KEY:-}"

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

echo
echo "== Cluster reachability (config/clusters.json) =="
if [[ -f "$CLUSTERS_FILE" ]]; then
  while IFS=$'\t' read -r NAME HOST PORT USER_NAME; do
    SSH_ARGS=(-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -p "$PORT")
    [[ -n "$SSH_KEY" ]] && SSH_ARGS+=(-i "$SSH_KEY")
    check "$NAME reachable (${USER_NAME}@${HOST}:${PORT})" \
      ssh "${SSH_ARGS[@]}" "${USER_NAME}@${HOST}" true
  done < <(jq -r '.clusters[] | [.name, .host, (.port // 22), .user] | @tsv' "$CLUSTERS_FILE")
else
  echo "FAIL - cluster config not found: $CLUSTERS_FILE"
  STATUS=1
fi

exit $STATUS
