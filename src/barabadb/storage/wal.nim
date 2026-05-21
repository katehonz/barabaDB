## WAL — Write-Ahead Log for durability
import std/algorithm
import std/os
import std/streams
import std/strutils
import std/posix

const
  WALMagic* = 0x42415241'u32  # "BARA"
  WALVersion* = 1'u32
  DefaultMaxWalSegmentSize* = 64 * 1024 * 1024  # 64MB
  WalArchiveDir* = "wal_archive"

type
  WalEntryKind* = enum
    wekPut = 1
    wekDelete = 2
    wekCheckpoint = 3
    wekCommit = 4

  WalEntry* = object
    kind*: WalEntryKind
    timestamp*: uint64
    key*: seq[byte]
    value*: seq[byte]

  WalSegment* = object
    sequence*: int64
    path*: string
    size*: int64

  WriteAheadLog* = object
    dir*: string
    path: string
    stream: FileStream
    entryCount: uint64
    syncOnWrite: bool
    maxSegmentSize: int64
    currentSequence: int64

proc readEntries*(walPath: string, untilTimestamp: uint64 = 0): seq[WalEntry]
proc listWalArchive*(dir: string): seq[WalSegment]
proc maybeRotate*(wal: var WriteAheadLog)

proc parseWalSequence*(filename: string): int64 =
  ## Extract sequence from "wal.000042.log"
  try:
    if filename.startsWith("wal.") and filename.endsWith(".log"):
      let numStr = filename[4..^5]
      result = parseBiggestInt(numStr)
    else:
      result = 0
  except:
    result = 0

proc listWalArchive*(dir: string): seq[WalSegment] =
  ## Return all archived WAL segments sorted by sequence.
  result = @[]
  let archiveDir = dir / WalArchiveDir
  if not dirExists(archiveDir):
    return
  for kind, path in walkDir(archiveDir):
    if kind == pcFile and path.endsWith(".log"):
      let seqNum = parseWalSequence(extractFilename(path))
      if seqNum > 0:
        let size = try: getFileSize(path) except: 0
        result.add(WalSegment(sequence: seqNum, path: path, size: size))
  result.sort(proc(a, b: WalSegment): int = cmp(a.sequence, b.sequence))

proc nextWalSequence*(dir: string): int64 =
  ## Find the next available WAL sequence number.
  let segments = listWalArchive(dir)
  if segments.len == 0:
    return 1
  return segments[^1].sequence + 1

proc rotate*(wal: var WriteAheadLog) =
  ## Close current WAL and archive it, then start a new one.
  if wal.stream != nil:
    wal.stream.flush()
    wal.stream.close()

  let archiveDir = wal.dir / WalArchiveDir
  createDir(archiveDir)
  let archivePath = archiveDir / ("wal." & align($wal.currentSequence, 6, '0') & ".log")

  try:
    moveFile(wal.path, archivePath)
  except IOError as e:
    raise newException(IOError, "WAL rotation failed: cannot move " & wal.path & " to " & archivePath & ": " & e.msg)

  wal.currentSequence = wal.currentSequence + 1
  wal.stream = newFileStream(wal.path, fmWrite)
  if wal.stream == nil:
    raise newException(IOError, "Cannot create new WAL after rotation: " & wal.path)
  wal.stream.write(WALMagic)
  wal.stream.write(WALVersion)
  wal.stream.flush()
  wal.entryCount = 0

proc maybeRotate*(wal: var WriteAheadLog) =
  ## Rotate if current WAL exceeds max segment size.
  if wal.maxSegmentSize <= 0:
    return
  let currentSize = try: getFileSize(wal.path) except: 0
  if currentSize >= wal.maxSegmentSize:
    wal.rotate()

proc newWriteAheadLog*(dir: string, syncOnWrite: bool = true): WriteAheadLog =
  createDir(dir)
  let path = dir / "wal.log"
  let exists = fileExists(path)
  let isEmpty = if exists: getFileSize(path) == 0 else: true
  let stream = if exists: newFileStream(path, fmAppend) else: newFileStream(path, fmWrite)
  if stream == nil:
    raise newException(IOError, "Cannot open WAL: " & path)
  if not exists or isEmpty:
    stream.write(WALMagic)
    stream.write(WALVersion)
    stream.flush()
  # Count existing entries when appending to an existing WAL so
  # entryCount() remains accurate across restarts.
  var count: uint64 = 0
  if exists and not isEmpty:
    for e in readEntries(path):
      inc count

  let seqNum = nextWalSequence(dir)
  WriteAheadLog(
    dir: dir,
    path: path,
    stream: stream,
    entryCount: count,
    syncOnWrite: syncOnWrite,
    maxSegmentSize: DefaultMaxWalSegmentSize,
    currentSequence: seqNum,
  )

proc writeEntry*(wal: var WriteAheadLog, entry: WalEntry) =
  wal.stream.write(uint8(entry.kind))
  wal.stream.write(entry.timestamp)
  wal.stream.write(uint32(entry.key.len))
  if entry.key.len > 0:
    wal.stream.writeData(unsafeAddr entry.key[0], entry.key.len)
  wal.stream.write(uint32(entry.value.len))
  if entry.value.len > 0:
    wal.stream.writeData(unsafeAddr entry.value[0], entry.value.len)
  if wal.syncOnWrite:
    wal.stream.flush()
  inc wal.entryCount
  # Check rotation every 1000 entries to avoid stat on every write
  if wal.entryCount mod 1000 == 0:
    wal.maybeRotate()

proc writePut*(wal: var WriteAheadLog, key, value: openArray[byte], timestamp: uint64) =
  wal.writeEntry(WalEntry(
    kind: wekPut,
    timestamp: timestamp,
    key: @key,
    value: @value,
  ))

proc writeDelete*(wal: var WriteAheadLog, key: openArray[byte], timestamp: uint64) =
  wal.writeEntry(WalEntry(
    kind: wekDelete,
    timestamp: timestamp,
    key: @key,
    value: @[],
  ))

proc writeCommit*(wal: var WriteAheadLog, timestamp: uint64) =
  wal.writeEntry(WalEntry(
    kind: wekCommit,
    timestamp: timestamp,
    key: @[],
    value: @[],
  ))

proc sync*(wal: var WriteAheadLog) =
  wal.stream.flush()
  # Re-open with O_RDWR so fsync operates on a write-capable fd.
  # Not ideal (two fds for same file) but avoids accessing private
  # FileStream internals that vary across Nim versions.
  let fd = posix.open(cstring(wal.path), O_RDWR)
  if fd != -1:
    discard posix.fsync(fd)
    discard posix.close(fd)

proc setMaxSegmentSize*(wal: var WriteAheadLog, size: int64) =
  wal.maxSegmentSize = size

proc close*(wal: var WriteAheadLog) =
  wal.stream.flush()
  let fd = posix.open(cstring(wal.path), O_RDWR)
  if fd != -1:
    discard posix.fsync(fd)
    discard posix.close(fd)
  wal.stream.close()

proc entryCount*(wal: WriteAheadLog): uint64 = wal.entryCount
proc path*(wal: WriteAheadLog): string = wal.path

proc readEntries*(walPath: string, untilTimestamp: uint64 = 0): seq[WalEntry] =
  result = @[]
  if not fileExists(walPath): return
  let s = newFileStream(walPath, fmRead)
  if s == nil: return
  try:
    # Skip header
    var magic: uint32 = 0
    var version: uint32 = 0
    if s.readData(addr magic, 4) != 4: return
    if s.readData(addr version, 4) != 4: return
    if magic != WALMagic: return
    while not s.atEnd:
      var kind: uint8
      if s.readData(addr kind, 1) != 1: break
      var timestamp: uint64
      if s.readData(addr timestamp, 8) != 8: break
      if untilTimestamp > 0 and timestamp > untilTimestamp:
        break
      var keyLen: uint32
      if s.readData(addr keyLen, 4) != 4: break
      var key = newSeq[byte](keyLen)
      if keyLen > 0:
        if s.readData(addr key[0], int(keyLen)) != int(keyLen): break
      var valLen: uint32
      if s.readData(addr valLen, 4) != 4: break
      var value = newSeq[byte](valLen)
      if valLen > 0:
        if s.readData(addr value[0], int(valLen)) != int(valLen): break
      result.add(WalEntry(
        kind: WalEntryKind(kind),
        timestamp: timestamp,
        key: key,
        value: value,
      ))
  finally:
    s.close()
