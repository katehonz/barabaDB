#!/bin/sh
set -e

# BaraDB Docker Entrypoint
# Създава нужните директории и стартира сървъра с правилни настройки

BARADB_DATA_DIR="${BARADB_DATA_DIR:-/data}"
BARADB_LOG_LEVEL="${BARADB_LOG_LEVEL:-info}"
BARADB_PORT="${BARADB_PORT:-9472}"

# Създаваме data директорията ако не съществува
if [ ! -d "$BARADB_DATA_DIR" ]; then
    echo "Creating data directory: $BARADB_DATA_DIR"
    mkdir -p "$BARADB_DATA_DIR"
fi

# Създаваме поддиректории за WAL и SSTables ако не съществуват
mkdir -p "$BARADB_DATA_DIR/server"
mkdir -p "$BARADB_DATA_DIR/server/wal"
mkdir -p "$BARADB_DATA_DIR/server/sstables"

# Създаваме symlink от /app/data към /data ако липсва
if [ ! -L "/app/data" ]; then
    ln -s "$BARADB_DATA_DIR" /app/data
fi

# Правим директорията собственост на baradb потребителя ако сме root
if [ "$(id -u)" = "0" ]; then
    chown -R baradb:baradb "$BARADB_DATA_DIR"
    # Стартираме като baradb потребител (gosu за Debian, su-exec за Alpine)
    if command -v gosu >/dev/null 2>&1; then
        exec gosu baradb "$@"
    elif command -v su-exec >/dev/null 2>&1; then
        exec su-exec baradb "$@"
    else
        echo "Warning: neither gosu nor su-exec found, running as root"
        exec "$@"
    fi
else
    exec "$@"
fi
