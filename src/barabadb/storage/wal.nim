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
