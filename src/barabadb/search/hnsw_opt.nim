import std/tables
import std/sets
import std/locks
import std/math
import std/random
import std/algorithm

import ../vector/engine
import priority_queue

proc randomLevelOpt(m: int): int =
  var level = 0
  let p = 1.0 / float64(m)
  while rand(1.0) < p and level < 16:
    inc level
  return level

proc selectNeighborsOpt(candidates: seq[NodeDist], maxN: int): seq[uint64] =
  var sorted = candidates
  sorted.sort(proc(a, b: NodeDist): int = cmp(a.dist, b.dist))
  let n = min(maxN, sorted.len)
  result = newSeq[uint64](n)
  for i in 0..<n:
    result[i] = sorted[i].id

proc addBidirectionalLinkOpt(idx: HNSWIndex, nodeId, neighborId: uint64, level: int) =
  let node = idx.nodes[nodeId]
  let neighbor = idx.nodes[neighborId]
  if level >= node.neighbors.len or level >= neighbor.neighbors.len:
    return
  if neighborId notin node.neighbors[level]:
    node.neighbors[level].add(neighborId)
  if nodeId notin neighbor.neighbors[level]:
    neighbor.neighbors[level].add(nodeId)
  if neighbor.neighbors[level].len > idx.maxM:
    var dists: seq[(float64, uint64)] = @[]
    for nid in neighbor.neighbors[level]:
      dists.add((distance(neighbor.vector, idx.nodes[nid].vector, idx.metric), nid))
    dists.sort(proc(a, b: (float64, uint64)): int = cmp(a[0], b[0]))
    neighbor.neighbors[level].setLen(idx.maxM)
    for i in 0..<idx.maxM:
      neighbor.neighbors[level][i] = dists[i][1]

proc searchLayerOpt*(idx: HNSWIndex, entryId: uint64, query: Vector, ef: int,
                     level: int, metric: DistanceMetric): seq[NodeDist] =
  var visited = initHashSet[uint64]()

  let candidates = newBoundedHeap[float64, uint64](0,
    proc(a, b: float64): bool = a < b)
  let nearest = newBoundedHeap[float64, uint64](ef,
    proc(a, b: float64): bool = a > b)

  let entryDist = distance(query, idx.nodes[entryId].vector, metric)
  candidates.push(entryDist, entryId)
  nearest.push(entryDist, entryId)
  visited.incl(entryId)

  while not candidates.isEmpty:
    let closest = candidates.pop()
    if nearest.len >= ef and closest.key > nearest.peek().key:
      break

    let node = idx.nodes[closest.value]
    if level < node.neighbors.len:
      for neighborId in node.neighbors[level]:
        if neighborId notin visited:
          visited.incl(neighborId)
          let dist = distance(query, idx.nodes[neighborId].vector, metric)
          if nearest.len < ef or dist < nearest.peek().key:
            candidates.push(dist, neighborId)
            nearest.push(dist, neighborId)

  result = newSeqOfCap[NodeDist](nearest.len)
  for entry in nearest.items():
    result.add((entry.key, entry.value))
  result.sort(proc(a, b: NodeDist): int = cmp(a.dist, b.dist))

proc searchOpt*(idx: HNSWIndex, query: Vector, k: int,
                metric: DistanceMetric = dmCosine): seq[(uint64, float64)] =
  acquire(idx.lock)
  defer: release(idx.lock)
  if idx.nodes.len == 0:
    return @[]

  var currEntry = idx.entryPoint
  for lc in countdown(idx.maxLevel, 1):
    let nearest = searchLayerOpt(idx, currEntry, query, 1, lc, metric)
    if nearest.len > 0:
      currEntry = nearest[0].id

  let ef = max(k * 2, idx.efConstruction)
  let nearest = searchLayerOpt(idx, currEntry, query, ef, 0, metric)

  let n = min(k, nearest.len)
  result = newSeq[(uint64, float64)](n)
  for i in 0..<n:
    result[i] = (nearest[i].id, nearest[i].dist)

proc searchExOpt*(idx: HNSWIndex, query: Vector, k: int,
                  metric: DistanceMetric = dmCosine): seq[(uint64, float64, Table[string, string])] =
  acquire(idx.lock)
  defer: release(idx.lock)
  if idx.nodes.len == 0:
    return @[]

  var currEntry = idx.entryPoint
  for lc in countdown(idx.maxLevel, 1):
    let nearest = searchLayerOpt(idx, currEntry, query, 1, lc, metric)
    if nearest.len > 0:
      currEntry = nearest[0].id

  let ef = max(k * 2, idx.efConstruction)
  let nearest = searchLayerOpt(idx, currEntry, query, ef, 0, metric)

  let n = min(k, nearest.len)
  result = newSeq[(uint64, float64, Table[string, string])](n)
  for i in 0..<n:
    let nodeId = nearest[i].id
    var meta = initTable[string, string]()
    if nodeId in idx.nodes:
      meta = idx.nodes[nodeId].metadata
    result[i] = (nodeId, nearest[i].dist, meta)

proc searchWithFilterOpt*(idx: HNSWIndex, query: Vector, k: int,
                          filter: proc(metadata: Table[string, string]): bool {.gcsafe.},
                          metric: DistanceMetric = dmCosine): seq[(uint64, float64)] =
  acquire(idx.lock)
  defer: release(idx.lock)
  if idx.nodes.len == 0:
    return @[]

  var currEntry = idx.entryPoint
  for lc in countdown(idx.maxLevel, 1):
    let nearest = searchLayerOpt(idx, currEntry, query, 1, lc, metric)
    if nearest.len > 0:
      currEntry = nearest[0].id

  let maxEf = max(k * 64, idx.efConstruction * 4)
  var ef = k

  while ef <= maxEf:
    let nearest = searchLayerOpt(idx, currEntry, query, ef, 0, metric)
    var filtered: seq[(uint64, float64)] = @[]
    for nd in nearest:
      if nd.id in idx.nodes and filter(idx.nodes[nd.id].metadata):
        filtered.add((nd.id, nd.dist))
    if filtered.len >= k:
      return filtered[0..<k]
    if nearest.len > 0:
      currEntry = nearest[0].id
    ef = ef * 2

  let nearest = searchLayerOpt(idx, currEntry, query, maxEf, 0, metric)
  var filtered: seq[(uint64, float64)] = @[]
  for nd in nearest:
    if nd.id in idx.nodes and filter(idx.nodes[nd.id].metadata):
      filtered.add((nd.id, nd.dist))
  if filtered.len > k:
    filtered.setLen(k)
  return filtered

proc insertOpt*(idx: HNSWIndex, id: uint64, vector: Vector,
                metadata: Table[string, string] = initTable[string, string]()) =
  acquire(idx.lock)
  defer: release(idx.lock)
  let level = randomLevelOpt(idx.m)
  let node = HNSWNode(id: id, vector: vector, metadata: metadata,
                      neighbors: newSeq[seq[uint64]](level + 1))
  for i in 0..level:
    node.neighbors[i] = @[]
  idx.nodes[id] = node

  if idx.entryPoint == 0:
    idx.entryPoint = id
    idx.maxLevel = level
    return

  var currEntry = idx.entryPoint
  for lc in countdown(idx.maxLevel, level + 1):
    let nearest = searchLayerOpt(idx, currEntry, vector, 1, lc, idx.metric)
    if nearest.len > 0:
      currEntry = nearest[0].id

  let topLevel = min(level, idx.maxLevel)
  for lc in countdown(topLevel, 0):
    let nearest = searchLayerOpt(idx, currEntry, vector, idx.efConstruction, lc, idx.metric)
    let neighbors = selectNeighborsOpt(nearest, idx.m)
    for neighborId in neighbors:
      addBidirectionalLinkOpt(idx, id, neighborId, lc)
    if nearest.len > 0:
      currEntry = nearest[0].id

  if level > idx.maxLevel:
    idx.entryPoint = id
    idx.maxLevel = level
