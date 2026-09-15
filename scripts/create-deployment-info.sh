#!/usr/bin/env bash
# Usage: ./create-deployment-info.sh <image-tag> [output-file]
#
# Writes a small JSON file describing what was just built/deployed:
# commit, image_tag, digest (optional, via IMAGE_DIGEST env var) and a UTC
# timestamp. Used by Group 4 to compare "expected" (this file / current
# commit) against "actual" (verify.sh's view of each cluster).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() { echo "Usage: $0 <image-tag> [output-file]" >&2; exit 1; }
[[ $# -ge 1 ]] || usage

IMAGE_TAG="$1"
OUTPUT_FILE="${2:-$REPO_ROOT/deployment-info.json}"

COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD)"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [[ -n "${IMAGE_DIGEST:-}" ]]; then
  DIGEST_JSON="\"${IMAGE_DIGEST}\""
else
  DIGEST_JSON="null"
fi

cat > "$OUTPUT_FILE" <<EOF
{
  "commit": "${COMMIT}",
  "image_tag": "${IMAGE_TAG}",
  "digest": ${DIGEST_JSON},
  "timestamp": "${TIMESTAMP}"
}
EOF

echo "Wrote ${OUTPUT_FILE}:"
cat "$OUTPUT_FILE"
