## LSM-Tree Storage Engine — core key-value store
import std/algorithm
import std/os
import std/hashes
import std/tables
import std/monotimes
import bloom
import wal

const
  SSTableMagic* = 0x53535442'u32  # "SSTB"
  DefaultMemTableSize* = 4 * 1024 * 1024  # 4MB
  DefaultBloomFpRate* = 0.01

type
  Entry* = object
    key*: string
    value*: seq[byte]
    timestamp*: uint64
    deleted*: bool

  MemTable* = object
    entries: seq[Entry]
    size: int
    maxSize: int

  SSTable* = object
    path*: string
    index: Table[string, int64]  # key -> file offset
    bloom: BloomFilter
    level: int
    minKey: string
    maxKey: string
    entryCount: int

  LSMTree* = object
    dir: string
    memTable: MemTable
    immutableMem: MemTable
    sstables: seq[SSTable]
    wal: WriteAheadLog
    memMaxSize: int
    currentSeq: uint64
    readLocks: int

proc newMemTable(maxSize: int = DefaultMemTableSize): MemTable =
  MemTable(entries: @[], size: 0, maxSize: maxSize)

proc len*(mt: MemTable): int = mt.entries.len

proc put*(mt: var MemTable, key: string, value: seq[byte], timestamp: uint64, deleted: bool = false): bool =
  let entrySize = key.len + value.len + 16
  if mt.size + entrySize > mt.maxSize and mt.entries.len > 0:
    return false
  let entry = Entry(key: key, value: value, timestamp: timestamp, deleted: deleted)
  let pos = mt.entries.lowerBound(entry, proc(a, b: Entry): int = cmp(a.key, b.key))
  if pos < mt.entries.len and mt.entries[pos].key == key:
    mt.entries[pos] = entry
  else:
    mt.entries.insert(entry, pos)
  mt.size += entrySize
  return true

proc get*(mt: MemTable, key: string): (bool, Entry) =
  for entry in mt.entries:
    if entry.key == key:
      return (true, entry)
  return (false, Entry())

proc scan*(mt: MemTable, startKey, endKey: string): seq[Entry] =
  result = @[]
  for entry in mt.entries:
    if entry.key >= startKey and entry.key <= endKey:
      result.add(entry)

proc clear*(mt: var MemTable) =
  mt.entries.setLen(0)
  mt.size = 0

proc newLSMTree*(dir: string, memMaxSize: int = DefaultMemTableSize): LSMTree =
  createDir(dir)
  createDir(dir / "sstables")
  LSMTree(
    dir: dir,
    memTable: newMemTable(memMaxSize),
    immutableMem: newMemTable(0),
    sstables: @[],
    wal: newWriteAheadLog(dir / "wal"),
    memMaxSize: memMaxSize,
    currentSeq: 0,
    readLocks: 0,
  )

proc put*(db: var LSMTree, key: string, value: seq[byte]) =
  let ts = uint64(getMonoTime().ticks())
  db.wal.writePut(cast[seq[byte]](key), value, ts)
  if not db.memTable.put(key, value, ts):
    db.immutableMem = db.memTable
    db.memTable = newMemTable(db.memMaxSize)
    discard db.memTable.put(key, value, ts)

proc delete*(db: var LSMTree, key: string) =
  let ts = uint64(getMonoTime().ticks())
  db.wal.writeDelete(cast[seq[byte]](key), ts)
  discard db.memTable.put(key, @[], ts, deleted = true)

proc get*(db: LSMTree, key: string): (bool, seq[byte]) =
  let (found, entry) = db.memTable.get(key)
  if found:
    if entry.deleted:
      return (false, @[])
    return (true, entry.value)

  let (found2, entry2) = db.immutableMem.get(key)
  if found2:
    if entry2.deleted:
      return (false, @[])
    return (true, entry2.value)

  for sst in db.sstables:
    if key in sst.index:
      return (true, @[])  # placeholder for SSTable read

  return (false, @[])

proc contains*(db: LSMTree, key: string): bool =
  let (found, _) = db.get(key)
  return found

proc flush*(db: var LSMTree) =
  if db.memTable.len == 0:
    return
  db.immutableMem = db.memTable
  db.memTable = newMemTable(db.memMaxSize)
  db.wal.writeCommit(uint64(getMonoTime().ticks()))
  db.wal.sync()

proc close*(db: var LSMTree) =
  db.flush()
  db.wal.close()

proc memTableSize*(db: LSMTree): int = db.memTable.len
proc sstableCount*(db: LSMTree): int = db.sstables.len
proc dir*(db: LSMTree): string = db.dir
