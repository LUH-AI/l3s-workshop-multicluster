#!/usr/bin/env bash
# Prepares one local "cluster" node as a Docker container: sshd + docker CLI
# talking to the host's Docker socket. This lets the runner SSH into a
# container exactly like it would SSH into Cluster A, so the whole
# pipeline can be tested end-to-end before real cluster access exists.
#
# Usage: ./local-docker.sh <container-name> <local-ssh-port> <ssh-user> <public-key-file> [restrict-command]
#
# The container name, port and user must match the corresponding entry in
# config/clusters.json (see cluster-a-docker.sh for the values already
# wired up there).
#
# Security note: mounting /var/run/docker.sock into the container gives
# whoever can exec into it root-equivalent access to the host - this is the
# same risk called out for real cluster runners in README.md. For this local
# rig you can approximate the recommended `command=` restriction by passing
# a 5th argument, e.g.:
#   ./local-docker.sh cluster-a 2222 clustera ~/workshop-keys/runner_key.pub '/usr/local/bin/deploy-wrapper.sh'
set -euo pipefail

NAME="${1:?container name required}"
SSH_PORT="${2:?local SSH port required}"
SSH_USER="${3:?ssh user required (must match config/clusters.json)}"
PUBKEY_FILE="${4:?path to an SSH public key required}"
RESTRICT_COMMAND="${5:-}"

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

echo "==> ${NAME} listening on 127.0.0.1:${SSH_PORT}, user '${SSH_USER}'"
echo "    test with: ssh -p ${SSH_PORT} ${SSH_USER}@127.0.0.1"
