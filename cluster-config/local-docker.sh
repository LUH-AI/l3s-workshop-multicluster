#!/usr/bin/env bash
# Prepares one local "cluster" node as a Docker container: sshd + docker CLI
# talking to the host's Docker socket. This lets the runner SSH into a
# container exactly like it would SSH into Cluster A/B, so the whole
# pipeline can be tested end-to-end before real cluster access exists.
#
# Usage: ./local-docker.sh <container-name> <local-ssh-port> <public-key-file> [restrict-command]
#
# Security note: mounting /var/run/docker.sock into the container gives
# whoever can exec into it root-equivalent access to the host - this is the
# same risk called out for real cluster runners in README.md. For this local
# rig you can approximate the recommended `command=` restriction by passing
# a 4th argument, e.g.:
#   ./local-docker.sh cluster-a 2201 ~/.ssh/id_cluster_a.pub '/usr/local/bin/deploy-wrapper.sh'
set -euo pipefail

NAME="${1:?container name required}"
SSH_PORT="${2:?local SSH port required}"
PUBKEY_FILE="${3:?path to an SSH public key required}"
RESTRICT_COMMAND="${4:-}"

[[ -f "$PUBKEY_FILE" ]] || { echo "ERROR: public key not found: $PUBKEY_FILE" >&2; exit 1; }

PUBKEY_CONTENT="$(cat "$PUBKEY_FILE")"
AUTHORIZED_KEYS_LINE="$PUBKEY_CONTENT"
if [[ -n "$RESTRICT_COMMAND" ]]; then
  AUTHORIZED_KEYS_LINE="command=\"$RESTRICT_COMMAND\",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty $PUBKEY_CONTENT"
fi

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

cat > "$BUILD_DIR/Dockerfile" <<'DOCKERFILE'
FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends openssh-server docker.io \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /var/run/sshd \
    && useradd -m -s /bin/bash deploy \
    && usermod -aG docker deploy \
    && mkdir -p /home/deploy/.ssh \
    && chmod 700 /home/deploy/.ssh
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

docker cp "$BUILD_DIR/authorized_keys" "${NAME}:/home/deploy/.ssh/authorized_keys"
docker exec "$NAME" chown -R deploy:deploy /home/deploy/.ssh
docker exec "$NAME" chmod 600 /home/deploy/.ssh/authorized_keys

echo "==> ${NAME} listening on 127.0.0.1:${SSH_PORT}, user 'deploy'"
echo "    test with: ssh -p ${SSH_PORT} deploy@127.0.0.1"
