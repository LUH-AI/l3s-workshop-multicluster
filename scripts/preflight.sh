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
WARNINGS=0

check() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "  OK   - $desc"
  else
    echo "  FAIL - $desc"
    STATUS=1
  fi
}

warn() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "  OK   - $desc"
  else
    echo "  WARN - $desc"
    WARNINGS=$((WARNINGS + 1))
  fi
}

# ── 1. Required system tools ────────────────────────────────────────
echo "== Required system tools =="
check "bash available"      command -v bash
check "git installed"       command -v git
check "jq installed"        command -v jq
check "ssh installed"       command -v ssh
check "rsync installed"     command -v rsync
check "docker installed"    command -v docker

# ── 2. Docker daemon ────────────────────────────────────────────────
echo
echo "== Docker daemon =="
check "docker daemon reachable (docker info)" docker info

# Check if cluster-a simulator is running
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^cluster-a$'; then
  echo "  OK   - cluster-a container is running"
else
  echo "  FAIL - cluster-a container is not running"
  echo "         Run: ./cluster-config/local-docker.sh cluster-a ~/workshop-keys/runner_key.pub"
  STATUS=1
fi

# ── 3. SSH agent and keys ───────────────────────────────────────────
echo
echo "== SSH agent =="
check "ssh-agent has at least one key loaded (ssh-add ~/workshop-keys/runner_key if not)" \
  ssh-add -l

if [[ -f "$HOME/workshop-keys/runner_key" ]]; then
  echo "  OK   - workshop SSH key exists at ~/workshop-keys/runner_key"
else
  echo "  FAIL - no key at ~/workshop-keys/runner_key"
  echo "         Run: ssh-keygen -t ed25519 -f ~/workshop-keys/runner_key -N \"\""
  STATUS=1
fi

# ── 4. GHCR access ──────────────────────────────────────────────────
echo
echo "== GHCR (GitHub Container Registry) =="

# Derive the registry namespace the same way deploy.sh does
ORIGIN_URL=$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || echo "")
if [[ -n "$ORIGIN_URL" ]]; then
  # Extract owner from git@github.com:owner/repo.git or https://github.com/owner/repo.git
  OWNER=$(echo "$ORIGIN_URL" | sed -E 's#.*(github\.com[:/])([^/]+)/.*#\2#' | tr '[:upper:]' '[:lower:]')
  REGISTRY="ghcr.io/${OWNER}/project"
  echo "  INFO - derived registry: $REGISTRY"

  # Test pull access (doesn't require GHCR_TOKEN if the package is public)
  if docker pull "$REGISTRY:dummy" >/dev/null 2>&1; then
    echo "  OK   - can pull $REGISTRY:dummy (package is public or docker login active)"
  else
    echo "  WARN - cannot pull $REGISTRY:dummy"
    echo "         Either the package is private (make it public in GitHub Packages settings)"
    echo "         or no image has been pushed yet (run build.yml first)"
    WARNINGS=$((WARNINGS + 1))
  fi
else
  echo "  WARN - could not determine origin remote — skipping registry check"
  WARNINGS=$((WARNINGS + 1))
fi

# ── 5. Cluster reachability ─────────────────────────────────────────
echo
echo "== Cluster reachability (config/clusters.json) =="
if [[ -f "$CLUSTERS_FILE" ]]; then
  CLUSTER_COUNT=$(jq 'keys | length' "$CLUSTERS_FILE")
  echo "  INFO - $CLUSTER_COUNT cluster(s) configured"

  for CLUSTER_NAME in $(jq -r 'keys[]' "$CLUSTERS_FILE"); do
    HOST=$(jq -r ".\"$CLUSTER_NAME\".host" "$CLUSTERS_FILE")
    PORT=$(jq -r ".\"$CLUSTER_NAME\".port // 22" "$CLUSTERS_FILE")
    USER_NAME=$(jq -r ".\"$CLUSTER_NAME\".user" "$CLUSTERS_FILE")
    TYPE=$(jq -r ".\"$CLUSTER_NAME\".type // \"unknown\"" "$CLUSTERS_FILE")

    check "$CLUSTER_NAME reachable (${USER_NAME}@${HOST}:${PORT}, type: ${TYPE})" \
      ssh -p "$PORT" -o BatchMode=yes -o ConnectTimeout=5 \
          -o StrictHostKeyChecking=accept-new "${USER_NAME}@${HOST}" true
  done
else
  echo "  FAIL - cluster config not found: $CLUSTERS_FILE"
  STATUS=1
fi

# ── 6. Python tools (optional — needed for WP2 and extended tooling) ─
echo
echo "== Python tools (optional) =="
warn "python3 available"          command -v python3
warn "pip available"              command -v pip
warn "fabric installed (WP2)"    python3 -c "import fabric" 2>/dev/null
warn "ansible installed (WP2)"   command -v ansible-playbook
warn "jinja2 installed"          python3 -c "import jinja2" 2>/dev/null
warn "pyyaml installed"          python3 -c "import yaml" 2>/dev/null

if [[ -f "$REPO_ROOT/requirements-dev.txt" ]]; then
  echo
  echo "  TIP  - Install optional Python tools with:"
  echo "         pip install -r requirements-dev.txt"
fi

# ── Summary ─────────────────────────────────────────────────────────
echo
echo "=========================================="
if [[ $STATUS -eq 0 && $WARNINGS -eq 0 ]]; then
  echo "All checks passed."
elif [[ $STATUS -eq 0 ]]; then
  echo "All required checks passed ($WARNINGS warning(s) — see WARN lines above)."
else
  echo "Some required checks FAILED — fix them before proceeding."
  echo "See the README's Individual Setup section for detailed instructions."
fi
echo "=========================================="

exit $STATUS
