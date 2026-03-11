#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Update the serahrchat/latest.json manifest with the current image digest.
# Run after pushing a new image to ghcr.io:
#   ./scripts/update-manifest.sh 0.2.0 feature "Bug fixes and improvements"
# =============================================================================

VERSION="${1:?Usage: $0 <version> <type> <changelog>}"
TYPE="${2:-feature}"
CHANGELOG="${3:-}"

IMAGE="ghcr.io/reeb78/serahrchat:${VERSION}"
MANIFEST="serahrchat/latest.json"

echo "Pulling image to read digest: ${IMAGE}..."
docker pull "$IMAGE" >/dev/null

DIGEST=$(docker inspect "$IMAGE" --format '{{index .RepoDigests 0}}' | grep -o 'sha256:.*')

if [ -z "$DIGEST" ]; then
  echo "ERROR: Could not determine image digest."
  exit 1
fi

echo "Image digest: ${DIGEST}"

cat > "$MANIFEST" <<EOF
{
  "latest_version": "${VERSION}",
  "update_type": "${TYPE}",
  "changelog": "${CHANGELOG}",
  "update_url": "https://github.com/Reeb78/SerahrChat/releases/tag/v${VERSION}",
  "image_digest": "${DIGEST}"
}
EOF

echo "Manifest updated: ${MANIFEST}"
echo "Don't forget to commit and push to update.serahr.de!"
