## Vector Engine — HNSW and IVF-PQ indexes for vector similarity search
import std/math
import std/algorithm
import std/random
import std/tables
import std/sets
import std/monotimes
import std/locks

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
    lock*: Lock

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

  NodeDist = tuple[dist: float64, id: uint64]

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

# ----------------------------------------------------------------------
# HNSW Index — Hierarchical Navigable Small World
# ----------------------------------------------------------------------

proc newHNSWIndex*(dimensions: int, m: int = 16, efConstruction: int = 200,
                   metric: DistanceMetric = dmCosine): HNSWIndex =
  var idx = HNSWIndex(
    nodes: initTable[uint64, HNSWNode](),
    entryPoint: 0,
    maxLevel: 0,
    efConstruction: efConstruction,
    m: m,
    maxM: m * 2,
    metric: metric,
    dimensions: dimensions,
  )
  initLock(idx.lock)
  return idx

proc randomLevel(m: int): int =
  ## Geometric distribution: probability of level L is (1/m)^L
  var level = 0
  let p = 1.0 / float64(m)
  while rand(1.0) < p and level < 16:
    inc level
  return level

proc nodeDistCmp(a, b: NodeDist): int = cmp(a.dist, b.dist)

proc searchLayer(idx: HNSWIndex, entryId: uint64, query: Vector, ef: int,
                 level: int, metric: DistanceMetric): seq[NodeDist] =
  ## Greedy beam search at a specific level.
  ## Returns up to `ef` nearest neighbors sorted by distance.
  var visited = initHashSet[uint64]()
  var candidates: seq[NodeDist] = @[]
  var nearest: seq[NodeDist] = @[]

  let entryDist = distance(query, idx.nodes[entryId].vector, metric)
  candidates.add((entryDist, entryId))
  nearest.add((entryDist, entryId))
  visited.incl(entryId)

  while candidates.len > 0:
    # Pop closest candidate
    var bestIdx = 0
    for i in 1..<candidates.len:
      if candidates[i].dist < candidates[bestIdx].dist:
        bestIdx = i
    let current = candidates[bestIdx]
    candidates.del(bestIdx)

    # Stop if current is worse than the ef-th nearest
    if nearest.len >= ef and current.dist > nearest[^1].dist:
      break

    # Explore neighbors at this level
    let node = idx.nodes[current.id]
    if level < node.neighbors.len:
      for neighborId in node.neighbors[level]:
        if neighborId notin visited:
          visited.incl(neighborId)
          let dist = distance(query, idx.nodes[neighborId].vector, metric)
          candidates.add((dist, neighborId))
          nearest.add((dist, neighborId))
          nearest.sort(nodeDistCmp)
          if nearest.len > ef:
            nearest.setLen(ef)

  return nearest

proc selectNeighbors(idx: HNSWIndex, baseVector: Vector, candidates: seq[NodeDist],
                     maxNeighbors: int, metric: DistanceMetric): seq[uint64] =
  ## Keep only the closest `maxNeighbors` candidates.
  var sorted = candidates
  sorted.sort(nodeDistCmp)
  let n = min(maxNeighbors, sorted.len)
  result = newSeq[uint64](n)
  for i in 0..<n:
    result[i] = sorted[i].id

proc addBidirectionalLink(idx: HNSWIndex, nodeId, neighborId: uint64, level: int) =
  ## Add a bidirectional link between two nodes at the given level,
  ## pruning if the neighbor list exceeds maxM.
  let node = idx.nodes[nodeId]
  let neighbor = idx.nodes[neighborId]
  if level >= node.neighbors.len or level >= neighbor.neighbors.len:
    return

  # Add forward link
  if neighborId notin node.neighbors[level]:
    node.neighbors[level].add(neighborId)

  # Add backward link
  if nodeId notin neighbor.neighbors[level]:
    neighbor.neighbors[level].add(nodeId)

  # Prune neighbor's connections if too many
  if neighbor.neighbors[level].len > idx.maxM:
    var dists: seq[(float64, uint64)] = @[]
    for nid in neighbor.neighbors[level]:
      dists.add((distance(neighbor.vector, idx.nodes[nid].vector, idx.metric), nid))
    dists.sort(proc(a, b: (float64, uint64)): int = cmp(a[0], b[0]))
    neighbor.neighbors[level].setLen(idx.maxM)
    for i in 0..<idx.maxM:
      neighbor.neighbors[level][i] = dists[i][1]

proc insert*(idx: HNSWIndex, id: uint64, vector: Vector,
             metadata: Table[string, string] = initTable[string, string]()) =
  acquire(idx.lock)
  defer: release(idx.lock)
  let level = randomLevel(idx.m)
  let node = HNSWNode(id: id, vector: vector, metadata: metadata,
                      neighbors: newSeq[seq[uint64]](level + 1))
  for i in 0..level:
    node.neighbors[i] = @[]
  idx.nodes[id] = node

  if idx.entryPoint == 0:
    idx.entryPoint = id
    idx.maxLevel = level
    return

  # Find entry point for each level from maxLevel down to level+1
  var currEntry = idx.entryPoint
  for lc in countdown(idx.maxLevel, level + 1):
    let nearest = searchLayer(idx, currEntry, vector, 1, lc, idx.metric)
    if nearest.len > 0:
      currEntry = nearest[0].id

  # For each level from min(level, maxLevel) down to 0, find neighbors and link
  let topLevel = min(level, idx.maxLevel)
  for lc in countdown(topLevel, 0):
    let nearest = searchLayer(idx, currEntry, vector, idx.efConstruction, lc, idx.metric)
    let neighbors = selectNeighbors(idx, vector, nearest, idx.m, idx.metric)
    for neighborId in neighbors:
      addBidirectionalLink(idx, id, neighborId, lc)
    if nearest.len > 0:
      currEntry = nearest[0].id

  # Update entry point if new node has higher level
  if level > idx.maxLevel:
    idx.entryPoint = id
    idx.maxLevel = level

proc search*(idx: HNSWIndex, query: Vector, k: int,
             metric: DistanceMetric = dmCosine): seq[(uint64, float64)] =
  acquire(idx.lock)
  defer: release(idx.lock)
  if idx.nodes.len == 0:
    return @[]

  var currEntry = idx.entryPoint

  # Descend from top level to level 1
  for lc in countdown(idx.maxLevel, 1):
    let nearest = searchLayer(idx, currEntry, query, 1, lc, metric)
    if nearest.len > 0:
      currEntry = nearest[0].id

  # Search at level 0 with ef = max(k * 2, idx.efConstruction)
  let ef = max(k * 2, idx.efConstruction)
  let nearest = searchLayer(idx, currEntry, query, ef, 0, metric)

  let n = min(k, nearest.len)
  result = newSeq[(uint64, float64)](n)
  for i in 0..<n:
    result[i] = (nearest[i].id, nearest[i].dist)

proc searchWithFilter*(idx: HNSWIndex, query: Vector, k: int,
                       filter: proc(metadata: Table[string, string]): bool {.gcsafe.},
                       metric: DistanceMetric = dmCosine): seq[(uint64, float64)] =
  acquire(idx.lock)
  defer: release(idx.lock)
  if idx.nodes.len == 0:
    return @[]

  var currEntry = idx.entryPoint
  for lc in countdown(idx.maxLevel, 1):
    let nearest = searchLayer(idx, currEntry, query, 1, lc, metric)
    if nearest.len > 0:
      currEntry = nearest[0].id

  # Use larger ef to compensate for filtering
  let ef = max(k * 10, idx.efConstruction)
  let nearest = searchLayer(idx, currEntry, query, ef, 0, metric)

  var filtered: seq[(uint64, float64)] = @[]
  for (dist, id) in nearest:
    if filter(idx.nodes[id].metadata):
      filtered.add((id, dist))
      if filtered.len >= k:
        break

  return filtered

# ----------------------------------------------------------------------
# IVF-PQ Index (unchanged)
# ----------------------------------------------------------------------

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

# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------

proc len*(idx: HNSWIndex): int = idx.nodes.len

proc clear*(idx: HNSWIndex) =
  idx.nodes.clear()
  idx.entryPoint = 0
  idx.maxLevel = 0

proc clear*(idx: IVFPQIndex) =
  for i in 0..<idx.nClusters:
    idx.clusters[i].entries.setLen(0)

proc batchInsert*(idx: HNSWIndex, batch: seq[(uint64, Vector)],
                  metadata: seq[Table[string, string]] = @[]) =
  for i, (id, vec) in batch:
    var meta = initTable[string, string]()
    if i < metadata.len:
      meta = metadata[i]
    idx.insert(id, vec, meta)

proc batchInsert*(idx: IVFPQIndex, batch: seq[(uint64, Vector)]) =
  var entries: seq[VectorEntry] = @[]
  for (id, vec) in batch:
    entries.add(VectorEntry(id: id, vector: vec, metadata: @[]))
  idx.train(entries, nIterations = 5)

proc batchSearch*(idx: HNSWIndex, queries: seq[Vector], k: int,
                  metric: DistanceMetric = dmCosine): seq[seq[(uint64, float64)]] =
  result = newSeq[seq[(uint64, float64)]](queries.len)
  for i, query in queries:
    result[i] = idx.search(query, k, metric)

# Auto-rebuild index when threshold exceeded
type
  RebuildConfig* = object
    maxUnindexedCount*: int
    checkInterval*: int64
    rebuildThreshold*: float64
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
    checkInterval: 60_000_000_000,
    rebuildThreshold: 0.1,
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
