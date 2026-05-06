## BaraDB Backup & Restore — tar.gz snapshots with retention, verification & CLI
##
## Commands:
##   backup   Create a snapshot of the data directory
##   restore  Restore data directory from a snapshot
##   list     List available snapshots with size & timestamp
##   verify   Check archive integrity without extracting
##   cleanup  Remove old snapshots keeping N most recent
##   help     Show detailed usage information
##
## Options:
##   --data-dir, -d <DIR>   Data directory to backup (default: data/server)
##   --output,   -o <FILE>  Output archive path for backup
##   --input,    -i <FILE>  Input archive path for restore/verify
##   --keep,     -k <N>     Number of snapshots to retain (default: 5)
##   --exclude,  -e <PAT>   Exclude pattern (can be used multiple times)
##   --level,    -l <0-9>   Compression level for gzip (default: 6)
##   --verbose,  -v         Enable verbose output

import std/os
import std/osproc
import std/strutils
import std/times
import std/algorithm
import std/sequtils
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

  list     Show all snapshots found next to the data directory.
           Displays size, timestamp and compression ratio if known.

  verify   Test archive integrity without extracting files.
           Detects corrupted or incomplete snapshots early.

  cleanup  Delete old snapshots, keeping only the N most recent ones.
           Default retention is 5 snapshots.

  help     Show this help message.

OPTIONS:
  -d, --data-dir <DIR>   Path to data directory (default: data/server)
  -o, --output   <FILE>  Destination path for new backup archive
  -i, --input    <FILE>  Source archive for restore or verify
  -k, --keep     <N>     Retention count for cleanup (default: 5)
  -e, --exclude  <PAT>   Exclude files matching pattern (repeatable)
  -l, --level    <0-9>   Gzip compression level (default: 6, max: 9)
  -v, --verbose          Print detailed progress information

EXAMPLES:
  # Quick backup with default settings
  backup backup

  # Backup with maximum compression and custom name
  backup backup --output=prod_backup_$(date +%F).tar.gz --level=9

  # Restore from a specific snapshot
  backup restore --input=backup_1715011200.tar.gz

  # List all snapshots
  backup list

  # Verify archive before restoring
  backup verify --input=backup_1715011200.tar.gz

  # Keep only last 3 snapshots
  backup cleanup --keep=3

  # Exclude WAL files from backup
  backup backup --exclude="*.log" --exclude="wal/*"
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

proc restoreDataDir*(input: string, dataDir: string, verbose: bool = false): bool =
  ## Restore from a tar.gz backup
  if not fileExists(input):
    echo "ERROR: Backup file not found: ", input
    return false

  if dirExists(dataDir):
    let backupOld = dataDir & ".old_" & $getTime().toUnix()
    if verbose:
      echo "Moving existing data to: ", backupOld
    moveDir(dataDir, backupOld)

  createDir(dataDir)

  let cmd = "tar -xzf " & quoteShell(input) & " -C " & quoteShell(dataDir)
  if verbose:
    echo "Running: ", cmd

  let (outputStr, exitCode) = execCmdEx(cmd)
  if exitCode != 0:
    echo "ERROR: tar extraction failed with exit code ", exitCode
    if outputStr.len > 0:
      echo outputStr
    return false

  echo "Restored successfully from: ", input
  echo "  Target: ", dataDir
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
    echo "WARNING: This will REPLACE the data in: ", dataDir
    echo "Continue? [y/N] "
    let answer = readLine(stdin)
    if answer.toLowerAscii() notin ["y", "yes"]:
      quit("Restore cancelled", 0)
    let ok = restoreDataDir(target, dataDir, verbose)
    if not ok:
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

  of "help":
    echo HELP_TEXT

  else:
    echo "ERROR: Unknown command: ", command
    echo ""
    echo HELP_TEXT
    quit(1)
