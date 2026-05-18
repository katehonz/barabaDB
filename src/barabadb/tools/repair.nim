## BaraDB Repair Tool — Storage verification, cleanup, and WAL replay
##
## Usage:
##   nim c -r src/barabadb/tools/repair.nim --data-dir=./data/server
##
## Or via baradadb binary (if wired):
##   ./baradadb repair --data-dir=./data/server

import std/os
import std/strutils
import std/times
import std/parseopt
import ../storage/lsm
import ../storage/recovery

type
  SSTableRepairStatus* = enum
    srsOk
    srsCorrupt
    srsRebuilt
    srsRemoved

  SSTableRepairResult* = object
    path*: string
    status*: SSTableRepairStatus
    message*: string
    version*: int

  RepairReport* = object
    dataDir*: string
    sstablesChecked*: int
    sstablesOk*: int
    sstablesCorrupt*: int
    sstablesRemoved*: int
    walEntriesRecovered*: int
    walRedone*: int
    walUndone*: int
    errors*: seq[string]
    results*: seq[SSTableRepairResult]
    startedAt*: string
    completedAt*: string

const
  DEFAULT_DATA_DIR = "data/server"
  HelpText* = """
BaraDB Storage Repair — Verify SSTables, remove corruption, replay WAL
BaraDB Storage Repair — Verify SSTables, remove corruption, replay WAL
=======================================================================

USAGE:
  repair [options]

OPTIONS:
  -d, --data-dir <DIR>   Path to data directory (default: data/server)
  -f, --force            Remove corrupt SSTables without prompting
  -q, --quiet            Only print errors and summary
  --dry-run              Show what would be done without making changes
  -h, --help             Show this help message

DESCRIPTION:
  Scans all SSTable files in <DIR>/sstables/, verifies CRC checksums
  (v3) and magic/version (v1/v2). Corrupt files are moved to
  <DIR>/corrupt/ (or deleted with --force). After cleanup, WAL is
  replayed to recover any unflushed committed entries.

EXAMPLES:
  # Dry run — preview only
  repair --dry-run

  # Repair with default data dir
  repair

  # Repair specific directory, auto-remove corrupt files
  repair --data-dir=/var/lib/baradb --force
"""

proc formatBytes*(bytes: int64): string =
  const units = ["B", "KB", "MB", "GB", "TB"]
  if bytes < 0: return "0 B"
  var size = float64(bytes)
  var unitIndex = 0
  while size >= 1024.0 and unitIndex < units.high:
    size /= 1024.0
    unitIndex += 1
  result = formatFloat(size, ffDecimal, precision = 2) & " " & units[unitIndex]

proc runRepair*(dataDir: string, dryRun: bool = false, quiet: bool = false): RepairReport =
  ## Main repair routine.
  result.dataDir = dataDir
  result.startedAt = format(getTime(), "yyyy-MM-dd HH:mm:ss")
  result.sstablesChecked = 0
  result.sstablesOk = 0
  result.sstablesCorrupt = 0
  result.sstablesRemoved = 0
  result.walEntriesRecovered = 0
  result.walRedone = 0
  result.walUndone = 0

  let sstDir = dataDir / "sstables"
  let corruptDir = dataDir / "corrupt"

  if not dirExists(sstDir):
    result.errors.add("SSTables directory not found: " & sstDir)
    result.completedAt = format(getTime(), "yyyy-MM-dd HH:mm:ss")
    return

  if not dryRun:
    createDir(corruptDir)

  # ------------------------------------------------------------------
  # Phase 1: Scan and verify all SSTables
  # ------------------------------------------------------------------
  if not quiet:
    echo "Scanning SSTables in ", sstDir, " ..."

  for kind, path in walkDir(sstDir):
    if kind != pcFile or not path.endsWith(".sst"):
      continue

    inc result.sstablesChecked
    let (ok, msg) = verifySSTable(path)
    var res = SSTableRepairResult(path: path, message: msg)

    if ok:
      res.status = srsOk
      inc result.sstablesOk
      # Try to detect version from message
      if msg.contains("v3"): res.version = 3
      elif msg.contains("v2"): res.version = 2
      elif msg.contains("v1"): res.version = 1
    else:
      res.status = srsCorrupt
      inc result.sstablesCorrupt
      result.errors.add(msg)

      # Move to corrupt dir (or delete in dry-run we just report)
      if not dryRun:
        let fname = extractFilename(path)
        let dest = corruptDir / fname
        try:
          moveFile(path, dest)
          res.status = srsRemoved
          inc result.sstablesRemoved
          res.message = msg & " → moved to " & dest
        except IOError as e:
          res.message = msg & " → failed to move: " & e.msg
      else:
        res.message = msg & " → would move to " & corruptDir

    result.results.add(res)

  if not quiet:
    echo "SSTable scan complete: ", result.sstablesOk, " OK, ", result.sstablesCorrupt, " corrupt"

  # ------------------------------------------------------------------
  # Phase 2: WAL replay to recover unflushed data
  # ------------------------------------------------------------------
  let walPath = dataDir / "wal" / "wal.log"
  if fileExists(walPath):
    if not quiet:
      echo "Replaying WAL: ", walPath, " ..."

    if dryRun:
      # Just count entries without applying
      var rec = newCrashRecovery(dataDir / "wal", dataDir)
      let analysis = rec.analyze()
      result.walEntriesRecovered = analysis.totalEntries
      result.walRedone = analysis.redone
      result.walUndone = analysis.undone
      if not quiet:
        echo "WAL dry-run: ", analysis.totalEntries, " entries (", analysis.redone, " redo, ", analysis.undone, " undo)"
    else:
      # Create a temporary LSMTree just for recovery, then flush
      var tmpDb = newLSMTree(dataDir, DefaultMemTableSize)
      var rec = newCrashRecovery(dataDir / "wal", dataDir)
      let recoveryResult = rec.recover(tmpDb)
      result.walEntriesRecovered = recoveryResult.totalEntries
      result.walRedone = recoveryResult.redone
      result.walUndone = recoveryResult.undone

      # Flush recovered data to SSTables
      if recoveryResult.redone > 0:
        tmpDb.flush()
        if not quiet:
          echo "WAL replay complete: ", recoveryResult.redone, " entries redone, ", recoveryResult.undone, " undone"
      tmpDb.close()
  else:
    if not quiet:
      echo "No WAL found at ", walPath

  result.completedAt = format(getTime(), "yyyy-MM-dd HH:mm:ss")

proc printReport*(report: RepairReport, quiet: bool = false) =
  if quiet and report.errors.len == 0 and report.sstablesCorrupt == 0:
    echo "Repair complete. No issues found."
    return

  echo ""
  echo "═══════════════════════════════════════════════════════════════════════"
  echo "                    BaraDB Repair Report"
  echo "═══════════════════════════════════════════════════════════════════════"
  echo "Data directory:  ", report.dataDir
  echo "Started:         ", report.startedAt
  echo "Completed:       ", report.completedAt
  echo ""
  echo "SSTables:"
  echo "  Checked:       ", report.sstablesChecked
  echo "  OK:            ", report.sstablesOk
  echo "  Corrupt:       ", report.sstablesCorrupt
  echo "  Removed:       ", report.sstablesRemoved
  echo ""
  echo "WAL Recovery:"
  echo "  Entries:       ", report.walEntriesRecovered
  echo "  Redone:        ", report.walRedone
  echo "  Undone:        ", report.walUndone
  echo ""

  if report.errors.len > 0:
    echo "Errors (", report.errors.len, "):"
    for e in report.errors:
      echo "  • ", e
    echo ""

  if report.results.len > 0:
    echo "Details:"
    for r in report.results:
      let icon = case r.status
        of srsOk: "✓"
        of srsCorrupt: "✗"
        of srsRebuilt: "↻"
        of srsRemoved: "→"
      echo "  ", icon, " ", extractFilename(r.path), " — ", r.message
    echo ""

  if report.sstablesCorrupt == 0 and report.errors.len == 0:
    echo "Result: ALL OK — storage is healthy."
  else:
    echo "Result: ", report.sstablesCorrupt, " corrupt SSTable(s) handled."
  echo "═══════════════════════════════════════════════════════════════════════"

# =============================================================================
# CLI Entry Point
# =============================================================================
when isMainModule:
  var
    dataDir = DEFAULT_DATA_DIR
    dryRun = false
    force = false
    quiet = false

  for kind, key, val in getopt():
    case kind
    of cmdArgument:
      discard  # no positional args
    of cmdLongOption, cmdShortOption:
      case key
      of "data-dir", "d": dataDir = val
      of "dry-run": dryRun = true
      of "force", "f": force = true
      of "quiet", "q": quiet = true
      of "help", "h":
        echo HelpText
        quit(0)
      else: discard
    of cmdEnd: discard

  if dryRun and not quiet:
    echo "DRY-RUN mode: no changes will be made."

  let report = runRepair(dataDir, dryRun, quiet)
  printReport(report, quiet)

  if report.sstablesCorrupt > 0:
    quit(1)  # exit with error if corruption was found
  else:
    quit(0)
