## BaraDB SSTable Migration Tool — rewrite legacy v1/v2 SSTables to v3
##
## Usage:
##   nim c -r src/barabadb/tools/migrate.nim --data-dir=./data/server
##
## Or via baradadb binary:
##   ./baradadb migrate --data-dir=./data/server

import std/os
import ../storage/lsm

type
  MigrateResult* = object
    scanned*: int
    migrated*: int
    skipped*: int
    errors*: seq[string]

const
  DEFAULT_DATA_DIR = "data/server"
  HelpText* = """
BaraDB SSTable Migration — Upgrade legacy SSTables to current format
=====================================================================

USAGE:
  migrate [options]

OPTIONS:
  -d, --data-dir <DIR>   Path to data directory (default: data/server)
  --dry-run              Show what would be migrated without making changes
  -h, --help             Show this help message

DESCRIPTION:
  Scans all SSTables in <DIR>/sstables/ and rewrites any v1 or v2 files
  to the current v3 format (with CRC footer). The original files are
  replaced atomically. This is an offline operation — the server should
  not be running during migration.

EXAMPLES:
  # Preview only
  migrate --dry-run

  # Migrate default data directory
  migrate

  # Migrate specific directory
  migrate --data-dir=/var/lib/baradb
"""

proc runMigration*(dataDir: string, dryRun: bool = false): MigrateResult =
  result.scanned = 0
  result.migrated = 0
  result.skipped = 0
  result.errors = @[]

  let legacy = listLegacySSTables(dataDir)
  result.scanned = legacy.len

  if legacy.len == 0:
    echo "No legacy SSTables found. All files are already at version ", SSTableVersion, "."
    return

  echo "Found ", legacy.len, " legacy SSTable(s) to migrate:"
  for (path, version) in legacy:
    echo "  ", extractFilename(path), " (v", version, ")"

  if dryRun:
    echo "DRY-RUN: No changes made."
    return

  for (path, version) in legacy:
    echo "Migrating: ", extractFilename(path), " (v", version, " → v", SSTableVersion, ")"
    if migrateSSTable(path):
      inc result.migrated
      echo "  ✓ Done"
    else:
      result.errors.add("Failed: " & path)
      echo "  ✗ Failed"

  # After migration, rewrite MANIFEST so it references current versions
  if result.migrated > 0:
    try:
      var db = newLSMTree(dataDir)
      writeManifest(db)
      db.close()
      echo "MANIFEST updated."
    except CatchableError as e:
      result.errors.add("MANIFEST update failed: " & e.msg)

# =============================================================================
# CLI Entry Point
# =============================================================================
when isMainModule:
  var
    dataDir = DEFAULT_DATA_DIR
    dryRun = false

  for kind, key, val in getopt():
    case kind
    of cmdArgument:
      discard
    of cmdLongOption, cmdShortOption:
      case key
      of "data-dir", "d": dataDir = val
      of "dry-run": dryRun = true
      of "help", "h":
        echo HelpText
        quit(0)
      else: discard
    of cmdEnd: discard

  if dryRun:
    echo "DRY-RUN mode: no changes will be made."

  let result = runMigration(dataDir, dryRun)
  echo ""
  echo "Migration complete:"
  echo "  Scanned:  ", result.scanned
  echo "  Migrated: ", result.migrated
  echo "  Errors:   ", result.errors.len
  if result.errors.len > 0:
    for e in result.errors:
      echo "  ! ", e
    quit(1)
  else:
    quit(0)
