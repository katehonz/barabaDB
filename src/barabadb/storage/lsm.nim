## LSM-Tree Storage Engine — core key-value store
import std/algorithm
import std/os
import std/hashes
import std/strutils
import std/tables
import std/monotimes
import std/streams
import std/locks
import bloom
import wal
import mmap
import streams

const
  SSTableMagic* = 0x53535442'u32  # "SSTB"
  SSTableVersion* = 1'u32
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
    index*: Table[string, int64]
    bloom*: BloomFilter
    level*: int
    minKey*: string
    maxKey*: string
    entryCount*: int
    mmapFile*: MmapFile

  LSMTree* = ref object
    dir*: string
    memTable: MemTable
    immutableMem: MemTable
    sstables*: seq[SSTable]
    wal: WriteAheadLog
    memMaxSize: int
    currentSeq: uint64
    nextSSTableId: int
    lock*: Lock

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
  if mt.entries.len == 0:
    return (false, Entry())
  var lo = 0
  var hi = mt.entries.len - 1
  while lo <= hi:
    let mid = (lo + hi) div 2
    let c = cmp(mt.entries[mid].key, key)
    if c == 0:
      return (true, mt.entries[mid])
    elif c < 0:
      lo = mid + 1
    else:
      hi = mid - 1
  return (false, Entry())

proc scan*(mt: MemTable, startKey, endKey: string): seq[Entry] =
  result = @[]
  for entry in mt.entries:
    if entry.key >= startKey and entry.key <= endKey:
      result.add(entry)

proc clear*(mt: var MemTable) =
  mt.entries.setLen(0)
  mt.size = 0

# ----------------------------------------------------------------------
# SSTable serialization format (native endianness):
# [Header] 28 bytes
#   magic: uint32
#   version: uint32
#   entryCount: uint32
#   indexOffset: uint64
#   bloomOffset: uint64
#
# [Data Block]
#   For each entry:
#     keyLen: uint32
#     key: bytes[keyLen]
#     valueLen: uint32
#     value: bytes[valueLen]
#     timestamp: uint64
#     deleted: uint8
#
# [Index Block]
#   For each entry:
#     keyLen: uint32
#     key: bytes[keyLen]
#     dataOffset: uint64   # offset of this entry in data block
#
# [Bloom Filter Block]
#   bloomSize: uint32
#   bloomData: bytes[bloomSize]
# ----------------------------------------------------------------------

proc writeSSTable*(entries: seq[Entry], path: string, level: int): SSTable =
  let s = newFileStream(path, fmWrite)
  if s.isNil:
    raise newException(IOError, "Cannot create SSTable file: " & path)

  # Write header
  s.write(SSTableMagic)
  s.write(SSTableVersion)
  s.write(uint32(entries.len))
  let indexOffsetPos = s.getPosition()
  s.write(0'u64)  # patched after data+bloom are written
  let bloomOffsetPos = s.getPosition()
  s.write(0'u64)  # patched after data+bloom are written

  # Write data block
  var offsets = newSeq[(string, int64)](entries.len)
  for i, entry in entries:
    offsets[i] = (entry.key, int64(s.getPosition()))
    s.write(uint32(entry.key.len))
    s.write(entry.key)
    s.write(uint32(entry.value.len))
    if entry.value.len > 0:
      s.writeData(addr entry.value[0], entry.value.len)
    s.write(entry.timestamp)
    s.write(if entry.deleted: 1'u8 else: 0'u8)

  let indexOffset = uint64(s.getPosition())

  # Write index block
  for i, entry in entries:
    s.write(uint32(entry.key.len))
    s.write(entry.key)
    s.write(uint64(offsets[i][1]))

  let bloomOffset = uint64(s.getPosition())

  # Write bloom filter
  var bloom = newBloomFilter(max(entries.len * 10, 1000), DefaultBloomFpRate)
  for entry in entries:
    bloom.add(cast[seq[byte]](entry.key))
  let bloomData = bloom.serialize()
  s.write(uint32(bloomData.len))
  if bloomData.len > 0:
    s.writeData(addr bloomData[0], bloomData.len)

  # Patch header with correct offsets before closing
  s.setPosition(int(indexOffsetPos))
  s.write(indexOffset)
  s.setPosition(int(bloomOffsetPos))
  s.write(bloomOffset)
  s.close()

  # Build in-memory index
  var idxTable = initTable[string, int64]()
  var minK = ""
  var maxK = ""
  for i, entry in entries:
    idxTable[entry.key] = offsets[i][1]
    if minK == "" or entry.key < minK: minK = entry.key
    if maxK == "" or entry.key > maxK: maxK = entry.key

  result = SSTable(
    path: path,
    index: idxTable,
    bloom: bloom,
    level: level,
    minKey: minK,
    maxKey: maxK,
    entryCount: entries.len,
    mmapFile: openMmap(path),
  )

proc loadSSTable*(path: string): SSTable =
  let mf = openMmap(path)
  if mf.regions.len == 0:
    raise newException(IOError, "Cannot mmap SSTable: " & path)

  if mf.readUint32(0) != SSTableMagic:
    raise newException(ValueError, "Invalid SSTable magic")
  if mf.readUint32(4) != SSTableVersion:
    raise newException(ValueError, "Unsupported SSTable version")

  let entryCount = int(mf.readUint32(8))
  let indexOffset = int(mf.readUint64(12))
  let bloomOffset = int(mf.readUint64(20))

  var idxTable = initTable[string, int64]()
  var minK = ""
  var maxK = ""

  # Parse index block
  var pos = indexOffset
  for i in 0..<entryCount:
    let keyLen = int(mf.readUint32(pos))
    pos += 4
    let key = mf.readString(pos, keyLen)
    pos += keyLen
    let dataOffset = int64(mf.readUint64(pos))
    pos += 8
    idxTable[key] = dataOffset
    if minK == "" or key < minK: minK = key
    if maxK == "" or key > maxK: maxK = key

  # Parse bloom filter
  var bloom = newBloomFilter(max(entryCount * 10, 1000), DefaultBloomFpRate)
  pos = bloomOffset
  let bloomSize = int(mf.readUint32(pos))
  pos += 4
  if bloomSize > 0 and pos + bloomSize <= mf.totalSize:
    var bloomData = newSeq[byte](bloomSize)
    copyMem(addr bloomData[0], unsafeAddr mf.regions[0].data[pos], bloomSize)
    bloom.deserialize(bloomData)

  result = SSTable(
    path: path,
    index: idxTable,
    bloom: bloom,
    level: 0,
    minKey: minK,
    maxKey: maxK,
    entryCount: entryCount,
    mmapFile: mf,
  )

proc readSSTableEntry*(sst: SSTable, key: string): (bool, Entry) =
  if key notin sst.index:
    return (false, Entry())

  let offset = int(sst.index[key])
  let mf = sst.mmapFile
  if mf.regions.len == 0:
    return (false, Entry())

  var pos = offset
  if pos + 4 > mf.totalSize:
    return (false, Entry())
  let keyLen = int(mf.readUint32(pos))
  pos += 4
  if pos + keyLen > mf.totalSize:
    return (false, Entry())
  let readKey = mf.readString(pos, keyLen)
  pos += keyLen
  if readKey != key:
    return (false, Entry())

  if pos + 4 > mf.totalSize:
    return (false, Entry())
  let valueLen = int(mf.readUint32(pos))
  pos += 4
  if pos + valueLen + 8 + 1 > mf.totalSize:
    return (false, Entry())

  var value = newSeq[byte](valueLen)
  if valueLen > 0:
    copyMem(addr value[0], unsafeAddr mf.regions[0].data[pos], valueLen)
  pos += valueLen

  let timestamp = mf.readUint64(pos)
  pos += 8
  let deleted = mf.readByte(pos) != 0

  return (true, Entry(key: key, value: value, timestamp: timestamp, deleted: deleted))

proc close*(sst: var SSTable) =
  sst.mmapFile.close()

# ----------------------------------------------------------------------
# LSMTree API
# ----------------------------------------------------------------------

proc newLSMTree*(dir: string, memMaxSize: int = DefaultMemTableSize): LSMTree =
  createDir(dir)
  createDir(dir / "sstables")

  var sstables: seq[SSTable] = @[]
  var nextId = 1

  # Load existing SSTables
  for kind, path in walkDir(dir / "sstables"):
    if kind == pcFile and path.endsWith(".sst"):
      try:
        var sst = loadSSTable(path)
        sstables.add(sst)
        let name = splitFile(path).name
        nextId = max(nextId, parseInt(name) + 1)
      except:
        discard  # skip corrupt SSTables

  sstables.sort(proc(a, b: SSTable): int = cmp(a.minKey, b.minKey))

  new(result)
  initLock(result.lock)
  result.dir = dir
  result.memTable = newMemTable(memMaxSize)
  result.immutableMem = newMemTable(0)
  result.sstables = sstables
  result.wal = newWriteAheadLog(dir / "wal")
  result.memMaxSize = memMaxSize
  result.currentSeq = 0
  result.nextSSTableId = nextId

  # WAL crash recovery — replay unflushed entries into memTable
  let walPath = dir / "wal" / "wal.log"
  if fileExists(walPath):
    try:
      let stream = newFileStream(walPath, fmRead)
      if stream != nil:
        var magic: uint32 = 0
        var version: uint32 = 0
        if stream.readData(addr magic, 4) == 4 and magic == WALMagic:
          if stream.readData(addr version, 4) == 4:
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
              case WalEntryKind(kind)
              of wekPut:
                discard result.memTable.put(key, value, timestamp)
              of wekDelete:
                discard result.memTable.put(key, @[], timestamp)  # tombstone
              of wekCommit:
                discard
              of wekCheckpoint:
                discard
        stream.close()
    except:
      discard

proc put*(db: LSMTree, key: string, value: seq[byte]) =
  acquire(db.lock)
  defer: release(db.lock)
  let ts = uint64(getMonoTime().ticks())
  db.wal.writePut(cast[seq[byte]](key), value, ts)
  if not db.memTable.put(key, value, ts):
    db.immutableMem = db.memTable
    db.memTable = newMemTable(db.memMaxSize)
    discard db.memTable.put(key, value, ts)

proc delete*(db: LSMTree, key: string) =
  acquire(db.lock)
  defer: release(db.lock)
  let ts = uint64(getMonoTime().ticks())
  db.wal.writeDelete(cast[seq[byte]](key), ts)
  discard db.memTable.put(key, @[], ts, deleted = true)

proc getUnsafe(db: LSMTree, key: string): (bool, seq[byte]) =
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

  # Search SSTables from newest to oldest
  for i in countdown(db.sstables.high, db.sstables.low):
    let sst = db.sstables[i]
    if key < sst.minKey or key > sst.maxKey:
      continue
    if not sst.bloom.contains(cast[seq[byte]](key)):
      continue
    let (found3, entry3) = readSSTableEntry(sst, key)
    if found3:
      if entry3.deleted:
        return (false, @[])
      return (true, entry3.value)

  return (false, @[])

proc get*(db: LSMTree, key: string): (bool, seq[byte]) =
  acquire(db.lock)
  defer: release(db.lock)
  return getUnsafe(db, key)

proc contains*(db: LSMTree, key: string): bool =
  acquire(db.lock)
  defer: release(db.lock)
  let (found, _) = getUnsafe(db, key)
  return found

proc flushUnsafe(db: LSMTree) =
  if db.immutableMem.len == 0 and db.memTable.len == 0:
    return

  # Flush immutable memtable if present, otherwise flush current memtable
  var toFlush = db.immutableMem
  if toFlush.len == 0:
    toFlush = db.memTable
    db.memTable = newMemTable(db.memMaxSize)
  else:
    db.immutableMem = newMemTable(0)

  if toFlush.len == 0:
    return

  let path = db.dir / "sstables" / ($db.nextSSTableId & ".sst")
  inc db.nextSSTableId

  var sst = writeSSTable(toFlush.entries, path, level = 0)
  db.sstables.add(sst)
  db.sstables.sort(proc(a, b: SSTable): int = cmp(a.minKey, b.minKey))

  db.wal.writeCommit(uint64(getMonoTime().ticks()))
  db.wal.sync()

proc flush*(db: LSMTree) =
  acquire(db.lock)
  defer: release(db.lock)
  flushUnsafe(db)

proc close*(db: LSMTree) =
  acquire(db.lock)
  defer: release(db.lock)
  flushUnsafe(db)
  for sst in db.sstables.mitems:
    sst.close()
  db.wal.close()

proc memTableSize*(db: LSMTree): int =
  acquire(db.lock)
  defer: release(db.lock)
  return db.memTable.len

proc sstableCount*(db: LSMTree): int =
  acquire(db.lock)
  defer: release(db.lock)
  return db.sstables.len

proc dir*(db: LSMTree): string =
  acquire(db.lock)
  defer: release(db.lock)
  return db.dir

proc scanMemTable*(db: LSMTree): seq[Entry] =
  acquire(db.lock)
  defer: release(db.lock)
  ## Return all entries from memory (memTable + immutableMem)
  result = @[]
  for e in db.memTable.entries:
    result.add(e)
  for e in db.immutableMem.entries:
    result.add(e)
