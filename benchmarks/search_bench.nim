## BaraDB Search Benchmarks — HNSW recall, FTS performance, scalability
import std/monotimes
import std/times
import std/random
import std/strutils
import std/tables
import std/sets
import std/math
import std/algorithm
import ../src/barabadb/vector/engine as vengine
import ../src/barabadb/fts/engine as fts
import ../src/barabadb/search/hnsw_opt

type
  LatencyStats = tuple[avg, p50, p95, p99: float64]

const sampleDocs = [
  "The quick brown fox jumps over the lazy dog near the river bank",
  "Database indexing strategies include B-trees hash indexes and inverted indexes",
  "Vector similarity search uses approximate nearest neighbor algorithms like HNSW",
  "Full text search engines use inverted indexes with BM25 ranking",
  "Natural language processing requires tokenization stemming and embedding",
  "Machine learning models transform raw data into meaningful insights",
  "Distributed systems handle network partitions and consistency tradeoffs",
  "Graph databases traverse relationships between connected entities efficiently",
  "Time series databases optimize for sequential write patterns",
  "Columnar storage accelerates analytical queries across large datasets",
  "Query optimization involves cost-based planning and execution strategies",
  "Memory management uses reference counting for deterministic cleanup",
  "Concurrent data structures enable lock-free parallel processing",
  "Cryptographic hashing provides integrity verification for stored data",
  "Replication strategies ensure high availability across multiple nodes",
  "Sharding distributes data based on consistent hashing algorithms",
  "ACID transactions guarantee atomicity consistency isolation durability",
  "Event sourcing captures state changes as immutable sequence of events",
  "Microservices architecture decomposes applications into independent services",
  "API design principles emphasize simplicity consistency and discoverability",
]

proc elapsed(start: MonoTime): float64 =
  let ns = float64((getMonoTime() - start).inNanoseconds)
  return ns / 1_000_000_000.0

proc percentile(values: seq[float64], p: int): float64 =
  if values.len == 0: return 0.0
  var sorted = values
  sorted.sort()
  let idx = (p * sorted.len) div 100
  if idx >= sorted.len: return sorted[^1]
  return sorted[idx]

proc latencyStats(latencies: seq[float64]): LatencyStats =
  if latencies.len == 0:
    return (0.0, 0.0, 0.0, 0.0)
  var sum = 0.0
  for v in latencies: sum += v
  result.avg = sum / float64(latencies.len)
  result.p50 = percentile(latencies, 50)
  result.p95 = percentile(latencies, 95)
  result.p99 = percentile(latencies, 99)

proc formatMs(ms: float64): string =
  if ms < 0.01:
    return ms.formatFloat(ffDecimal, 4) & "ms"
  return ms.formatFloat(ffDecimal, 2) & "ms"

proc formatOps(ops: int, secs: float64): string =
  let rate = float64(ops) / secs
  if rate > 1_000_000:
    return $(rate / 1_000_000).formatFloat(ffDecimal, 1) & "M ops/s"
  elif rate > 1_000:
    return $(rate / 1_000).formatFloat(ffDecimal, 1) & "K ops/s"
  else:
    return $rate.formatFloat(ffDecimal, 1) & " ops/s"

proc computeGroundTruth(query: Vector, vectors: seq[(uint64, Vector)], k: int): seq[(uint64, float64)] =
  var dists: seq[(float64, uint64)] = @[]
  for (id, vec) in vectors:
    let dist = cosineDistance(query, vec)
    dists.add((dist, id))
  dists.sort(proc(a, b: (float64, uint64)): int = cmp(a[0], b[0]))
  let n = min(k, dists.len)
  result = newSeq[(uint64, float64)](n)
  for i in 0..<n:
    result[i] = (dists[i][1], dists[i][0])

proc computeRecall(groundTruth: seq[(uint64, float64)], hnswResults: seq[(uint64, float64)], k: int): float64 =
  if groundTruth.len == 0: return 0.0
  var gtIds = initHashSet[uint64]()
  for (id, _) in groundTruth:
    gtIds.incl(id)
  var hits = 0
  for (id, _) in hnswResults:
    if id in gtIds: inc hits
  return float64(hits) / float64(groundTruth.len)

proc benchHnswRecall(n: int, dim: int, kValues: seq[int]) =
  echo ""
  echo "=== HNSW Recall@k ==="
  echo "  Dataset: ", $n, " vectors, dim=", dim

  randomize(42)
  var idx = newHNSWIndex(dim)
  var vectors: seq[(uint64, Vector)] = @[]

  for i in 0..<n:
    var vec = newSeq[float32](dim)
    for d in 0..<dim:
      vec[d] = rand(1.0)
    idx.insert(uint64(i), vec)
    vectors.add((uint64(i), vec))

  let queryCount = 100
  var queries: seq[Vector] = @[]
  for i in 0..<queryCount:
    var vec = newSeq[float32](dim)
    for d in 0..<dim:
      vec[d] = rand(1.0)
    queries.add(vec)

  for k in kValues:
    var totalRecall = 0.0
    var latencies: seq[float64] = @[]

    for query in queries:
      let start = getMonoTime()
      let hnswResults = searchOpt(idx, query, k)
      let elap = (getMonoTime() - start).inNanoseconds.float64 / 1_000_000.0
      latencies.add(elap)

      let gt = computeGroundTruth(query, vectors, k)
      let recall = computeRecall(gt, hnswResults, k)
      totalRecall += recall

    let avgRecall = totalRecall / float64(queryCount)
    let stats = latencyStats(latencies)
    echo "  recall@", k, ": ", (avgRecall * 100).formatFloat(ffDecimal, 1), "%  (avg ", formatMs(stats.avg), ")"

proc benchScalability =
  echo ""
  echo "=== HNSW Scalability ==="
  let sizes = [1000, 5000, 10000, 50000, 100000]
  let dim = 128

  for n in sizes:
    randomize(42)
    let efC = if n <= 10000: 200 elif n <= 50000: 200 else: 200
    var idx = newHNSWIndex(dim, m = 16, efConstruction = efC)
    var vectors: seq[(uint64, Vector)] = @[]

    let insertStart = getMonoTime()
    for i in 0..<n:
      var vec = newSeq[float32](dim)
      for d in 0..<dim:
        vec[d] = rand(1.0)
      insertOpt(idx, uint64(i), vec)
      vectors.add((uint64(i), vec))
    let insertTime = elapsed(insertStart)

    let queryCount = if n <= 10000: 50 elif n <= 50000: 20 else: 10
    var queries: seq[Vector] = @[]
    for i in 0..<queryCount:
      var vec = newSeq[float32](dim)
      for d in 0..<dim:
        vec[d] = rand(1.0)
      queries.add(vec)

    var latencies: seq[float64] = @[]
    var totalRecall = 0.0

    for query in queries:
      let start = getMonoTime()
      let hnswResults = searchOpt(idx, query, 10)
      let elap = (getMonoTime() - start).inNanoseconds.float64 / 1_000_000.0
      latencies.add(elap)

      let gt = computeGroundTruth(query, vectors, 10)
      let recall = computeRecall(gt, hnswResults, 10)
      totalRecall += recall

    let avgRecall = totalRecall / float64(queryCount)
    let stats = latencyStats(latencies)

    echo "  N=", $n, ":   insert=", insertTime.formatFloat(ffDecimal, 2), "s  search=", formatMs(stats.avg), "  recall@10=", (avgRecall * 100).formatFloat(ffDecimal, 1), "%"

proc phraseSearch(idx: fts.InvertedIndex, phrase: string): seq[fts.SearchResult] =
  let tokens = fts.tokenize(phrase)
  if tokens.len == 0: return @[]

  var docCounts = initTable[uint64, int]()
  for token in tokens:
    if token in idx.postings:
      for entry in idx.postings[token]:
        if entry.docId notin docCounts:
          docCounts[entry.docId] = 0
        inc docCounts[entry.docId]

  var candidates: seq[uint64] = @[]
  for docId, count in docCounts:
    if count == tokens.len:
      candidates.add(docId)

  result = @[]
  for docId in candidates:
    var positions: seq[seq[int]] = @[]
    for token in tokens:
      if token in idx.postings:
        for entry in idx.postings[token]:
          if entry.docId == docId:
            positions.add(entry.positions)
            break

    if positions.len == tokens.len:
      var found = false
      if positions[0].len > 0:
        for startPos in positions[0]:
          var match = true
          for i in 1..<positions.len:
            if (startPos + i) notin positions[i]:
              match = false
              break
          if match:
            found = true
            break
      if found:
        result.add(fts.SearchResult(docId: docId, score: 1.0, highlights: @[]))

proc booleanAndSearch(idx: fts.InvertedIndex, terms: seq[string]): seq[fts.SearchResult] =
  var docCounts = initTable[uint64, int]()
  for term in terms:
    if term in idx.postings:
      for entry in idx.postings[term]:
        if entry.docId notin docCounts:
          docCounts[entry.docId] = 0
        inc docCounts[entry.docId]

  result = @[]
  for docId, count in docCounts:
    if count == terms.len:
      result.add(fts.SearchResult(docId: docId, score: float64(count), highlights: @[]))

proc benchFts(n: int) =
  echo ""
  echo "=== FTS Performance ==="

  var idx = fts.newInvertedIndex()

  let indexStart = getMonoTime()
  for i in 0..<n:
    let docText = sampleDocs[i mod sampleDocs.len]
    idx.addDocument(uint64(i), docText)
  let indexTime = elapsed(indexStart)

  echo "  Index ", $n, " docs: ", indexTime.formatFloat(ffDecimal, 2), "s"

  let queryCount = 1000
  var bm25Queries = @[
    "database indexing strategies",
    "vector similarity search",
    "full text search engines",
    "machine learning models",
    "distributed systems",
  ]

  var latencies: seq[float64] = @[]
  let start = getMonoTime()
  for i in 0..<queryCount:
    let qStart = getMonoTime()
    discard idx.search(bm25Queries[i mod bm25Queries.len])
    let elap = (getMonoTime() - qStart).inNanoseconds.float64 / 1_000_000.0
    latencies.add(elap)
  let bm25Time = elapsed(start)
  let stats = latencyStats(latencies)
  echo "  BM25 search:     ", formatOps(queryCount, bm25Time), "  (p50=", formatMs(stats.p50), " p95=", formatMs(stats.p95), " p99=", formatMs(stats.p99), ")"

  var phraseQueries = @[
    "quick brown fox",
    "database indexing strategies",
    "vector similarity search",
    "full text search",
    "machine learning",
  ]

  latencies.setLen(0)
  let phraseStart = getMonoTime()
  for i in 0..<queryCount:
    let qStart = getMonoTime()
    discard phraseSearch(idx, phraseQueries[i mod phraseQueries.len])
    let elap = (getMonoTime() - qStart).inNanoseconds.float64 / 1_000_000.0
    latencies.add(elap)
  let phraseTime = elapsed(phraseStart)
  let phraseStats = latencyStats(latencies)
  echo "  Phrase search:    ", formatOps(queryCount, phraseTime), "  (p50=", formatMs(phraseStats.p50), " p95=", formatMs(phraseStats.p95), " p99=", formatMs(phraseStats.p99), ")"

  var boolQueries = @[
    @["database", "indexing"],
    @["vector", "search"],
    @["text", "search"],
    @["machine", "learning"],
    @["distributed", "systems"],
  ]

  latencies.setLen(0)
  let boolStart = getMonoTime()
  for i in 0..<queryCount:
    let qStart = getMonoTime()
    discard booleanAndSearch(idx, boolQueries[i mod boolQueries.len])
    let elap = (getMonoTime() - qStart).inNanoseconds.float64 / 1_000_000.0
    latencies.add(elap)
  let boolTime = elapsed(boolStart)
  let boolStats = latencyStats(latencies)
  echo "  Boolean (AND):   ", formatOps(queryCount, boolTime), "  (p50=", formatMs(boolStats.p50), " p95=", formatMs(boolStats.p95), " p99=", formatMs(boolStats.p99), ")"

  var fuzzyQueries = @[
    "programing",
    "databse",
    "algorihm",
    "indxing",
    "simlarity",
  ]

  let fuzzyCount = 200
  latencies.setLen(0)
  let fuzzyStart = getMonoTime()
  for i in 0..<fuzzyCount:
    let qStart = getMonoTime()
    discard idx.fuzzySearch(fuzzyQueries[i mod fuzzyQueries.len], maxDistance = 2)
    let elap = (getMonoTime() - qStart).inNanoseconds.float64 / 1_000_000.0
    latencies.add(elap)
  let fuzzyTime = elapsed(fuzzyStart)
  let fuzzyStats = latencyStats(latencies)
  echo "  Fuzzy search:     ", formatOps(fuzzyCount, fuzzyTime), "  (p50=", formatMs(fuzzyStats.p50), " p95=", formatMs(fuzzyStats.p95), " p99=", formatMs(fuzzyStats.p99), ")"

proc main =
  echo ""
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║         BaraDB Search Benchmarks                     ║"
  echo "╚══════════════════════════════════════════════════════╝"

  benchHnswRecall(10000, 128, @[1, 5, 10, 20])
  benchScalability()
  benchFts(10000)

  echo ""

when isMainModule:
  main()
