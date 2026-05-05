## SSTable Compaction — size-tiered and leveled strategies
import std/tables
import std/algorithm
import std/os
import std/math

const
  MaxLevel* = 7
  LevelMultiplier* = 10  # each level is 10x the previous

type
  SSTableMeta* = object
    path*: string
    level*: int
    minKey*: string
    maxKey*: string
    entryCount*: int
    sizeBytes*: int
    createdAt*: int64

  CompactionResult* = object
    inputTables*: seq[SSTableMeta]
    outputTables*: seq[SSTableMeta]
    entriesRead*: int
    entriesWritten*: int

  CompactionStrategy* = ref object
    levels*: seq[seq[SSTableMeta]]
    dataDir*: string
    maxSizePerLevel*: seq[int]

proc newCompactionStrategy*(dataDir: string): CompactionStrategy =
  result = CompactionStrategy(
    levels: newSeq[seq[SSTableMeta]](MaxLevel),
    dataDir: dataDir,
    maxSizePerLevel: newSeq[int](MaxLevel),
  )
  for i in 0..<MaxLevel:
    result.levels[i] = @[]
    result.maxSizePerLevel[i] = int(float64(1024 * 1024) * pow(float64(LevelMultiplier), float64(i)))  # 1MB, 10MB, 100MB...

proc addTable*(cs: CompactionStrategy, meta: SSTableMeta) =
  if meta.level < MaxLevel:
    cs.levels[meta.level].add(meta)

proc totalSize*(cs: CompactionStrategy, level: int): int =
  result = 0
  for t in cs.levels[level]:
    result += t.sizeBytes

proc needsCompaction*(cs: CompactionStrategy, level: int): bool =
  if level >= MaxLevel - 1:
    return false
  return cs.totalSize(level) > cs.maxSizePerLevel[level]

proc pickTablesForCompaction*(cs: CompactionStrategy, level: int): seq[SSTableMeta] =
  if cs.levels[level].len == 0:
    return @[]
  # Sort by creation time, pick oldest
  var sorted = cs.levels[level]
  sorted.sort(proc(a, b: SSTableMeta): int = cmp(a.createdAt, b.createdAt))
  let count = min(sorted.len, 4)  # compact up to 4 tables at once
  return sorted[0..<count]

proc compact*(cs: CompactionStrategy, level: int): CompactionResult =
  let tables = cs.pickTablesForCompaction(level)
  if tables.len == 0:
    return CompactionResult()

  var entriesRead = 0
  var allEntries: seq[(string, seq[byte], uint64, bool)] = @[]

  for t in tables:
    entriesRead += t.entryCount
    # In real impl, would read SSTable file and merge
    # For now, simulate the merge

  let outputPath = cs.dataDir / "sstables" / ("level_" & $level & "_" & $tables[0].createdAt & ".sst")
  let outputMeta = SSTableMeta(
    path: outputPath,
    level: level + 1,
    minKey: tables[0].minKey,
    maxKey: tables[^1].maxKey,
    entryCount: entriesRead,
    sizeBytes: entriesRead * 64,  # estimate
    createdAt: tables[^1].createdAt,
  )

  # Remove old tables from level
  var newTables: seq[SSTableMeta] = @[]
  for t in cs.levels[level]:
    var found = false
    for picked in tables:
      if t.path == picked.path:
        found = true
        break
    if not found:
      newTables.add(t)
  cs.levels[level] = newTables

  # Add to next level
  if level + 1 < MaxLevel:
    cs.levels[level + 1].add(outputMeta)

  return CompactionResult(
    inputTables: tables,
    outputTables: @[outputMeta],
    entriesRead: entriesRead,
    entriesWritten: entriesRead,
  )

proc levelCount*(cs: CompactionStrategy): int =
  result = 0
  for level in cs.levels:
    if level.len > 0:
      inc result

proc tableCount*(cs: CompactionStrategy): int =
  result = 0
  for level in cs.levels:
    result += level.len

# Page Cache — LRU cache for SSTable pages
type
  CacheEntry* = ref object
    key*: string
    data*: seq[byte]
    accessCount*: int
    lastAccess*: int64
    dirty*: bool

  PageCache* = ref object
    capacity: int
    pages: Table[string, CacheEntry]
    accessOrder: seq[string]
    hits*: int
    misses*: int

proc newPageCache*(capacity: int = 1000): PageCache =
  PageCache(
    capacity: capacity,
    pages: initTable[string, CacheEntry](),
    accessOrder: @[],
    hits: 0,
    misses: 0,
  )

proc evict*(cache: PageCache) =
  if cache.pages.len >= cache.capacity:
    # Remove least recently used
    if cache.accessOrder.len > 0:
      let oldest = cache.accessOrder[0]
      cache.accessOrder.delete(0)
      cache.pages.del(oldest)

proc put*(cache: PageCache, key: string, data: seq[byte]) =
  if key in cache.pages:
    cache.pages[key].data = data
    cache.pages[key].lastAccess = 0
    # Move to end of access order
    var newOrder: seq[string] = @[]
    for k in cache.accessOrder:
      if k != key:
        newOrder.add(k)
    newOrder.add(key)
    cache.accessOrder = newOrder
  else:
    cache.evict()
    cache.pages[key] = CacheEntry(
      key: key, data: data,
      accessCount: 1, lastAccess: 0, dirty: false,
    )
    cache.accessOrder.add(key)

proc get*(cache: PageCache, key: string): (bool, seq[byte]) =
  if key in cache.pages:
    inc cache.hits
    cache.pages[key].accessCount += 1
    # Move to end
    var newOrder: seq[string] = @[]
    for k in cache.accessOrder:
      if k != key:
        newOrder.add(k)
    newOrder.add(key)
    cache.accessOrder = newOrder
    return (true, cache.pages[key].data)
  inc cache.misses
  return (false, @[])

proc contains*(cache: PageCache, key: string): bool =
  return key in cache.pages

proc hitRate*(cache: PageCache): float64 =
  let total = cache.hits + cache.misses
  if total == 0: return 0.0
  return float64(cache.hits) / float64(total)

proc len*(cache: PageCache): int = cache.pages.len
proc capacity*(cache: PageCache): int = cache.capacity

proc clear*(cache: PageCache) =
  cache.pages.clear()
  cache.accessOrder.setLen(0)
  cache.hits = 0
  cache.misses = 0
