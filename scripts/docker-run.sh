#!/bin/bash
set -e

# BaraDB Docker Run Script
# Улеснява стартирането на BaraDB контейнер с правилни настройки

IMAGE_NAME="${IMAGE_NAME:-baradb:latest}"
CONTAINER_NAME="${CONTAINER_NAME:-baradb}"
DATA_DIR="${DATA_DIR:-$(pwd)/data/docker}"

echo "=== Starting BaraDB Container ==="
echo "Image: ${IMAGE_NAME}"
echo "Container: ${CONTAINER_NAME}"
echo "Data directory: ${DATA_DIR}"
echo ""

# Създаваме локална data директория ако не съществува
mkdir -p "${DATA_DIR}"

docker run -d \
  --name "${CONTAINER_NAME}" \
  --hostname baradb \
  --restart unless-stopped \
  -p 9472:9472 \
  -p 9912:9912 \
  -p 9913:9913 \
  -v "${DATA_DIR}:/data" \
  -e BARADB_ADDRESS=0.0.0.0 \
  -e BARADB_PORT=9472 \
  -e BARADB_DATA_DIR=/data \
  -e BARADB_LOG_LEVEL=info \
  --health-cmd "wget -q --spider http://localhost:9470/health || exit 1" \
  --health-interval 15s \
  --health-timeout 5s \
  --health-retries 3 \
  "${IMAGE_NAME}"

echo ""
echo "=== Container Started ==="
echo "Logs: docker logs -f ${CONTAINER_NAME}"
echo "Stop: docker stop ${CONTAINER_NAME}"
echo ""
echo "API Endpoints:"
echo "  Binary Protocol: localhost:9472"
echo "  HTTP/REST:       http://localhost:9912"
echo "  WebSocket:       ws://localhost:9913"
