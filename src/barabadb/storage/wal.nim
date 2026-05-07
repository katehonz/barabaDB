## WAL — Write-Ahead Log for durability
import std/os
import std/streams

const
  WALMagic* = 0x42415241'u32  # "BARA"
  WALVersion* = 1'u32

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

  WriteAheadLog* = object
    path: string
    stream: FileStream
    entryCount: uint64
    syncOnWrite: bool

proc newWriteAheadLog*(dir: string, syncOnWrite: bool = true): WriteAheadLog =
  createDir(dir)
  let path = dir / "wal.log"
  let exists = fileExists(path)
  let stream = if exists: newFileStream(path, fmAppend) else: newFileStream(path, fmWrite)
  if stream == nil:
    raise newException(IOError, "Cannot open WAL: " & path)
  if not exists:
    stream.write(WALMagic)
    stream.write(WALVersion)
    stream.flush()
  WriteAheadLog(path: path, stream: stream, entryCount: 0, syncOnWrite: syncOnWrite)

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

proc close*(wal: var WriteAheadLog) =
  wal.stream.flush()
  wal.stream.close()

proc entryCount*(wal: WriteAheadLog): uint64 = wal.entryCount
proc path*(wal: WriteAheadLog): string = wal.path

proc readEntries*(walPath: string, untilTimestamp: uint64 = 0): seq[WalEntry] =
  result = @[]
  if not fileExists(walPath): return
  let s = newFileStream(walPath, fmRead)
  if s == nil: return
  # Skip header
  var magic: uint32
  var version: uint32
  discard s.readData(addr magic, 4)
  discard s.readData(addr version, 4)
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
  s.close()
