#!/bin/sh
set -eu

# Ormin + BaraDB Dev Entrypoint
# Handles dependency installation and optional example compilation.

DEPS_FLAG="/workspace/.deps-installed"

# Install dependencies once
if [ ! -f "$DEPS_FLAG" ]; then
    echo "[ormin-dev] Installing BaraDB client..."
    cd /workspace/baradb
    nimble install -y

    echo "[ormin-dev] Installing Ormin dependencies..."
    cd /workspace/ormin
    nimble install -y

    touch "$DEPS_FLAG"
    echo "[ormin-dev] Dependencies ready."
fi

# If no arguments, drop to shell
if [ $# -eq 0 ]; then
    exec bash
fi

# Otherwise run the provided command
exec "$@"
