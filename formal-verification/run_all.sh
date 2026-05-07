#!/usr/bin/env bash
# BaraDB Formal Verification Suite — Run All TLC Model Checks
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JAR="$SCRIPT_DIR/tla2tools.jar"

if [ ! -f "$JAR" ]; then
  echo "ERROR: tla2tools.jar not found at $JAR"
  echo "Download from https://github.com/tlaplus/tlaplus/releases"
  exit 1
fi

run_tlc() {
  local spec="$1"
  local cfg="$2"
  echo "=============================================="
  echo " TLC: $spec (cfg: $cfg)"
  echo "=============================================="
  java -cp "$JAR" tlc2.TLC -config "$cfg" "$spec" 2>&1 | tail -5
  echo ""
}

echo "=============================================="
echo " BaraDB Formal Verification Suite v1.0.0"
echo " Running TLC model checker on all specs"
echo "=============================================="
echo ""

run_tlc "$SCRIPT_DIR/raft.tla"         "$SCRIPT_DIR/models/raft.cfg"
run_tlc "$SCRIPT_DIR/twopc.tla"        "$SCRIPT_DIR/models/twopc.cfg"
run_tlc "$SCRIPT_DIR/mvcc.tla"         "$SCRIPT_DIR/models/mvcc.cfg"
run_tlc "$SCRIPT_DIR/replication.tla"  "$SCRIPT_DIR/models/replication.cfg"
run_tlc "$SCRIPT_DIR/gossip.tla"       "$SCRIPT_DIR/models/gossip.cfg"
run_tlc "$SCRIPT_DIR/deadlock.tla"     "$SCRIPT_DIR/models/deadlock.cfg"
run_tlc "$SCRIPT_DIR/sharding.tla"     "$SCRIPT_DIR/models/sharding.cfg"

echo "All verification runs completed."
