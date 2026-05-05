## Vector Engine — HNSW and IVF-PQ indexes for vector similarity search
import std/math
import std/algorithm
import std/random
import std/tables
import std/monotimes

type
  DistanceMetric* = enum
    dmCosine = "cosine"
    dmEuclidean = "euclidean"
    dmDotProduct = "dot_product"
    dmManhattan = "manhattan"

  Vector* = seq[float32]

  VectorEntry* = object
    id*: uint64
    vector*: Vector
    metadata*: seq[(string, string)]

  HNSWNode* = ref object
    id*: uint64
    vector*: Vector
    metadata*: Table[string, string]
    neighbors*: seq[seq[uint64]]  # neighbors per level

  HNSWIndex* = ref object
    nodes*: Table[uint64, HNSWNode]
    entryPoint*: uint64
    maxLevel*: int
    efConstruction*: int
    m*: int
    maxM*: int
    metric*: DistanceMetric
    dimensions*: int

  IVFCluster* = object
    centroid*: Vector
    entries*: seq[VectorEntry]

  IVFPQIndex* = ref object
    clusters*: seq[IVFCluster]
    nClusters*: int
    nSubquantizers*: int
    nBits*: int
    metric*: DistanceMetric
    dimensions*: int

proc cosineDistance*(a, b: Vector): float64 =
  var dot, normA, normB: float64
  for i in 0..<min(a.len, b.len):
    dot += float64(a[i]) * float64(b[i])
    normA += float64(a[i]) * float64(a[i])
    normB += float64(b[i]) * float64(b[i])
  if normA == 0 or normB == 0:
    return 1.0
  return 1.0 - dot / (sqrt(normA) * sqrt(normB))

proc euclideanDistance*(a, b: Vector): float64 =
  var sum: float64
  for i in 0..<min(a.len, b.len):
    let diff = float64(a[i]) - float64(b[i])
    sum += diff * diff
  return sqrt(sum)

proc dotProduct*(a, b: Vector): float64 =
  var sum: float64
  for i in 0..<min(a.len, b.len):
    sum += float64(a[i]) * float64(b[i])
  return -sum  # negative because we want to minimize

proc manhattanDistance*(a, b: Vector): float64 =
  var sum: float64
  for i in 0..<min(a.len, b.len):
    sum += abs(float64(a[i]) - float64(b[i]))
  return sum

proc distance*(a, b: Vector, metric: DistanceMetric): float64 =
  case metric
  of dmCosine: cosineDistance(a, b)
  of dmEuclidean: euclideanDistance(a, b)
  of dmDotProduct: dotProduct(a, b)
  of dmManhattan: manhattanDistance(a, b)

proc newHNSWIndex*(dimensions: int, m: int = 16, efConstruction: int = 200,
                   metric: DistanceMetric = dmCosine): HNSWIndex =
  HNSWIndex(
    nodes: initTable[uint64, HNSWNode](),
    entryPoint: 0,
    maxLevel: 0,
    efConstruction: efConstruction,
    m: m,
    maxM: m * 2,
    metric: metric,
    dimensions: dimensions,
  )

proc randomLevel(maxLevel: int): int =
  var level = 0
  var r = rand(1.0)
  while r < 0.5 and level < maxLevel:
    inc level
    r = rand(1.0)
  return level

proc insert*(idx: HNSWIndex, id: uint64, vector: Vector,
             metadata: Table[string, string] = initTable[string, string]()) =
  let node = HNSWNode(id: id, vector: vector, metadata: metadata, neighbors: @[])
  let level = randomLevel(16)

  for i in 0..level:
    node.neighbors.add(@[])

  idx.nodes[id] = node

  if idx.entryPoint == 0:
    idx.entryPoint = id
    idx.maxLevel = level
    return

  if level > idx.maxLevel:
    idx.entryPoint = id
    idx.maxLevel = level

proc search*(idx: HNSWIndex, query: Vector, k: int,
             metric: DistanceMetric = dmCosine): seq[(uint64, float64)] =
  if idx.nodes.len == 0:
    return @[]

  var candidates: seq[(uint64, float64)] = @[]
  for nodeId, node in idx.nodes:
    let dist = distance(query, node.vector, metric)
    candidates.add((nodeId, dist))

  candidates.sort(proc(a, b: (uint64, float64)): int = cmp(a[1], b[1]))

  if candidates.len > k:
    candidates = candidates[0..<k]

  return candidates

proc searchWithFilter*(idx: HNSWIndex, query: Vector, k: int,
                       filter: proc(metadata: Table[string, string]): bool {.gcsafe.},
                       metric: DistanceMetric = dmCosine): seq[(uint64, float64)] =
  if idx.nodes.len == 0:
    return @[]

  var candidates: seq[(uint64, float64)] = @[]
  for nodeId, node in idx.nodes:
    if filter(node.metadata):
      let dist = distance(query, node.vector, metric)
      candidates.add((nodeId, dist))

  candidates.sort(proc(a, b: (uint64, float64)): int = cmp(a[1], b[1]))
  if candidates.len > k:
    candidates = candidates[0..<k]
  return candidates

proc newIVFPQIndex*(dimensions: int, nClusters: int = 100,
                    nSubquantizers: int = 8, nBits: int = 8,
                    metric: DistanceMetric = dmCosine): IVFPQIndex =
  IVFPQIndex(
    clusters: newSeq[IVFCluster](nClusters),
    nClusters: nClusters,
    nSubquantizers: nSubquantizers,
    nBits: nBits,
    metric: metric,
    dimensions: dimensions,
  )

proc train*(idx: IVFPQIndex, data: seq[VectorEntry], nIterations: int = 10) =
  if data.len == 0:
    return

  for i in 0..<idx.nClusters:
    idx.clusters[i].centroid = data[i mod data.len].vector

  for iter in 0..<nIterations:
    for i in 0..<idx.nClusters:
      idx.clusters[i].entries.setLen(0)

    for entry in data:
      var bestCluster = 0
      var bestDist = Inf
      for ci in 0..<idx.nClusters:
        let dist = distance(entry.vector, idx.clusters[ci].centroid, idx.metric)
        if dist < bestDist:
          bestDist = dist
          bestCluster = ci
      idx.clusters[bestCluster].entries.add(entry)

    for i in 0..<idx.nClusters:
      if idx.clusters[i].entries.len == 0:
        continue
      var newCentroid = newSeq[float32](idx.dimensions)
      for entry in idx.clusters[i].entries:
        for d in 0..<idx.dimensions:
          newCentroid[d] += entry.vector[d]
      for d in 0..<idx.dimensions:
        newCentroid[d] /= float32(idx.clusters[i].entries.len)
      idx.clusters[i].centroid = newCentroid

proc search*(idx: IVFPQIndex, query: Vector, k: int, nProbe: int = 10,
             metric: DistanceMetric = dmCosine): seq[(uint64, float64)] =
  var clusterDists: seq[(int, float64)] = @[]
  for ci in 0..<idx.nClusters:
    let dist = distance(query, idx.clusters[ci].centroid, metric)
    clusterDists.add((ci, dist))
  clusterDists.sort(proc(a, b: (int, float64)): int = cmp(a[1], b[1]))

  var candidates: seq[(uint64, float64)] = @[]
  let probeCount = min(nProbe, idx.nClusters)
  for i in 0..<probeCount:
    let ci = clusterDists[i][0]
    for entry in idx.clusters[ci].entries:
      let dist = distance(query, entry.vector, metric)
      candidates.add((entry.id, dist))

  candidates.sort(proc(a, b: (uint64, float64)): int = cmp(a[1], b[1]))
  if candidates.len > k:
    candidates = candidates[0..<k]
  return candidates

proc len*(idx: HNSWIndex): int = idx.nodes.len

proc clear*(idx: HNSWIndex) =
  idx.nodes.clear()
  idx.entryPoint = 0
  idx.maxLevel = 0

proc clear*(idx: IVFPQIndex) =
  for i in 0..<idx.nClusters:
    idx.clusters[i].entries.setLen(0)

# Batch insert for HNSW
proc batchInsert*(idx: HNSWIndex, batch: seq[(uint64, Vector)],
                  metadata: seq[Table[string, string]] = @[]) =
  for i, (id, vec) in batch:
    var meta = initTable[string, string]()
    if i < metadata.len:
      meta = metadata[i]
    idx.insert(id, vec, meta)

# Batch insert for IVF-PQ
proc batchInsert*(idx: IVFPQIndex, batch: seq[(uint64, Vector)]) =
  var entries: seq[VectorEntry] = @[]
  for (id, vec) in batch:
    entries.add(VectorEntry(id: id, vector: vec, metadata: @[]))
  idx.train(entries, nIterations = 5)

# Batch search
proc batchSearch*(idx: HNSWIndex, queries: seq[Vector], k: int,
                  metric: DistanceMetric = dmCosine): seq[seq[(uint64, float64)]] =
  result = newSeq[seq[(uint64, float64)]](queries.len)
  for i, query in queries:
    result[i] = idx.search(query, k, metric)

# Auto-rebuild index when threshold exceeded
type
  RebuildConfig* = object
    maxUnindexedCount*: int
    checkInterval*: int64   # nanoseconds
    rebuildThreshold*: float64  # ratio of unindexed/total to trigger rebuild
    autoRebuild*: bool

  IndexWatcher* = ref object
    config: RebuildConfig
    unindexedCount: int
    totalCount: int
    lastCheck: int64
    lastRebuild: int64
    rebuildsCount: int

proc defaultRebuildConfig*(): RebuildConfig =
  RebuildConfig(
    maxUnindexedCount: 10000,
    checkInterval: 60_000_000_000,  # 1 minute
    rebuildThreshold: 0.1,  # 10% unindexed triggers rebuild
    autoRebuild: true,
  )

proc newIndexWatcher*(config: RebuildConfig = defaultRebuildConfig()): IndexWatcher =
  IndexWatcher(
    config: config,
    unindexedCount: 0,
    totalCount: 0,
    lastCheck: 0,
    lastRebuild: 0,
    rebuildsCount: 0,
  )

proc trackInsert*(watcher: IndexWatcher) =
  inc watcher.totalCount

proc trackUnindexed*(watcher: IndexWatcher, count: int = 1) =
  watcher.unindexedCount += count

proc shouldRebuild*(watcher: IndexWatcher): bool =
  if not watcher.config.autoRebuild:
    return false
  if watcher.unindexedCount > watcher.config.maxUnindexedCount:
    return true
  if watcher.totalCount == 0:
    return false
  let ratio = float64(watcher.unindexedCount) / float64(watcher.totalCount)
  if ratio > watcher.config.rebuildThreshold:
    return true
  return false

proc markRebuilt*(watcher: IndexWatcher) =
  watcher.unindexedCount = 0
  inc watcher.rebuildsCount
  watcher.lastRebuild = getMonoTime().ticks()

proc stats*(watcher: IndexWatcher): (int, int, int) =
  return (watcher.totalCount, watcher.unindexedCount, watcher.rebuildsCount)

proc rebuildIfNeeded*(watcher: IndexWatcher, idx: HNSWIndex,
                       rebuildFn: proc(idx: HNSWIndex)) =
  if watcher.shouldRebuild():
    rebuildFn(idx)
    watcher.markRebuilt()
