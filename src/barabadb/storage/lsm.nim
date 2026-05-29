## LSM-Tree Storage Engine — core key-value store
import std/algorithm
import std/os
import std/hashes
import std/strutils
import std/tables
import std/monotimes
import std/times
import std/streams
import std/locks
import std/json
import bloom
import wal
import mmap
import crc32

const
  SSTableMagic* = 0x53535442'u32  # "SSTB"
  SSTableVersion* = 3'u32
  DefaultMemTableSize* = 4 * 1024 * 1024  # 4MB
  DefaultBloomFpRate* = 0.01
  ManifestVersion* = 1
  ManifestFileName* = "MANIFEST"

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
    id*: int
    path*: string
    index*: Table[string, int64]
    bloom*: BloomFilter
    level*: int
    minKey*: string
    maxKey*: string
    entryCount*: int
    fileVersion*: uint32
    mmapFile*: MmapFile

  LSMTree* = ref object
    dir*: string
    memTable: MemTable
    immutableMem: MemTable
    sstables*: seq[SSTable]
    wal*: WriteAheadLog
    memMaxSize: int
    currentSeq: uint64
    nextSSTableId*: int
    manifestSequence*: int64
    lock*: Lock
    walLock*: Lock

proc newMemTable(maxSize: int = DefaultMemTableSize): MemTable =
  MemTable(entries: @[], size: 0, maxSize: maxSize)

proc len*(mt: MemTable): int = mt.entries.len

proc put*(mt: var MemTable, key: string, value: seq[byte], timestamp: uint64, deleted: bool = false): bool =
  let entrySize = key.len + value.len + 16
  if entrySize > mt.maxSize:
    return false
  let entry = Entry(key: key, value: value, timestamp: timestamp, deleted: deleted)
  let pos = mt.entries.lowerBound(entry, proc(a, b: Entry): int = cmp(a.key, b.key))
  if pos < mt.entries.len and mt.entries[pos].key == key:
    let oldSize = mt.entries[pos].key.len + mt.entries[pos].value.len + 16
    mt.entries[pos] = entry
    mt.size += entrySize - oldSize
  else:
    if mt.size + entrySize > mt.maxSize and mt.entries.len > 0:
      return false
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
# [Header] 36 bytes (v3)
#   magic: uint32        (0x53535442 = "SSTB")
#   version: uint32      (3 = current, 2 = legacy with level, 1 = legacy)
#   entryCount: uint32
#   level: uint32
#   indexOffset: uint64
#   bloomOffset: uint64
#   footerOffset: uint64   # v3 only
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
#
# [Footer] 16 bytes (v3 only)
#   dataCrc32: uint32    # CRC32 of Data Block
#   indexCrc32: uint32   # CRC32 of Index Block
#   bloomCrc32: uint32   # CRC32 of Bloom Block
#   reserved: uint32     # must be 0
# ----------------------------------------------------------------------

const
  SSTableFooterSize* = 16

proc writeSSTable*(entries: seq[Entry], path: string, level: int): SSTable =
  let tmpPath = path & ".tmp"
  let s = newFileStream(tmpPath, fmWrite)
  if s.isNil:
    raise newException(IOError, "Cannot create SSTable file: " & tmpPath)

  # Write header (v3: 36 bytes)
  s.write(SSTableMagic)
  s.write(SSTableVersion)
  if entries.len > high(uint32).int:
    raise newException(ValueError, "SSTable entry count exceeds uint32 limit")
  s.write(uint32(entries.len))
  s.write(uint32(level))
  let indexOffsetPos = s.getPosition()
  s.write(0'u64)  # patched after data+bloom are written
  let bloomOffsetPos = s.getPosition()
  s.write(0'u64)  # patched after data+bloom are written
  let footerOffsetPos = s.getPosition()
  s.write(0'u64)  # patched after footer is written

  # Write data block
  var offsets = newSeq[(string, int64)](entries.len)
  for i, entry in entries:
    offsets[i] = (entry.key, int64(s.getPosition()))
    if entry.key.len > high(uint32).int:
      raise newException(ValueError, "SSTable key length exceeds uint32 limit")
    s.write(uint32(entry.key.len))
    s.write(entry.key)
    if entry.value.len > high(uint32).int:
      raise newException(ValueError, "SSTable value length exceeds uint32 limit")
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

  let footerOffset = uint64(s.getPosition())
  s.close()

  # Compute CRCs via mmap
  let mf = openMmap(tmpPath, mmReadOnly)
  if mf.regions.len == 0:
    removeFile(tmpPath)
    raise newException(IOError, "Cannot mmap SSTable for CRC: " & tmpPath)

  let headerSize = 40
  let dataCrc = crc32(unsafeAddr mf.regions[0].data[headerSize], int(indexOffset) - headerSize)
  let indexCrc = crc32(unsafeAddr mf.regions[0].data[int(indexOffset)], int(bloomOffset) - int(indexOffset))
  let bloomCrc = crc32(unsafeAddr mf.regions[0].data[int(bloomOffset)], int(footerOffset) - int(bloomOffset))
  mf.close()

  # Write footer and patch header
  let s2 = newFileStream(tmpPath, fmReadWriteExisting)
  if s2.isNil:
    removeFile(tmpPath)
    raise newException(IOError, "Cannot reopen SSTable for footer write: " & tmpPath)

  s2.setPosition(int(footerOffset))
  s2.write(dataCrc)
  s2.write(indexCrc)
  s2.write(bloomCrc)
  s2.write(0'u32)  # reserved

  s2.setPosition(int(indexOffsetPos))
  s2.write(indexOffset)
  s2.setPosition(int(bloomOffsetPos))
  s2.write(bloomOffset)
  s2.setPosition(int(footerOffsetPos))
  s2.write(footerOffset)
  s2.close()

  # Atomic rename: tmp -> final path
  if fileExists(path):
    removeFile(path)
  moveFile(tmpPath, path)

  # Build in-memory index
  var idxTable = initTable[string, int64]()
  var minK = ""
  var maxK = ""
  for i, entry in entries:
    idxTable[entry.key] = offsets[i][1]
    if minK == "" or entry.key < minK: minK = entry.key
    if maxK == "" or entry.key > maxK: maxK = entry.key

  result = SSTable(
    id: -1,
    path: path,
    index: idxTable,
    bloom: bloom,
    level: level,
    minKey: minK,
    maxKey: maxK,
    entryCount: entries.len,
    fileVersion: SSTableVersion,
    mmapFile: openMmap(path),
  )

proc verifySSTable*(path: string): (bool, string) =
  ## Verify SSTable integrity: magic, version, CRC footer.
  ## Returns (ok, message).
  let mf = openMmap(path, mmReadOnly)
  if mf.regions.len == 0:
    return (false, "Cannot mmap: " & path)
  if mf.totalSize < 40:
    return (false, "File too small: " & path)

  if mf.readUint32(0) != SSTableMagic:
    return (false, "Invalid SSTable magic: " & path)
  let fileVersion = mf.readUint32(4)
  if fileVersion == 1'u32:
    return (true, "OK (legacy v1): " & path)
  elif fileVersion == 2'u32:
    return (true, "OK (legacy v2): " & path)
  elif fileVersion != SSTableVersion:
    return (false, "Unsupported SSTable version " & $fileVersion & ": " & path)

  # v3 CRC verification
  let footerOffset = int(mf.readUint64(32))
  if footerOffset + SSTableFooterSize > mf.totalSize:
    return (false, "Footer extends past EOF (" & $footerOffset & " + 16 > " & $mf.totalSize & "): " & path)

  let indexOffset = int(mf.readUint64(16))
  let bloomOffset = int(mf.readUint64(24))

  let storedDataCrc = mf.readUint32(footerOffset)
  let storedIndexCrc = mf.readUint32(footerOffset + 4)
  let storedBloomCrc = mf.readUint32(footerOffset + 8)
  let reserved = mf.readUint32(footerOffset + 12)
  if reserved != 0:
    return (false, "Non-zero reserved field in footer: " & path)

  let headerSize = 40
  let computedDataCrc = crc32(unsafeAddr mf.regions[0].data[headerSize], indexOffset - headerSize)
  let computedIndexCrc = crc32(unsafeAddr mf.regions[0].data[indexOffset], bloomOffset - indexOffset)
  let computedBloomCrc = crc32(unsafeAddr mf.regions[0].data[bloomOffset], footerOffset - bloomOffset)

  if computedDataCrc != storedDataCrc:
    return (false, "Data block CRC mismatch (expected " & crc32ToHex(storedDataCrc) & ", got " & crc32ToHex(computedDataCrc) & "): " & path)
  if computedIndexCrc != storedIndexCrc:
    return (false, "Index block CRC mismatch (expected " & crc32ToHex(storedIndexCrc) & ", got " & crc32ToHex(computedIndexCrc) & "): " & path)
  if computedBloomCrc != storedBloomCrc:
    return (false, "Bloom block CRC mismatch (expected " & crc32ToHex(storedBloomCrc) & ", got " & crc32ToHex(computedBloomCrc) & "): " & path)

  return (true, "OK (v3 CRC verified): " & path)

proc loadSSTable*(path: string): SSTable =
  let mf = openMmap(path)
  if mf.regions.len == 0:
    raise newException(IOError, "Cannot mmap SSTable: " & path)
  if mf.totalSize < 40:
    raise newException(ValueError, "SSTable file too small: " & path)

  if mf.readUint32(0) != SSTableMagic:
    raise newException(ValueError, "Invalid SSTable magic")
  let fileVersion = mf.readUint32(4)
  if fileVersion != SSTableVersion and fileVersion != 2'u32 and fileVersion != 1'u32:
    raise newException(ValueError, "Unsupported SSTable version " & $fileVersion)

  let entryCount = int(mf.readUint32(8))
  var level = 0
  var indexOffset = 0
  var bloomOffset = 0
  var footerOffset = 0

  if fileVersion == 3'u32:
    level = int(mf.readUint32(12))
    indexOffset = int(mf.readUint64(16))
    bloomOffset = int(mf.readUint64(24))
    footerOffset = int(mf.readUint64(32))
    # Verify CRC before proceeding
    if footerOffset + SSTableFooterSize <= mf.totalSize:
      let storedDataCrc = mf.readUint32(footerOffset)
      let storedIndexCrc = mf.readUint32(footerOffset + 4)
      let storedBloomCrc = mf.readUint32(footerOffset + 8)
      let headerSize = 40
      let computedDataCrc = crc32(unsafeAddr mf.regions[0].data[headerSize], indexOffset - headerSize)
      let computedIndexCrc = crc32(unsafeAddr mf.regions[0].data[indexOffset], bloomOffset - indexOffset)
      let computedBloomCrc = crc32(unsafeAddr mf.regions[0].data[bloomOffset], footerOffset - bloomOffset)
      if computedDataCrc != storedDataCrc or computedIndexCrc != storedIndexCrc or computedBloomCrc != storedBloomCrc:
        raise newException(ValueError, "SSTable CRC check failed: " & path)
    else:
      raise newException(ValueError, "SSTable footer extends past EOF: " & path)
  elif fileVersion == 2'u32:
    level = int(mf.readUint32(12))
    indexOffset = int(mf.readUint64(16))
    bloomOffset = int(mf.readUint64(24))
  else:
    # Version 1: no level field, defaults to 0
    indexOffset = int(mf.readUint64(12))
    bloomOffset = int(mf.readUint64(20))

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
    id: -1,
    path: path,
    index: idxTable,
    bloom: bloom,
    level: level,
    minKey: minK,
    maxKey: maxK,
    entryCount: entryCount,
    fileVersion: fileVersion,
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
# SSTable Version Migration
# ----------------------------------------------------------------------

proc listLegacySSTables*(dir: string): seq[(string, uint32)] =
  ## Scan sstables directory and return paths of v1/v2 SSTables.
  result = @[]
  let sstDir = dir / "sstables"
  if not dirExists(sstDir):
    return
  for kind, path in walkDir(sstDir):
    if kind == pcFile and path.endsWith(".sst"):
      try:
        let sst = loadSSTable(path)
        if sst.fileVersion < SSTableVersion:
          result.add((path, sst.fileVersion))
      except:
        discard

proc migrateSSTable*(path: string): bool =
  ## Read a legacy SSTable and rewrite it as current version (v3).
  ## The original file is replaced atomically via temp + rename.
  try:
    let sst = loadSSTable(path)
    if sst.fileVersion == SSTableVersion:
      return true  # already current

    # Read all entries
    var entries: seq[Entry] = @[]
    for key, offset in sst.index:
      let (found, entry) = readSSTableEntry(sst, key)
      if found:
        entries.add(entry)

    if entries.len == 0:
      return false

    # Sort by key for writeSSTable
    entries.sort(proc(a, b: Entry): int = cmp(a.key, b.key))

    let tmpPath = path & ".migrate"
    discard writeSSTable(entries, tmpPath, sst.level)

    # Close mmap before replacing
    var mutableSst = sst
    mutableSst.close()

    # Atomic replace
    removeFile(path)
    moveFile(tmpPath, path)
    return true
  except CatchableError as e:
    echo "[ERROR] Failed to migrate ", path, ": ", e.msg
    return false

# ----------------------------------------------------------------------
# MANIFEST — Atomic catalog of active SSTables
# ----------------------------------------------------------------------

proc writeManifest*(db: LSMTree) =
  ## Atomically write MANIFEST file with current SSTable set.
  let manifestPath = db.dir / ManifestFileName
  let tmpPath = manifestPath & ".tmp"

  var j = newJObject()
  j["version"] = newJInt(ManifestVersion)
  j["sequence"] = newJInt(db.manifestSequence)
  j["createdAt"] = newJInt(int64(getTime().toUnix()))

  var sstArr = newJArray()
  for sst in db.sstables:
    var obj = newJObject()
    obj["id"] = newJInt(sst.id)
    obj["path"] = newJString(sst.path)
    obj["level"] = newJInt(sst.level)
    obj["minKey"] = newJString(sst.minKey)
    obj["maxKey"] = newJString(sst.maxKey)
    obj["entryCount"] = newJInt(sst.entryCount)
    sstArr.add(obj)
  j["sstables"] = sstArr

  let content = pretty(j)
  var f: File
  if open(f, tmpPath, fmWrite):
    try:
      f.write(content)
    finally:
      close(f)
    try:
      moveFile(tmpPath, manifestPath)
    except IOError:
      removeFile(tmpPath)
      raise
  else:
    raise newException(IOError, "Cannot write MANIFEST: " & tmpPath)

proc readManifest*(dir: string): (seq[SSTable], int64) =
  ## Read MANIFEST and return (sstables, sequence). If no MANIFEST, returns empty.
  let manifestPath = dir / ManifestFileName
  if not fileExists(manifestPath):
    return (@[], 0'i64)

  let content = readFile(manifestPath)
  if content.len == 0:
    return (@[], 0'i64)

  let j = parseJson(content)
  if j{"version"}.getInt() != ManifestVersion:
    raise newException(ValueError, "Unsupported MANIFEST version")

  var sstables: seq[SSTable] = @[]
  let seqNum = j{"sequence"}.getInt()
  let sstArr = j{"sstables"}
  for node in sstArr:
    let path = node{"path"}.getStr()
    if not fileExists(path):
      continue  # skip missing SSTables
    try:
      var sst = loadSSTable(path)
      sst.id = node{"id"}.getInt()
      sst.level = node{"level"}.getInt()
      sstables.add(sst)
    except CatchableError as e:
      echo "[WARN] MANIFEST references corrupt SSTable: ", path, " — ", e.msg

  return (sstables, int64(seqNum))

proc checkStorageConsistency*(db: LSMTree): seq[string] =
  ## Return list of warnings: orphan files, missing SSTables, etc.
  result = @[]
  let manifestPath = db.dir / ManifestFileName
  var manifestPaths: seq[string] = @[]

  if fileExists(manifestPath):
    try:
      let j = parseJson(readFile(manifestPath))
      for node in j{"sstables"}:
        manifestPaths.add(node{"path"}.getStr())
    except:
      result.add("MANIFEST is corrupt or unreadable")
      return

  # Check for orphan SSTables on disk
  let sstDir = db.dir / "sstables"
  if dirExists(sstDir):
    for kind, path in walkDir(sstDir):
      if kind == pcFile and path.endsWith(".sst"):
        if path notin manifestPaths and manifestPaths.len > 0:
          result.add("Orphan SSTable (not in MANIFEST): " & path)

  # Check for missing SSTables referenced in MANIFEST
  for p in manifestPaths:
    if not fileExists(p):
      result.add("Missing SSTable (in MANIFEST but not on disk): " & p)

# ----------------------------------------------------------------------
# LSMTree API
# ----------------------------------------------------------------------

proc flushUnsafe(db: LSMTree) {.gcsafe.}

proc newLSMTree*(dir: string, memMaxSize: int = DefaultMemTableSize): LSMTree =
  createDir(dir)
  createDir(dir / "sstables")

  var sstables: seq[SSTable] = @[]
  var nextId = 1
  var manifestSeq: int64 = 0

  # Try loading from MANIFEST first
  let manifestPath = dir / ManifestFileName
  if fileExists(manifestPath):
    try:
      let (loaded, seqNum) = readManifest(dir)
      sstables = loaded
      manifestSeq = seqNum
      for sst in sstables:
        nextId = max(nextId, sst.id + 1)
      if sstables.len > 0:
        echo "[INFO] Loaded ", sstables.len, " SSTable(s) from MANIFEST (seq=", manifestSeq, ")"
    except CatchableError as e:
      echo "[WARN] Failed to read MANIFEST: ", e.msg, " — falling back to directory scan"
      sstables.setLen(0)

  # Fallback: directory scan if MANIFEST missing or empty
  if sstables.len == 0:
    for kind, path in walkDir(dir / "sstables"):
      if kind == pcFile and path.endsWith(".sst"):
        try:
          var sst = loadSSTable(path)
          let name = splitFile(path).name
          sst.id = parseInt(name)
          sstables.add(sst)
          nextId = max(nextId, sst.id + 1)
        except CatchableError as e:
          echo "[WARN] Skipping corrupt SSTable: ", path, " — ", e.msg
    sstables.sort(proc(a, b: SSTable): int = cmp(a.id, b.id))
    if sstables.len > 0:
      echo "[INFO] Loaded ", sstables.len, " SSTable(s) from directory scan"

  new(result)
  initLock(result.lock)
  initLock(result.walLock)
  result.dir = dir
  result.memTable = newMemTable(memMaxSize)
  result.immutableMem = newMemTable(0)
  result.sstables = sstables
  result.wal = newWriteAheadLog(dir / "wal")
  result.memMaxSize = memMaxSize
  result.currentSeq = 0
  result.nextSSTableId = nextId
  result.manifestSequence = manifestSeq

  # WAL crash recovery — replay unflushed entries into memTable
  let walPath = dir / "wal" / "wal.log"
  if fileExists(walPath):
    var stream: FileStream = nil
    try:
      stream = newFileStream(walPath, fmRead)
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
                if not result.memTable.put(key, value, timestamp):
                  result.flushUnsafe()
                  if not result.memTable.put(key, value, timestamp):
                    raise newException(IOError, "WAL recovery: failed to insert key into memtable")
              of wekDelete:
                if not result.memTable.put(key, @[], timestamp, deleted = true):
                  result.flushUnsafe()
                  if not result.memTable.put(key, @[], timestamp, deleted = true):
                    raise newException(IOError, "WAL recovery: failed to insert delete tombstone into memtable")
              of wekCommit:
                discard
              of wekCheckpoint:
                discard
    finally:
      if stream != nil:
        stream.close()

proc put*(db: LSMTree, key: string, value: seq[byte]) =
  let ts = uint64(getMonoTime().ticks())
  acquire(db.lock)
  defer: release(db.lock)
  acquire(db.walLock)
  db.wal.writePut(cast[seq[byte]](key), value, ts)
  release(db.walLock)

  if not db.memTable.put(key, value, ts):
    if db.immutableMem.len > 0:
      db.flushUnsafe()
    db.immutableMem = db.memTable
    db.memTable = newMemTable(db.memMaxSize)
    if not db.memTable.put(key, value, ts):
      raise newException(IOError, "LSM put failed after flush")

proc delete*(db: LSMTree, key: string) =
  let ts = uint64(getMonoTime().ticks())
  acquire(db.lock)
  defer: release(db.lock)
  acquire(db.walLock)
  db.wal.writeDelete(cast[seq[byte]](key), ts)
  release(db.walLock)
  if not db.memTable.put(key, @[], ts, deleted = true):
    if db.immutableMem.len > 0:
      db.flushUnsafe()
    db.immutableMem = db.memTable
    db.memTable = newMemTable(db.memMaxSize)
    if not db.memTable.put(key, @[], ts, deleted = true):
      raise newException(IOError, "LSM delete failed after flush")

proc putUnsafe*(db: LSMTree, key: string, value: seq[byte], deleted: bool = false) =
  ## Direct LSM insert without WAL logging — used by recovery.
  let ts = uint64(getMonoTime().ticks())
  acquire(db.lock)
  defer: release(db.lock)
  if not db.memTable.put(key, value, ts, deleted):
    if db.immutableMem.len > 0:
      db.flushUnsafe()
    db.immutableMem = db.memTable
    db.memTable = newMemTable(db.memMaxSize)
    if not db.memTable.put(key, value, ts, deleted):
      raise newException(IOError, "LSM putUnsafe failed after flush")

proc deleteUnsafe*(db: LSMTree, key: string) =
  putUnsafe(db, key, @[], deleted = true)

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
  sst.id = db.nextSSTableId - 1
  db.sstables.add(sst)
  # SSTables are kept in insertion order (newest last) so getUnsafe can search newest-first

  # Update MANIFEST atomically
  inc db.manifestSequence
  try:
    writeManifest(db)
  except CatchableError as e:
    echo "[WARN] Failed to write MANIFEST: ", e.msg

  acquire(db.walLock)
  db.wal.writeCommit(uint64(getMonoTime().ticks()))
  db.wal.maybeRotate()
  db.wal.sync()
  release(db.walLock)

proc flush*(db: LSMTree) =
  acquire(db.lock)
  defer: release(db.lock)
  flushUnsafe(db)

proc checkpoint*(db: LSMTree) =
  ## Create a consistent checkpoint: freeze memtable, flush to SSTable,
  ## rotate WAL, and write MANIFEST. This provides a clean boundary
  ## for online backup without stopping the server.
  acquire(db.lock)

  # Flush any pending immutable memtable first
  if db.immutableMem.len > 0:
    flushUnsafe(db)

  # Freeze current memtable so writes can continue on a new one
  if db.memTable.len > 0:
    db.immutableMem = db.memTable
    db.memTable = newMemTable(db.memMaxSize)

  # Flush the frozen memtable
  if db.immutableMem.len > 0:
    flushUnsafe(db)

  # Rotate WAL for a clean backup boundary
  acquire(db.walLock)
  db.wal.maybeRotate()
  db.wal.sync()
  release(db.walLock)

  release(db.lock)

proc close*(db: LSMTree) =
  acquire(db.lock)
  try:
    # Flush both memtables to avoid data loss
    while db.immutableMem.len > 0:
      flushUnsafe(db)
    flushUnsafe(db)
    for sst in db.sstables.mitems:
      sst.close()
    db.wal.close()
  finally:
    release(db.lock)

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

proc scanAll*(db: LSMTree): seq[(string, seq[byte])] =
  ## Scan all active (non-deleted) entries from memory and SSTables.
  ## Used for shard data migration.
  acquire(db.lock)
  defer: release(db.lock)

  var seen = initTable[string, bool]()

  # Scan memtable first (most recent)
  for e in db.memTable.entries:
    if e.key notin seen:
      seen[e.key] = true
      if not e.deleted:
        result.add((e.key, e.value))

  # Scan immutable memtable
  for e in db.immutableMem.entries:
    if e.key notin seen:
      seen[e.key] = true
      if not e.deleted:
        result.add((e.key, e.value))

  # Scan SSTables from newest to oldest
  for i in countdown(db.sstables.high, db.sstables.low):
    let sst = db.sstables[i]
    for key, offset in sst.index:
      if key notin seen:
        seen[key] = true
        let (found, entry) = readSSTableEntry(sst, key)
        if found and not entry.deleted:
          result.add((entry.key, entry.value))
