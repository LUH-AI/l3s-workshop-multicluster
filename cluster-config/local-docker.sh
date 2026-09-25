#!/usr/bin/env bash
# Prepares one local "cluster" node as a Docker container: sshd + docker CLI
# talking to the host's Docker socket. This lets the runner SSH into a
# container exactly like it would SSH into a real cluster, so the whole
# pipeline can be tested end-to-end before real cluster access exists.
#
# Usage: ./local-docker.sh <cluster-name> <public-key-file> [restrict-command]
#
# Generic, like the scripts in scripts/: port and user come from the
# cluster's entry in config/clusters.json (which must be "type": "docker"
# on "host": "localhost"); the container is named after the cluster.
#
# Security note: mounting /var/run/docker.sock into the container gives
# whoever can exec into it root-equivalent access to the host - this is the
# same risk called out for real cluster runners in README.md. For this local
# rig you can approximate the recommended `command=` restriction by passing
# a 3rd argument, e.g.:
#   ./local-docker.sh cluster-a ~/workshop-keys/runner_key.pub '/usr/local/bin/deploy-wrapper.sh'
set -euo pipefail

NAME="${1:?cluster name required (an entry in config/clusters.json)}"
PUBKEY_FILE="${2:?path to an SSH public key required}"
RESTRICT_COMMAND="${3:-}"
CONFIG_FILE="$(dirname "$0")/../config/clusters.json"

command -v jq &> /dev/null || { echo "ERROR: jq is not installed (macOS: brew install jq, Debian/Ubuntu: sudo apt install jq)" >&2; exit 1; }

if ! jq -e --arg c "$NAME" 'has($c)' "$CONFIG_FILE" &> /dev/null; then
  echo "ERROR: cluster '$NAME' not found in $CONFIG_FILE" >&2
  exit 1
fi
TYPE=$(jq -r --arg c "$NAME" '.[$c].type' "$CONFIG_FILE")
HOST=$(jq -r --arg c "$NAME" '.[$c].host' "$CONFIG_FILE")
SSH_PORT=$(jq -r --arg c "$NAME" '.[$c].port // 22' "$CONFIG_FILE")
SSH_USER=$(jq -r --arg c "$NAME" '.[$c].user' "$CONFIG_FILE")
if [[ "$TYPE" != "docker" || ( "$HOST" != "localhost" && "$HOST" != "127.0.0.1" ) ]]; then
  echo "ERROR: '$NAME' is not a local simulator (needs \"type\": \"docker\" and host localhost, has type '$TYPE', host '$HOST')" >&2
  exit 1
fi

[[ -f "$PUBKEY_FILE" ]] || { echo "ERROR: public key not found: $PUBKEY_FILE" >&2; exit 1; }

PUBKEY_CONTENT="$(cat "$PUBKEY_FILE")"
AUTHORIZED_KEYS_LINE="$PUBKEY_CONTENT"
if [[ -n "$RESTRICT_COMMAND" ]]; then
  AUTHORIZED_KEYS_LINE="command=\"$RESTRICT_COMMAND\",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty $PUBKEY_CONTENT"
fi

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

cat > "$BUILD_DIR/Dockerfile" <<DOCKERFILE
FROM debian:bookworm-slim
RUN apt-get update \\
    && apt-get install -y --no-install-recommends openssh-server docker.io rsync \\
    && rm -rf /var/lib/apt/lists/* \\
    && mkdir -p /var/run/sshd \\
    && useradd -m -s /bin/bash ${SSH_USER} \\
    && usermod -aG docker ${SSH_USER} \\
    && mkdir -p /home/${SSH_USER}/.ssh \\
    && chmod 700 /home/${SSH_USER}/.ssh
EXPOSE 22
CMD ["/usr/sbin/sshd", "-D"]
DOCKERFILE

echo "$AUTHORIZED_KEYS_LINE" > "$BUILD_DIR/authorized_keys"

docker build -t "workshop/${NAME}:local" "$BUILD_DIR"

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d \
  --name "$NAME" \
  -p "${SSH_PORT}:22" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  "workshop/${NAME}:local"

docker cp "$BUILD_DIR/authorized_keys" "${NAME}:/home/${SSH_USER}/.ssh/authorized_keys"
docker exec "$NAME" chown -R "${SSH_USER}:${SSH_USER}" "/home/${SSH_USER}/.ssh"
docker exec "$NAME" chmod 600 "/home/${SSH_USER}/.ssh/authorized_keys"

# Known pitfall: the 'docker' group created inside the image rarely has the
# same GID as the group that owns the host's bind-mounted docker.sock, so
# group membership alone doesn't guarantee access. Fix it up against the
# GID actually seen at runtime instead of guessing at build time.
SOCK_GID="$(docker exec "$NAME" stat -c '%g' /var/run/docker.sock)"
EXISTING_GROUP="$(docker exec "$NAME" getent group "$SOCK_GID" | cut -d: -f1 || true)"
if [[ -n "$EXISTING_GROUP" ]]; then
  docker exec "$NAME" usermod -aG "$EXISTING_GROUP" "$SSH_USER"
else
  docker exec "$NAME" groupadd -g "$SOCK_GID" dockerhost
  docker exec "$NAME" usermod -aG dockerhost "$SSH_USER"
fi

# Every rebuild generates fresh sshd host keys, so any known_hosts entry
# from a previous container on this port is now stale and would make the
# next ssh/rsync fail with "REMOTE HOST IDENTIFICATION HAS CHANGED".
ssh-keygen -R "[localhost]:${SSH_PORT}" >/dev/null 2>&1 || true
ssh-keygen -R "[127.0.0.1]:${SSH_PORT}" >/dev/null 2>&1 || true

echo "==> ${NAME} listening on 127.0.0.1:${SSH_PORT}, user '${SSH_USER}'"
echo "    test with: ssh -p ${SSH_PORT} ${SSH_USER}@127.0.0.1"
