## BaraDB Backup & Restore — tar.gz snapshots
import std/os
import std/osproc
import std/strutils
import std/times

type
  Backup* = object
    path*: string
    timestamp*: int64
    size*: int64

proc backupDataDir*(dataDir: string, output: string): bool =
  ## Create a tar.gz backup of the data directory
  if not dirExists(dataDir):
    echo "Data directory not found: ", dataDir
    return false

  let parent = parentDir(dataDir)
  let name = lastPathPart(dataDir)
  let cmd = "tar -czf " & quoteShell(output) & " -C " & quoteShell(parent) & " " & quoteShell(name)
  let exitCode = execCmd(cmd)
  return exitCode == 0

proc restoreDataDir*(input: string, dataDir: string): bool =
  ## Restore from a tar.gz backup
  if not fileExists(input):
    echo "Backup file not found: ", input
    return false

  if dirExists(dataDir):
    removeDir(dataDir)
  createDir(dataDir)

  let cmd = "tar -xzf " & quoteShell(input) & " -C " & quoteShell(dataDir)
  let exitCode = execCmd(cmd)
  return exitCode == 0

proc listBackups*(dataDir: string): seq[Backup] =
  result = @[]
  for kind, path in walkDir(parentDir(dataDir)):
    let (_, name, ext) = splitFile(path)
    if ext == ".gz":
      var backup = Backup(path: path)
      backup.size = getFileSize(path)
      result.add(backup)

proc cleanupOldBackups*(dataDir: string, keepLast: int = 5) =
  var backups = listBackups(dataDir)
  if backups.len <= keepLast:
    return
  for i in 0..<(backups.len - keepLast):
    removeFile(backups[i].path)

when isMainModule:
  import std/os
  import std/parseopt

  var
    command = ""
    dataDir = "data/server"
    target = ""

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
      else: discard
    of cmdEnd: discard

  case command
  of "backup":
    let outputFile = if target.len > 0: target else: "backup_" & $getTime().toUnix() & ".tar.gz"
    let ok = backupDataDir(dataDir, outputFile)
    if ok:
      echo "Backup created: ", outputFile
    else:
      quit("Backup failed", 1)
  of "restore":
    if target.len == 0:
      quit("Usage: backup restore --input=<file.tar.gz>", 1)
    let ok = restoreDataDir(target, dataDir)
    if ok:
      echo "Restored from: ", target
    else:
      quit("Restore failed", 1)
  of "list":
    let backups = listBackups(dataDir)
    echo "Backups:"
    for b in backups:
      echo "  ", b.path, " (", b.size, " bytes)"
  else:
    echo "Usage: backup <backup|restore|list> [--data-dir=DIR] [--output/-i=FILE]"
    quit(1)
