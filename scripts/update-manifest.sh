#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Update and SIGN the serahrchat/latest.json manifest.
# Run after pushing a new image to ghcr.io:
#   ./scripts/update-manifest.sh 0.2.0 feature "Bug fixes and improvements"
#
# Requires: openssl, docker, jq (optional but recommended)
# The signing key must be at keys/manifest-signing.pem
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
SIGNING_KEY="${REPO_DIR}/keys/manifest-signing.pem"

VERSION="${1:?Usage: $0 <version> <type> <changelog>}"
TYPE="${2:-feature}"
CHANGELOG="${3:-}"

IMAGE="ghcr.io/reeb78/serahrchat:${VERSION}"
MANIFEST="${REPO_DIR}/serahrchat/latest.json"

# Check signing key exists
if [ ! -f "$SIGNING_KEY" ]; then
  echo "ERROR: Signing key not found at ${SIGNING_KEY}"
  echo "Generate with: openssl genpkey -algorithm Ed25519 -out ${SIGNING_KEY}"
  exit 1
fi

echo "Pulling image to read digest: ${IMAGE}..."
docker pull "$IMAGE" >/dev/null

DIGEST=$(docker inspect "$IMAGE" --format '{{index .RepoDigests 0}}' | grep -o 'sha256:.*')

if [ -z "$DIGEST" ]; then
  echo "ERROR: Could not determine image digest."
  exit 1
fi

echo "Image digest: ${DIGEST}"

# Build canonical JSON payload (sorted keys, no whitespace) for signing
# This MUST match the canonical_payload() function in verify.py
CANONICAL=$(python3 -c "
import json, sys
data = {
    'changelog': sys.argv[1],
    'image_digest': sys.argv[2],
    'latest_version': sys.argv[3],
    'update_type': sys.argv[4],
    'update_url': sys.argv[5],
}
print(json.dumps(data, sort_keys=True, separators=(',', ':')), end='')
" "$CHANGELOG" "$DIGEST" "$VERSION" "$TYPE" "https://github.com/Reeb78/SerahrChat/releases/tag/v${VERSION}")

echo "Canonical payload: ${CANONICAL}"

# Sign with Ed25519
SIGNATURE=$(echo -n "$CANONICAL" | openssl pkeyutl -sign -inkey "$SIGNING_KEY" | base64 -w 0)

if [ -z "$SIGNATURE" ]; then
  echo "ERROR: Signing failed."
  exit 1
fi

echo "Signature: ${SIGNATURE:0:20}..."

# Verify signature before writing (catch signing errors early)
PUB_KEY="${REPO_DIR}/keys/manifest-signing.pub"
if [ -f "$PUB_KEY" ]; then
  echo -n "$CANONICAL" > /tmp/_manifest_verify.bin
  echo "$SIGNATURE" | base64 -d > /tmp/_manifest_verify.sig
  if openssl pkeyutl -verify -pubin -inkey "$PUB_KEY" -in /tmp/_manifest_verify.bin -sigfile /tmp/_manifest_verify.sig 2>/dev/null; then
    echo "Signature verified OK"
  else
    echo "ERROR: Signature verification FAILED — aborting!"
    rm -f /tmp/_manifest_verify.bin /tmp/_manifest_verify.sig
    exit 1
  fi
  rm -f /tmp/_manifest_verify.bin /tmp/_manifest_verify.sig
fi

# Write signed manifest (human-readable format)
cat > "$MANIFEST" <<EOF
{
  "latest_version": "${VERSION}",
  "update_type": "${TYPE}",
  "changelog": "${CHANGELOG}",
  "update_url": "https://github.com/Reeb78/SerahrChat/releases/tag/v${VERSION}",
  "image_digest": "${DIGEST}",
  "signature": "${SIGNATURE}"
}
EOF

echo "Signed manifest written: ${MANIFEST}"
echo "Don't forget to commit and push to update.serahr.de!"
