#!/usr/bin/env bash
# Backup → wipe → restore → verify drill for BaraDB single-node GA.
# Usage: ./scripts/backup-restore-drill.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BIN="${BARADB_BIN:-./build/baradadb}"
BACKUP_BIN="${BARADB_BACKUP_BIN:-./build/backup}"
PORT="${DRILL_PORT:-19472}"
HTTP_PORT=$((PORT + 440))
WORKDIR="${DRILL_WORKDIR:-/tmp/baradb_backup_drill_$$}"
DATA_DIR="$WORKDIR/data"
ARCHIVE="$WORKDIR/drill_backup.tar.gz"
MARKER="drill-row-$$"

die() { echo "FAIL: $*" >&2; cleanup; exit 1; }
log() { echo "[drill] $*"; }

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  if [[ "${DRILL_KEEP:-1}" == "0" ]]; then
    rm -rf "$WORKDIR"
  fi
}
trap cleanup EXIT

[[ -x "$BIN" ]] || die "missing $BIN — build: nim c -o:build/baradadb src/baradadb.nim"
if [[ ! -x "$BACKUP_BIN" ]]; then
  log "building backup tool..."
  nim c -d:release -o:build/backup src/barabadb/core/backup.nim || die "cannot build backup tool"
  BACKUP_BIN=./build/backup
fi

rm -rf "$WORKDIR"
mkdir -p "$DATA_DIR"

start_server() {
  log "starting server port=$PORT data=$DATA_DIR"
  # every = fsync each WAL write so kill/backup cannot lose recent puts
  BARADB_PORT="$PORT" \
  BARADB_ADDRESS=127.0.0.1 \
  BARADB_DATA_DIR="$DATA_DIR" \
  BARADB_LOG_LEVEL=warn \
  BARADB_AUTH_ENABLED=false \
  BARADB_WAL_SYNC_MODE=every \
  "$BIN" >"$WORKDIR/server.log" 2>&1 &
  SERVER_PID=$!
  local i=0
  while (( i < 80 )); do
    if curl -sf "http://127.0.0.1:${HTTP_PORT}/health" >/dev/null 2>&1; then
      log "server ready pid=$SERVER_PID"
      return 0
    fi
    sleep 0.15
    i=$((i + 1))
  done
  tail -50 "$WORKDIR/server.log" >&2 || true
  die "server not healthy on :$HTTP_PORT"
}

stop_server() {
  if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    log "stopping pid=$SERVER_PID"
    kill -TERM "$SERVER_PID" 2>/dev/null || true
    local i=0
    while kill -0 "$SERVER_PID" 2>/dev/null && (( i < 50 )); do
      sleep 0.1
      i=$((i + 1))
    done
    if kill -0 "$SERVER_PID" 2>/dev/null; then
      kill -KILL "$SERVER_PID" 2>/dev/null || true
    fi
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  SERVER_PID=""
  sleep 0.3
}

http_query() {
  local sql="$1"
  local payload
  payload=$(python3 -c "import json,sys; print(json.dumps({'query': sys.argv[1]}))" "$sql")
  curl -sf -H 'Content-Type: application/json' -d "$payload" \
    "http://127.0.0.1:${HTTP_PORT}/query"
}

start_server

log "CREATE + INSERT marker"
http_query "CREATE TABLE drill_t (id INT PRIMARY KEY, name STRING)" >/dev/null || die "CREATE failed"
http_query "INSERT INTO drill_t (id, name) VALUES (1, '$MARKER')" >/dev/null || die "INSERT failed"
body=$(http_query "SELECT name FROM drill_t WHERE id = 1") || die "SELECT before backup failed"
echo "$body" | grep -q "$MARKER" || die "marker missing before backup: $body"
# allow WAL group/fsync to settle
sleep 0.5

stop_server

# Prefer multi-db layout used by the server registry
DB_ROOT="$DATA_DIR/databases"
[[ -d "$DB_ROOT" ]] || die "expected $DB_ROOT after server run"

log "backup from $DB_ROOT"
"$BACKUP_BIN" backup --all-databases --data-root="$DB_ROOT" \
  --output="$ARCHIVE" --force || die "backup failed"
# Sanity: archive must not be tiny empty shell only
asize=$(stat -c%s "$ARCHIVE" 2>/dev/null || stat -f%z "$ARCHIVE")
(( asize > 200 )) || die "backup archive suspiciously small ($asize bytes)"

log "wipe data"
rm -rf "$DATA_DIR"
mkdir -p "$DATA_DIR"

log "restore multi-db archive into $DB_ROOT"
mkdir -p "$DATA_DIR"
# Archive layout is databases/<name>/... ; --data-root is the databases/ parent leaf
"$BACKUP_BIN" restore --input="$ARCHIVE" --all-databases \
  --data-root="$DB_ROOT" --force || die "restore failed"

start_server

log "verify after restore"
body=$(http_query "SELECT name FROM drill_t WHERE id = 1") || die "SELECT after restore failed"
echo "$body" | grep -q "$MARKER" || die "marker missing after restore: $body"

log "PASS backup/restore drill OK marker=$MARKER archive=$ARCHIVE"
stop_server
trap - EXIT
[[ "${DRILL_KEEP:-1}" == "0" ]] && rm -rf "$WORKDIR"
exit 0
