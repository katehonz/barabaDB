#!/bin/bash
set -e

# BaraDB Docker Build Script
# Изгражда Docker образа с подходящи тагове

IMAGE_NAME="${IMAGE_NAME:-baradb}"
VERSION="${VERSION:-latest}"
BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

echo "=== Building BaraDB Docker Image ==="
echo "Image: ${IMAGE_NAME}:${VERSION}"
echo "Commit: ${GIT_COMMIT}"
echo ""

docker build \
  --build-arg BUILD_DATE="${BUILD_DATE}" \
  --build-arg VCS_REF="${GIT_COMMIT}" \
  --tag "${IMAGE_NAME}:${VERSION}" \
  --tag "${IMAGE_NAME}:latest" \
  --file Dockerfile \
  .

echo ""
echo "=== Build Complete ==="
echo "Run with: docker run -d -p 9472:9472 -p 9470:9470 -p 9471:9471 ${IMAGE_NAME}:${VERSION}"
