#!/usr/bin/env bash
# Thin wrapper so the documented interface `./deploy.sh <cluster-name>
# <image-tag>` works from the repo root. Actual logic lives in
# scripts/deploy.sh (grouped with the other operational scripts).
set -euo pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/deploy.sh" "$@"
