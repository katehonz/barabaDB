## BaraDB Benchmarks — performance tests for all engines
import std/monotimes
import std/tables
import std/random
import std/strutils
import ../src/barabadb/storage/lsm
import ../src/barabadb/storage/btree
import ../src/barabadb/vector/engine as vengine
import ../src/barabadb/vector/simd
import ../src/barabadb/fts/engine as fts
import ../src/barabadb/graph/engine as gengine

proc elapsed(start: MonoTime): float64 =
  let ns = float64((getMonoTime() - start).ticks)
  return ns / 1_000_000_000.0

proc formatOps(ops: int, secs: float64): string =
  let rate = float64(ops) / secs
  if rate > 1_000_000:
    return $(rate / 1_000_000).formatFloat(ffDecimal, 2) & "M ops/s"
  elif rate > 1_000:
    return $(rate / 1_000).formatFloat(ffDecimal, 2) & "K ops/s"
  else:
    return $rate.formatFloat(ffDecimal, 2) & " ops/s"

proc benchLSMTree() =
  echo "=== LSM-Tree Storage ==="
  var db = newLSMTree("/tmp/baradb_bench_lsm")

  # Write benchmark
  let n = 100_000
  let start = getMonoTime()
  for i in 0..<n:
    db.put("key_" & $i, cast[seq[byte]]("value_" & $i))
  let writeTime = elapsed(start)
  echo "  Write ", n, " keys: ", writeTime.formatFloat(ffDecimal, 3), "s (", formatOps(n, writeTime), ")"

  # Read benchmark
  let readStart = getMonoTime()
  var found = 0
  for i in 0..<n:
    let (ok, _) = db.get("key_" & $i)
    if ok: inc found
  let readTime = elapsed(readStart)
  echo "  Read ", n, " keys: ", readTime.formatFloat(ffDecimal, 3), "s (", formatOps(n, readTime), ") (", found, " found)"

  db.close()

proc benchBTree() =
  echo "=== B-Tree Index ==="
  var btree = newBTreeIndex[string, string]()
  let n = 100_000

  # Insert benchmark
  let start = getMonoTime()
  for i in 0..<n:
    btree.insert("key_" & $i, "value_" & $i)
  let insertTime = elapsed(start)
  echo "  Insert ", n, " keys: ", insertTime.formatFloat(ffDecimal, 3), "s (", formatOps(n, insertTime), ")"

  # Get benchmark
  let getStart = getMonoTime()
  var found = 0
  for i in 0..<n:
    let vals = btree.get("key_" & $i)
    if vals.len > 0: inc found
  let getTime = elapsed(getStart)
  echo "  Get ", n, " keys: ", getTime.formatFloat(ffDecimal, 3), "s (", formatOps(n, getTime), ") (", found, " found)"

  # Scan benchmark
  let scanStart = getMonoTime()
  let scanResults = btree.scan("key_1000", "key_2000")
  let scanTime = elapsed(scanStart)
  echo "  Scan 1000 range: ", scanTime.formatFloat(ffDecimal, 6), "s (", scanResults.len, " results)"

proc benchVectorSearch() =
  echo "=== Vector Engine (HNSW) ==="
  let dim = 128
  let n = 10_000
  var idx = vengine.newHNSWIndex(dim)

  # Insert benchmark
  randomize(42)
  let start = getMonoTime()
  for i in 0..<n:
    var vec = newSeq[float32](dim)
    for d in 0..<dim:
      vec[d] = rand(1.0)
    vengine.insert(idx, uint64(i), vec)
  let insertTime = elapsed(start)
  echo "  Insert ", n, " vectors (dim=", dim, "): ", insertTime.formatFloat(ffDecimal, 3), "s (", formatOps(n, insertTime), ")"

  # Search benchmark
  var query = newSeq[float32](dim)
  for d in 0..<dim:
    query[d] = rand(1.0)

  let searchStart = getMonoTime()
  let results = vengine.search(idx, query, 10)
  let searchTime = elapsed(searchStart)
  echo "  Search top-10: ", (searchTime * 1000).formatFloat(ffDecimal, 3), "ms"

proc benchVectorSIMD() =
  echo "=== Vector SIMD Operations ==="
  let dim = 768
  let n = 10_000
  randomize(42)

  var corpus = newSeq[SimdVector](n)
  for i in 0..<n:
    corpus[i] = newSeq[float32](dim)
    for d in 0..<dim:
      corpus[i][d] = rand(1.0)

  var query = newSeq[float32](dim)
  for d in 0..<dim:
    query[d] = rand(1.0)

  # Cosine distance benchmark
  let start = getMonoTime()
  for i in 0..<n:
    discard cosineSimd(query, corpus[i])
  let cosineTime = elapsed(start)
  echo "  Cosine distance (dim=768, n=10K): ", cosineTime.formatFloat(ffDecimal, 3), "s (", formatOps(n, cosineTime), ")"

  # L2 distance benchmark
  let l2Start = getMonoTime()
  for i in 0..<n:
    discard l2NormSimd(query, corpus[i])
  let l2Time = elapsed(l2Start)
  echo "  L2 distance (dim=768, n=10K): ", l2Time.formatFloat(ffDecimal, 3), "s (", formatOps(n, l2Time), ")"

  # Dot product benchmark
  let dotStart = getMonoTime()
  for i in 0..<n:
    discard dotProductSimd(query, corpus[i])
  let dotTime = elapsed(dotStart)
  echo "  Dot product (dim=768, n=10K): ", dotTime.formatFloat(ffDecimal, 3), "s (", formatOps(n, dotTime), ")"

proc benchFTS() =
  echo "=== Full-Text Search ==="
  var idx = fts.newInvertedIndex()
  let n = 10_000

  # Index benchmark
  let docs = @[
    "Nim is a statically typed compiled systems programming language",
    "It combines the speed of C with an expressive syntax like Python",
    "Memory management is deterministic with reference counting",
    "The compiler produces optimized native code for all platforms",
    "Metaprogramming and generics enable powerful abstractions",
  ]
  let start = getMonoTime()
  for i in 0..<n:
    idx.addDocument(uint64(i), docs[i mod docs.len])
  let indexTime = elapsed(start)
  echo "  Index ", n, " docs: ", indexTime.formatFloat(ffDecimal, 3), "s (", formatOps(n, indexTime), ")"

  # Search benchmark
  let searchStart = getMonoTime()
  for i in 0..<1000:
    discard idx.search("Nim programming language")
  let searchTime = elapsed(searchStart)
  echo "  Search 1000 queries: ", searchTime.formatFloat(ffDecimal, 3), "s (", formatOps(1000, searchTime), ")"

  # Fuzzy search benchmark
  let fuzzyStart = getMonoTime()
  for i in 0..<100:
    discard idx.fuzzySearch("programing", maxDistance = 2)
  let fuzzyTime = elapsed(fuzzyStart)
  echo "  Fuzzy search 100 queries: ", fuzzyTime.formatFloat(ffDecimal, 3), "s (", formatOps(100, fuzzyTime), ")"

proc benchGraph() =
  echo "=== Graph Engine ==="
  var g = gengine.newGraph()
  let nodeCount = 1000
  let edgeCount = 5000

  # Add nodes
  let nodeStart = getMonoTime()
  for i in 0..<nodeCount:
    discard gengine.addNode(g, "Node_" & $i)
  let nodeTime = elapsed(nodeStart)
  echo "  Add ", nodeCount, " nodes: ", nodeTime.formatFloat(ffDecimal, 6), "s"

  # Add edges
  randomize(42)
  let edgeStart = getMonoTime()
  for i in 0..<edgeCount:
    let src = NodeId(uint64(rand(nodeCount - 1)) + 1)
    let dst = NodeId(uint64(rand(nodeCount - 1)) + 1)
    discard gengine.addEdge(g, src, dst)
  let edgeTime = elapsed(edgeStart)
  echo "  Add ", edgeCount, " edges: ", edgeTime.formatFloat(ffDecimal, 6), "s"

  # BFS benchmark
  let bfsStart = getMonoTime()
  for i in 0..<100:
    discard gengine.bfs(g, NodeId(1))
  let bfsTime = elapsed(bfsStart)
  echo "  BFS 100 traversals: ", bfsTime.formatFloat(ffDecimal, 3), "s (", formatOps(100, bfsTime), ")"

  # PageRank benchmark
  let prStart = getMonoTime()
  discard gengine.pageRank(g, 10)
  let prTime = elapsed(prStart)
  echo "  PageRank (10 iterations): ", prTime.formatFloat(ffDecimal, 3), "s"

proc main() =
  echo ""
  echo "╔══════════════════════════════════════════════════╗"
  echo "║         BaraDB Performance Benchmarks            ║"
  echo "╚══════════════════════════════════════════════════╝"
  echo ""
  benchLSMTree()
  echo ""
  benchBTree()
  echo ""
  benchVectorSearch()
  echo ""
  benchVectorSIMD()
  echo ""
  benchFTS()
  echo ""
  benchGraph()
  echo ""

when isMainModule:
  main()
