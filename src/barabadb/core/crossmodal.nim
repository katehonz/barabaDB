## Cross-Modal Engine — unified query interface across all storage modes
import std/tables
import std/os
import std/sequtils
import ../storage/lsm
import ../vector/engine as vengine
import ../graph/engine as gengine
import ../fts/engine as fts

type
  QueryMode* = enum
    qmDocument  # key-value / JSON documents
    qmVector    # vector similarity search
    qmGraph     # graph traversal
    qmFullText  # full-text search
    qmHybrid    # combine multiple modes

  CrossModalQuery* = object
    mode*: QueryMode
    tableName*: string
    # Document mode
    key*: string
    keyRange*: (string, string)
    # Vector mode
    vector*: seq[float32]
    vectorK*: int
    vectorMetric*: string
    vectorFilter*: proc(meta: Table[string, string]): bool {.gcsafe.}
    # Graph mode
    startNode*: uint64
    traversal*: string  # bfs, dfs, shortest, pagerank
    maxDepth*: int
    edgeLabel*: string
    # FTS mode
    searchQuery*: string
    fuzzyMaxDist*: int
    # Hybrid weights
    docWeight*: float64
    vecWeight*: float64
    ftsWeight*: float64
    graphWeight*: float64

  CrossModalResult* = ref object
    docResults*: seq[(string, seq[byte])]
    vecResults*: seq[(uint64, float64)]
    graphResults*: seq[uint64]
    ftsResults*: seq[uint64]
    hybridScores*: Table[uint64, float64]
    totalResults*: int

  CrossModalEngine* = ref object
    store: LSMTree
    vectorIdx: vengine.HNSWIndex
    graphIdx: gengine.Graph
    ftsIdx: fts.InvertedIndex
    metadata: Table[uint64, Table[string, string]]  # id -> metadata

proc newCrossModalEngine*(dataDir: string): CrossModalEngine =
  CrossModalEngine(
    store: newLSMTree(dataDir / "kv"),
    vectorIdx: vengine.newHNSWIndex(128),
    graphIdx: gengine.newGraph(),
    ftsIdx: fts.newInvertedIndex(),
    metadata: initTable[uint64, Table[string, string]](),
  )

# Document operations
proc put*(engine: CrossModalEngine, key: string, value: seq[byte]) =
  engine.store.put(key, value)

proc get*(engine: CrossModalEngine, key: string): (bool, seq[byte]) =
  engine.store.get(key)

proc delete*(engine: CrossModalEngine, key: string) =
  engine.store.delete(key)

# Vector operations
proc insertVector*(engine: CrossModalEngine, id: uint64, vector: seq[float32],
                   meta: Table[string, string] = initTable[string, string]()) =
  vengine.insert(engine.vectorIdx, id, vector, meta)
  engine.metadata[id] = meta

proc searchVector*(engine: CrossModalEngine, query: seq[float32], k: int = 10,
                   metric: vengine.DistanceMetric = vengine.dmCosine): seq[(uint64, float64)] =
  vengine.search(engine.vectorIdx, query, k, metric)

proc searchVectorFiltered*(engine: CrossModalEngine, query: seq[float32], k: int,
                           filter: proc(meta: Table[string, string]): bool {.gcsafe.}): seq[(uint64, float64)] =
  vengine.searchWithFilter(engine.vectorIdx, query, k, filter)

# Graph operations
proc addNode*(engine: CrossModalEngine, label: string,
              props: Table[string, string] = initTable[string, string]()): uint64 =
  uint64(gengine.addNode(engine.graphIdx, label, props))

proc addEdge*(engine: CrossModalEngine, src, dst: uint64, label: string = "",
              weight: float64 = 1.0): uint64 =
  uint64(gengine.addEdge(engine.graphIdx, NodeId(src), NodeId(dst), label,
                          initTable[string, string](), weight))

proc traverseGraph*(engine: CrossModalEngine, start: uint64,
                    algo: string = "bfs", maxDepth: int = -1): seq[uint64] =
  case algo
  of "bfs":
    let nodes = gengine.bfs(engine.graphIdx, NodeId(start), maxDepth)
    return nodes.mapIt(uint64(it))
  of "dfs":
    let nodes = gengine.dfs(engine.graphIdx, NodeId(start), maxDepth)
    return nodes.mapIt(uint64(it))
  of "shortest":
    # BFS-based shortest (unweighted)
    let nodes = gengine.bfs(engine.graphIdx, NodeId(start), maxDepth)
    return nodes.mapIt(uint64(it))
  else:
    return @[]

proc pageRank*(engine: CrossModalEngine): Table[uint64, float64] =
  let ranks = gengine.pageRank(engine.graphIdx)
  result = initTable[uint64, float64]()
  for nodeId, rank in ranks:
    result[uint64(nodeId)] = rank

# FTS operations
proc indexText*(engine: CrossModalEngine, docId: uint64, text: string) =
  fts.addDocument(engine.ftsIdx, docId, text)

proc searchText*(engine: CrossModalEngine, query: string, limit: int = 10): seq[uint64] =
  let results = fts.search(engine.ftsIdx, query, limit)
  return results.mapIt(it.docId)

proc searchFuzzy*(engine: CrossModalEngine, query: string,
                  maxDist: int = 2, limit: int = 10): seq[uint64] =
  let results = fts.fuzzySearch(engine.ftsIdx, query, maxDist, limit)
  return results.mapIt(it.docId)

# Cross-modal hybrid query
proc hybridSearch*(engine: CrossModalEngine, query: CrossModalQuery): CrossModalResult =
  result = CrossModalResult(
    docResults: @[],
    vecResults: @[],
    graphResults: @[],
    ftsResults: @[],
    hybridScores: initTable[uint64, float64](),
    totalResults: 0,
  )

  var scores = initTable[uint64, float64]()

  # Document mode
  if query.mode in {qmDocument, qmHybrid}:
    if query.key.len > 0:
      let (found, val) = engine.store.get(query.key)
      if found:
        result.docResults.add((query.key, val))

  # Vector mode
  if query.mode in {qmVector, qmHybrid} and query.vector.len > 0:
    let vecResults = if query.vectorFilter != nil:
      engine.searchVectorFiltered(query.vector, query.vectorK, query.vectorFilter)
    else:
      engine.searchVector(query.vector, query.vectorK)
    result.vecResults = vecResults
    for (id, dist) in vecResults:
      let score = query.vecWeight / (1.0 + dist)
      scores[id] = scores.getOrDefault(id, 0.0) + score

  # FTS mode
  if query.mode in {qmFullText, qmHybrid} and query.searchQuery.len > 0:
    let ftsResults = engine.searchText(query.searchQuery, query.vectorK)
    result.ftsResults = ftsResults
    for i, id in ftsResults:
      let score = query.ftsWeight / (1.0 + float64(i))
      scores[id] = scores.getOrDefault(id, 0.0) + score

  # Graph mode
  if query.mode in {qmGraph, qmHybrid} and query.startNode > 0:
    let graphResults = engine.traverseGraph(query.startNode, query.traversal, query.maxDepth)
    result.graphResults = graphResults
    for i, id in graphResults:
      let score = query.graphWeight / (1.0 + float64(i))
      scores[id] = scores.getOrDefault(id, 0.0) + score

  # Sort by hybrid score
  result.hybridScores = scores
  result.totalResults = scores.len

proc newCrossModalQuery*(mode: QueryMode): CrossModalQuery =
  CrossModalQuery(
    mode: mode,
    vectorK: 10,
    vectorMetric: "cosine",
    maxDepth: -1,
    fuzzyMaxDist: 2,
    docWeight: 1.0,
    vecWeight: 1.0,
    ftsWeight: 1.0,
    graphWeight: 1.0,
  )

# 2PC Cross-Modal Transaction
type
  TPCParticipant* = ref object
    name*: string
    prepared*: bool
    committed*: bool
    aborted*: bool
    writeLog*: seq[(string, seq[byte])]

  TPCTransaction* = ref object
    id*: uint64
    participants*: seq[TPCParticipant]
    state*: string  # "active", "prepared", "committed", "aborted"

proc newTPCTransaction*(id: uint64): TPCTransaction =
  TPCTransaction(id: id, participants: @[], state: "active")

proc addParticipant*(txn: TPCTransaction, name: string) =
  txn.participants.add(TPCParticipant(name: name, prepared: false,
                                       committed: false, aborted: false,
                                       writeLog: @[]))

proc prepare*(txn: TPCTransaction): bool =
  if txn.state != "active":
    return false
  for p in txn.participants:
    # In a real system, would send PREPARE to each participant
    p.prepared = true
  txn.state = "prepared"
  return true

proc commit*(txn: TPCTransaction): bool =
  if txn.state != "prepared":
    return false
  for p in txn.participants:
    p.committed = true
  txn.state = "committed"
  return true

proc rollback*(txn: TPCTransaction): bool =
  if txn.state == "active" or txn.state == "prepared":
    for p in txn.participants:
      p.aborted = true
    txn.state = "aborted"
    return true
  return false

proc participantCount*(txn: TPCTransaction): int = txn.participants.len
proc isPrepared*(txn: TPCTransaction): bool = txn.state == "prepared"
proc isCommitted*(txn: TPCTransaction): bool = txn.state == "committed"
proc isAborted*(txn: TPCTransaction): bool = txn.state == "aborted"
