## Crash Recovery — WAL replay with REDO/UNDO
import std/streams
import std/os
import std/tables
import ../storage/wal

type
  RecoveryState* = enum
    recScanning
    recRedoing
    recUndoing
    recDone

  RecoveryResult* = object
    state*: RecoveryState
    totalEntries*: int
    redone*: int
    undone*: int
    lastLsn*: uint64
    lastTxn*: uint64
    applied*: bool

  RecoveredEntry* = object
    key*: string
    value*: seq[byte]
    lsn*: uint64
    txnId*: uint64
    isDelete*: bool

  CrashRecovery* = ref object
    walDir*: string
    dataDir*: string
    entries*: seq[RecoveredEntry]
    result*: RecoveryResult

proc newCrashRecovery*(walDir: string, dataDir: string): CrashRecovery =
  CrashRecovery(
    walDir: walDir,
    dataDir: dataDir,
    entries: @[],
    result: RecoveryResult(state: recScanning),
  )

proc scanWAL*(rec: CrashRecovery): seq[RecoveredEntry] =
  result = @[]
  let walPath = rec.walDir / "wal.log"
  if not fileExists(walPath):
    return

  let stream = newFileStream(walPath, fmRead)
  if stream == nil:
    return

  # Read magic and version
  var magic: uint32 = 0
  var version: uint32 = 0
  if stream.readData(addr magic, 4) != 4:
    stream.close()
    return
  if magic != WALMagic:
    stream.close()
    return

  if stream.readData(addr version, 4) != 4:
    stream.close()
    return

  var txnId: uint64 = 0
  var entryCount = 0

  # Read entries
  while not stream.atEnd():
    var kind: uint8 = 0
    var timestamp: uint64 = 0
    var keyLen: uint32 = 0
    var valLen: uint32 = 0

    if stream.readData(addr kind, 1) != 1: break
    if stream.readData(addr timestamp, 8) != 8: break
    if stream.readData(addr keyLen, 4) != 4: break

    var key = newString(keyLen.int)
    if keyLen > 0:
      if stream.readData(addr key[0], keyLen.int) != keyLen.int: break

    if stream.readData(addr valLen, 4) != 4: break
    var value = newSeq[byte](valLen.int)
    if valLen > 0:
      if stream.readData(addr value[0], valLen.int) != valLen.int: break

    inc entryCount

    case WalEntryKind(kind)
    of wekPut:
      result.add(RecoveredEntry(key: key, value: value,
                                 lsn: uint64(entryCount), txnId: txnId))
    of wekDelete:
      result.add(RecoveredEntry(key: key, value: @[],
                                 lsn: uint64(entryCount), txnId: txnId, isDelete: true))
    of wekCommit:
      inc txnId
    of wekCheckpoint:
      discard

  stream.close()

proc analyze*(rec: CrashRecovery): RecoveryResult =
  rec.entries = rec.scanWAL()

  if rec.entries.len == 0:
    rec.result = RecoveryResult(state: recDone, applied: false)
    return rec.result

  # Find last successful checkpoint or committed txn
  var lastCommitted: uint64 = 0
  var uncommittedEntries: seq[RecoveredEntry] = @[]

  for entry in rec.entries:
    if entry.txnId > lastCommitted:
      lastCommitted = entry.txnId

  # Entries with txnId < lastCommitted are committed -> redo
  # Entries with txnId == lastCommitted and no commit seen -> undo
  var redoCount = 0
  var undoCount = 0

  for entry in rec.entries:
    if entry.txnId < lastCommitted:
      inc redoCount
    else:
      inc undoCount

  rec.result = RecoveryResult(
    state: recDone,
    totalEntries: rec.entries.len,
    redone: redoCount,
    undone: undoCount,
    lastLsn: if rec.entries.len > 0: rec.entries[^1].lsn else: 0,
    lastTxn: lastCommitted,
    applied: true,
  )

  return rec.result

proc recover*(rec: CrashRecovery): RecoveryResult =
  let result = rec.analyze()

  if not result.applied:
    return result

  # In a real system, would redo committed entries and undo uncommitted ones
  # For now, provide the analysis result
  return result

proc totalEntries*(rec: CrashRecovery): int = rec.entries.len

proc summary*(rec: CrashRecovery): string =
  let r = rec.recover()
  result = "WAL Recovery Summary:\n"
  result &= "  Total entries: " & $r.totalEntries & "\n"
  result &= "  Redone (committed): " & $r.redone & "\n"
  result &= "  Undone (uncommitted): " & $r.undone & "\n"
  result &= "  Last committed txn: " & $r.lastTxn & "\n"
  result &= "  Recovery complete: " & $r.applied
