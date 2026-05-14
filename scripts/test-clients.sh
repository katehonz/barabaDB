#!/usr/bin/env bash
# BaraDB — Client Integration Test Runner
# Spins up the BaraDB server in Docker and runs all client test suites sequentially.
#
# Usage:
#   ./scripts/test-clients.sh

set -euo pipefail

COMPOSE="docker compose -f docker-compose.test.yml"

echo "=== Building BaraDB server image ==="
$COMPOSE build baradb

echo "=== Starting BaraDB server ==="
$COMPOSE up -d baradb

# Wait for server healthcheck
echo "=== Waiting for server to be healthy ==="
$COMPOSE ps baradb --format json 2>/dev/null | grep -q '"Health":"healthy"' || sleep 10

# Give a little extra time for the wire protocol port to be ready
sleep 3

run_test() {
  local service=$1
  echo ""
  echo "========================================"
  echo "=== Running $service tests ==="
  echo "========================================"
  if $COMPOSE run --rm "$service"; then
    echo "✅ $service tests PASSED"
  else
    echo "❌ $service tests FAILED"
    EXIT_CODE=1
  fi
}

EXIT_CODE=0

run_test test-python
run_test test-javascript
run_test test-nim
run_test test-rust

echo ""
echo "========================================"
if [ "$EXIT_CODE" -eq 0 ]; then
  echo "🎉 All client tests passed!"
else
  echo "⚠️  Some client tests failed."
fi
echo "========================================"

echo "=== Stopping BaraDB server ==="
$COMPOSE down -v

exit $EXIT_CODE
