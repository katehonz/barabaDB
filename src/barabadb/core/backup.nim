## BaraDB Backup & Restore — tar.gz snapshots with retention, verification & CLI
##
## Commands:
##   backup   Create a snapshot of the data directory
##   restore  Restore data directory from a snapshot
##   list     List available snapshots with size & timestamp
##   verify   Check archive integrity without extracting
##   cleanup  Remove old snapshots keeping N most recent
##   history  Show restore operation log
##   help     Show detailed usage information
##
## Options:
##   --data-dir, -d <DIR>   Data directory to backup (default: data/server)
##   --output,   -o <FILE>  Output archive path for backup
##   --input,    -i <FILE>  Input archive path for restore/verify
##   --keep,     -k <N>     Number of snapshots to retain (default: 5)
##   --exclude,  -e <PAT>   Exclude pattern (can be used multiple times)
##   --level,    -l <0-9>   Compression level for gzip (default: 6)
##   --dry-run               Show what would be done without doing it
##   --force,    -f         Skip confirmation prompts
##   --verbose,  -v         Enable verbose output

import std/os
import std/osproc
import std/strutils
import std/times
import std/algorithm
import std/parseopt

type
  Backup* = object
    path*: string
    timestamp*: int64
    size*: int64
    compressed*: bool

const
  DEFAULT_DATA_DIR = "data/server"
  DEFAULT_KEEP_COUNT = 5
  DEFAULT_COMPRESSION = 6
  HISTORY_FILE = "backup_history.log"
  HELP_TEXT = """
BaraDB Backup Manager — Archive and restore your database safely
================================================================

USAGE:
  backup <command> [options]

COMMANDS:
  backup   Create a compressed tar.gz snapshot of the data directory.
           By default archives are named backup_<unixtimestamp>.tar.gz.

  restore  Replace the current data directory with contents from a snapshot.
           WARNING: This DESTROYS existing data. Use with care.
           Automatically verifies archive integrity before extracting.

  list     Show all snapshots found next to the data directory.
           Displays size, timestamp and compression ratio if known.

  verify   Test archive integrity without extracting files.
           Detects corrupted or incomplete snapshots early.

  cleanup  Delete old snapshots, keeping only the N most recent ones.
           Default retention is 5 snapshots.

  history  Show log of all restore operations performed on this system.

  help     Show this help message.

OPTIONS:
  -d, --data-dir <DIR>   Path to data directory (default: data/server)
  -o, --output   <FILE>  Destination path for new backup archive
  -i, --input    <FILE>  Source archive for restore or verify
  -k, --keep     <N>     Retention count for cleanup (default: 5)
  -e, --exclude  <PAT>   Exclude files matching pattern (repeatable)
  -l, --level    <0-9>   Gzip compression level (default: 6, max: 9)
      --dry-run          Show what restore would do without changing anything
  -f, --force            Skip confirmation prompts (use with caution!)
  -v, --verbose          Print detailed progress information

EXAMPLES:
  # Quick backup with default settings
  backup backup

  # Backup with maximum compression and custom name
  backup backup --output=prod_backup_$(date +%F).tar.gz --level=9

  # Restore from a specific snapshot
  backup restore --input=backup_1715011200.tar.gz

  # Dry-run restore — preview what will happen
  backup restore --input=backup.tar.gz --dry-run

  # Force restore without confirmation (automation/scripts)
  backup restore --input=backup.tar.gz --force

  # List all snapshots
  backup list

  # Verify archive before restoring
  backup verify --input=backup_1715011200.tar.gz

  # Keep only last 3 snapshots
  backup cleanup --keep=3

  # Exclude WAL files from backup
  backup backup --exclude="*.log" --exclude="wal/*"

EXIT CODES:
  0  Success
  1  General error (invalid arguments, missing files, tar failure, etc.)
"""

proc formatBytes*(bytes: int64): string =
  ## Human readable byte size
  const units = ["B", "KB", "MB", "GB", "TB"]
  if bytes < 0: return "0 B"
  var size = float64(bytes)
  var unitIndex = 0
  while size >= 1024.0 and unitIndex < units.high:
    size /= 1024.0
    unitIndex += 1
  result = formatFloat(size, ffDecimal, precision = 2) & " " & units[unitIndex]

proc formatTimestamp*(ts: int64): string =
  ## Format unix timestamp to human readable string
  try:
    let dt = fromUnix(ts)
    result = format(dt, "yyyy-MM-dd HH:mm:ss")
  except:
    result = $ts

proc parseBackupFilename*(filename: string): int64 =
  ## Try to extract timestamp from backup_1234567890.tar.gz
  try:
    let name = extractFilename(filename)
    if name.startsWith("backup_"):
      let tsStr = name[7..^8]  # skip "backup_" and ".tar.gz"
      result = parseBiggestInt(tsStr)
    else:
      result = 0
  except:
    result = 0

proc getArchiveSize*(input: string): int64 =
  ## Return uncompressed size estimate from tar archive
  let cmd = "tar -tzf " & quoteShell(input) & " | wc -l"
  let (outStr, exitCode) = execCmdEx(cmd)
  if exitCode == 0:
    try:
      result = parseBiggestInt(strip(outStr))
    except:
      result = 0
  else:
    result = 0

proc getFreeSpace*(path: string): int64 =
  ## Return free disk space in bytes for the filesystem containing path
  let cmd = "df -B1 " & quoteShell(path) & " | tail -1 | awk '{print $4}'"
  let (outStr, exitCode) = execCmdEx(cmd)
  if exitCode == 0:
    try:
      result = parseBiggestInt(strip(outStr))
    except:
      result = -1
  else:
    result = -1

proc logRestore*(archive: string, dataDir: string, success: bool, dryRun: bool = false) =
  ## Append restore operation to history log
  let logPath = getCurrentDir() / HISTORY_FILE
  let status = if dryRun: "DRY-RUN" elif success: "SUCCESS" else: "FAILED"
  let entry = "[" & format(getTime(), "yyyy-MM-dd HH:mm:ss") & "] " &
              status & " restore from " & absolutePath(archive) &
              " to " & absolutePath(dataDir) & "\n"
  try:
    let f = open(logPath, fmAppend)
    f.write(entry)
    f.close()
  except:
    discard  # Silently fail if log cannot be written

proc readHistory*(): seq[string] =
  ## Read restore history log
  result = @[]
  let logPath = getCurrentDir() / HISTORY_FILE
  if not fileExists(logPath):
    return
  try:
    let content = readFile(logPath)
    for line in splitLines(content):
      if line.len > 0:
        result.add(line)
  except:
    discard

proc backupDataDir*(dataDir: string, output: string, excludes: seq[string] = @[], compression: int = DEFAULT_COMPRESSION, verbose: bool = false): bool =
  ## Create a tar.gz backup of the data directory
  if not dirExists(dataDir):
    echo "ERROR: Data directory not found: ", dataDir
    return false

  if fileExists(output):
    echo "WARNING: Overwriting existing file: ", output

  let parent = parentDir(dataDir)
  let name = lastPathPart(dataDir)
  var excludeArgs = ""
  for pattern in excludes:
    excludeArgs.add(" --exclude=" & quoteShell(pattern))

  let tarCmd = "tar -cf -" & excludeArgs & " -C " & quoteShell(parent) & " " & quoteShell(name)
  let gzipCmd = "gzip -" & $compression
  let cmd = tarCmd & " | " & gzipCmd & " > " & quoteShell(output)

  if verbose:
    echo "Running: ", cmd
    echo "Source:  ", dataDir
    echo "Target:  ", output

  let (outputStr, exitCode) = execCmdEx("bash -c " & quoteShell(cmd))
  if exitCode != 0:
    echo "ERROR: tar command failed with exit code ", exitCode
    if outputStr.len > 0:
      echo outputStr
    return false

  let size = getFileSize(output)
  echo "Backup created successfully:"
  echo "  File:     ", output
  echo "  Size:     ", formatBytes(size)
  echo "  Source:   ", dataDir
  return true

proc restoreDataDir*(input: string, dataDir: string, verbose: bool = false, dryRun: bool = false): bool =
  ## Restore from a tar.gz backup.
  ## When dryRun is true, only prints what would be done.
  if not fileExists(input):
    echo "ERROR: Backup file not found: ", input
    return false

  let archiveSize = getFileSize(input)
  let freeSpace = getFreeSpace(parentDir(dataDir))
  let oldBackupPath = dataDir & ".old_" & $getTime().toUnix()

  if dryRun:
    echo "DRY-RUN: The following actions would be performed:"
    echo "  1. Verify archive integrity: ", input
    echo "  2. Move existing data to:    ", oldBackupPath
    echo "  3. Extract archive to:       ", dataDir
    echo "  Archive size: ", formatBytes(archiveSize)
    if freeSpace >= 0:
      echo "  Free space:   ", formatBytes(freeSpace)
    else:
      echo "  Free space:   unable to determine"
    return true

  # Check free space
  if freeSpace >= 0 and freeSpace < archiveSize * 2:
    echo "WARNING: Free space (", formatBytes(freeSpace), ") may be insufficient."
    echo "         Archive is ", formatBytes(archiveSize), " — at least 2x is recommended."

  if dirExists(dataDir):
    if verbose:
      echo "Moving existing data to: ", oldBackupPath
    moveDir(dataDir, oldBackupPath)

  createDir(dataDir)

  let cmd = "tar -xzf " & quoteShell(input) & " -C " & quoteShell(dataDir)
  if verbose:
    echo "Running: ", cmd

  let (outputStr, exitCode) = execCmdEx(cmd)
  if exitCode != 0:
    echo "ERROR: tar extraction failed with exit code ", exitCode
    if outputStr.len > 0:
      echo outputStr
    # Attempt rollback
    if dirExists(oldBackupPath):
      echo "Attempting rollback..."
      removeDir(dataDir)
      moveDir(oldBackupPath, dataDir)
      echo "Rollback complete. Data restored to previous state."
    return false

  echo "Restored successfully from: ", input
  echo "  Target: ", dataDir
  if dirExists(oldBackupPath):
    echo "  Old data preserved at: ", oldBackupPath
  return true

proc verifyArchive*(input: string, verbose: bool = false): bool =
  ## Verify tar.gz archive integrity without extracting
  if not fileExists(input):
    echo "ERROR: Archive not found: ", input
    return false

  let cmd = "tar -tzf " & quoteShell(input) & " > /dev/null"
  if verbose:
    echo "Verifying archive: ", input

  let (_, exitCode) = execCmdEx(cmd)
  if exitCode == 0:
    let size = getFileSize(input)
    echo "Archive is valid: ", input, " (", formatBytes(size), ")"
    return true
  else:
    echo "ERROR: Archive is corrupted or unreadable: ", input
    return false

proc listBackups*(dataDir: string): seq[Backup] =
  ## List all backup archives found in current directory and next to data directory
  var backups: seq[Backup] = @[]
  var seenPaths: seq[string] = @[]

  proc scanDir(searchDir: string) =
    if not dirExists(searchDir):
      return
    for kind, path in walkDir(searchDir):
      if kind == pcFile:
        let fullPath = absolutePath(path)
        if fullPath in seenPaths:
          continue
        let (_, _, ext) = splitFile(path)
        if ext == ".gz" or ext == ".tar" or path.endsWith(".tar.gz"):
          seenPaths.add(fullPath)
          var backup = Backup(path: path)
          backup.size = getFileSize(path)
          backup.timestamp = parseBackupFilename(path)
          backup.compressed = path.endsWith(".gz")
          backups.add(backup)

  scanDir(getCurrentDir())
  scanDir(parentDir(dataDir))

  # Sort by timestamp descending (newest first)
  backups.sort(proc(a, b: Backup): int =
    if a.timestamp > b.timestamp: -1
    elif a.timestamp < b.timestamp: 1
    else: 0
  )
  result = backups

proc printBackups*(backups: seq[Backup]) =
  ## Pretty print backup list
  if backups.len == 0:
    echo "No backups found."
    return

  echo "Found ", backups.len, " backup(s):"
  echo repeat("-", 80)
  echo alignLeft("#", 4), alignLeft("Timestamp", 22), alignLeft("Size", 12), "Path"
  echo repeat("-", 80)
  for i, b in backups:
    let ts = if b.timestamp > 0: formatTimestamp(b.timestamp) else: "unknown"
    let idx = alignLeft($(i+1), 4)
    echo idx, alignLeft(ts, 22), alignLeft(formatBytes(b.size), 12), b.path
  echo repeat("-", 80)

proc cleanupOldBackups*(dataDir: string, keepLast: int = DEFAULT_KEEP_COUNT, verbose: bool = false) =
  ## Remove old backups keeping only N most recent
  var backups = listBackups(dataDir)
  if backups.len <= keepLast:
    echo "Nothing to clean. Found ", backups.len, " backup(s), keeping up to ", keepLast, "."
    return

  let toDelete = backups.len - keepLast
  echo "Removing ", toDelete, " old backup(s), keeping ", keepLast, " most recent."

  for i in countdown(backups.high, keepLast):
    if verbose:
      echo "  Deleting: ", backups[i].path, " (", formatBytes(backups[i].size), ")"
    removeFile(backups[i].path)

  echo "Cleanup complete."

proc printHistory*() =
  ## Display restore history
  let entries = readHistory()
  if entries.len == 0:
    echo "No restore history found."
    return
  echo "Restore history:"
  echo repeat("-", 80)
  for entry in entries:
    echo entry
  echo repeat("-", 80)

# =============================================================================
# CLI Entry Point
# =============================================================================
when isMainModule:
  var
    command = ""
    dataDir = DEFAULT_DATA_DIR
    target = ""
    keepCount = DEFAULT_KEEP_COUNT
    excludes: seq[string] = @[]
    compression = DEFAULT_COMPRESSION
    verbose = false
    dryRun = false
    force = false

  for kind, key, val in getopt():
    case kind
    of cmdArgument:
      if command == "":
        command = key
      elif target == "":
        target = key
    of cmdLongOption, cmdShortOption:
      case key
      of "data-dir", "d": dataDir = val
      of "output", "o": target = val
      of "input", "i": target = val
      of "keep", "k":
        try: keepCount = parseInt(val)
        except: quit("ERROR: --keep must be a number", 1)
      of "exclude", "e": excludes.add(val)
      of "level", "l":
        try:
          compression = parseInt(val)
          if compression < 0 or compression > 9:
            quit("ERROR: --level must be between 0 and 9", 1)
        except: quit("ERROR: --level must be a number", 1)
      of "dry-run": dryRun = true
      of "force", "f": force = true
      of "verbose", "v": verbose = true
      of "help", "h":
        echo HELP_TEXT
        quit(0)
      else: discard
    of cmdEnd: discard

  # If no command given, show help
  if command == "":
    echo HELP_TEXT
    quit(0)

  case command
  of "backup":
    let outputFile = if target.len > 0: target else: "backup_" & $getTime().toUnix() & ".tar.gz"
    let ok = backupDataDir(dataDir, outputFile, excludes, compression, verbose)
    if not ok:
      quit("Backup failed", 1)

  of "restore":
    if target.len == 0:
      quit("ERROR: restore requires --input=<file.tar.gz>\nUse 'backup help' for usage.", 1)

    # Always verify first unless dry-run
    if not dryRun:
      echo "Verifying archive before restore..."
      let vok = verifyArchive(target, verbose)
      if not vok:
        logRestore(target, dataDir, false)
        quit("Restore aborted: archive verification failed.", 1)

    if not dryRun and not force:
      echo "WARNING: This will REPLACE the data in: ", dataDir
      echo "Continue? [y/N] "
      let answer = readLine(stdin)
      if answer.toLowerAscii() notin ["y", "yes"]:
        echo "Restore cancelled."
        logRestore(target, dataDir, false, dryRun = false)
        quit(0)

    let ok = restoreDataDir(target, dataDir, verbose, dryRun)
    logRestore(target, dataDir, ok, dryRun)
    if not ok and not dryRun:
      quit("Restore failed", 1)

  of "list":
    let backups = listBackups(dataDir)
    printBackups(backups)

  of "verify":
    if target.len == 0:
      quit("ERROR: verify requires --input=<file.tar.gz>\nUse 'backup help' for usage.", 1)
    let ok = verifyArchive(target, verbose)
    if not ok:
      quit("Verification failed", 1)

  of "cleanup":
    cleanupOldBackups(dataDir, keepCount, verbose)

  of "history":
    printHistory()

  of "help":
    echo HELP_TEXT

  else:
    echo "ERROR: Unknown command: ", command
    echo ""
    echo HELP_TEXT
    quit(1)
