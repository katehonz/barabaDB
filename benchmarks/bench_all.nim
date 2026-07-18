## BaraDB Benchmarks — performance tests for all engines
import std/monotimes
import std/times
import std/random
import std/strutils
import std/os
import std/osproc
import std/json
import ../src/barabadb/storage/lsm
import ../src/barabadb/storage/btree
import ../src/barabadb/vector/engine as vengine
import ../src/barabadb/vector/simd
import ../src/barabadb/fts/engine as fts
import ../src/barabadb/graph/engine as gengine

# ═══════════════════════════════════════════════════
# Benchmark Result Tracking
# ═══════════════════════════════════════════════════
type
  BenchResult* = object
    name*: string
    ops*: int
    seconds*: float64
    opsPerSec*: float64
    timestamp*: string

  BenchReport* = object
    version*: string
    gitSha*: string
    results*: seq[BenchResult]

const ResultsFile = "benchmark_results.json"

proc loadPreviousResults(path: string): seq[BenchResult] =
  result = @[]
  if not fileExists(path): return
  try:
    let j = parseFile(path)
    if j.hasKey("results"):
      for item in j["results"]:
        if item.hasKey("name") and item.hasKey("opsPerSec"):
          result.add(BenchResult(
            name: item["name"].getStr(),
            ops: if item.hasKey("ops"): item["ops"].getInt() else: 0,
            seconds: if item.hasKey("seconds"): item["seconds"].getFloat() else: 0.0,
            opsPerSec: item["opsPerSec"].getFloat(),
            timestamp: if item.hasKey("timestamp"): item["timestamp"].getStr() else: "",
          ))
  except:
    discard

proc saveResults(path: string, report: BenchReport) =
  var j = newJObject()
  j["version"] = %report.version
  j["gitSha"] = %report.gitSha
  var arr = newJArray()
  for r in report.results:
    var obj = newJObject()
    obj["name"] = %r.name
    obj["ops"] = %r.ops
    obj["seconds"] = %r.seconds
    obj["opsPerSec"] = %r.opsPerSec
    obj["timestamp"] = %r.timestamp
    arr.add(obj)
  j["results"] = arr
  writeFile(path, j.pretty())

proc compareResult(name: string, currentOpsPerSec: float64, previous: seq[BenchResult]): string =
  for p in previous:
    if p.name == name:
      let delta = currentOpsPerSec - p.opsPerSec
      let pct = if p.opsPerSec > 0: (delta / p.opsPerSec) * 100.0 else: 0.0
      if abs(pct) < 1.0:
        return " (≈ same)"
      elif pct > 0:
        return " (+" & pct.formatFloat(ffDecimal, 1) & "% vs last)"
      else:
        return " (" & pct.formatFloat(ffDecimal, 1) & "% vs last)"
  return " (new)"

var currentResults: seq[BenchResult] = @[]
var previousResults = loadPreviousResults(ResultsFile)

proc recordResult(name: string, ops: int, seconds: float64) =
  currentResults.add(BenchResult(
    name: name,
    ops: ops,
    seconds: seconds,
    opsPerSec: if seconds > 0: float64(ops) / seconds else: 0.0,
    timestamp: now().format("yyyy-MM-dd HH:mm:ss"),
  ))

proc gitSha(): string =
  let (output, code) = execCmdEx("git rev-parse --short HEAD")
  if code == 0:
    return output.strip()
  return "unknown"

proc elapsed(start: MonoTime): float64 =
  let ns = float64((getMonoTime() - start).inNanoseconds)
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
  echo "  Note: in-process embedded API (no network/SQL). Not comparable to client-server DBs."
  let benchDir = getTempDir() / "baradb_bench_lsm"
  removeDir(benchDir)
  # Default group-commit WAL (production default)
  var db = newLSMTree(benchDir, walSyncMode = wsmGroup, walGroupEvery = 64)

  # Write benchmark
  let n = 100_000
  let start = getMonoTime()
  for i in 0..<n:
    db.put("key_" & $i, cast[seq[byte]]("value_" & $i))
  let writeTime = elapsed(start)
  let writeLabel = "LSM-Write"
  recordResult(writeLabel, n, writeTime)
  echo "  Write ", n, " keys: ", writeTime.formatFloat(ffDecimal, 3), "s (", formatOps(n, writeTime), ")", compareResult(writeLabel, currentResults[^1].opsPerSec, previousResults)
  echo "    fsyncs: ", db.wal.fsyncCount, " (group every 64)"

  # Read benchmark
  let readStart = getMonoTime()
  var found = 0
  for i in 0..<n:
    let (ok, _) = db.get("key_" & $i)
    if ok: inc found
  let readTime = elapsed(readStart)
  let readLabel = "LSM-Read"
  recordResult(readLabel, n, readTime)
  echo "  Read ", n, " keys: ", readTime.formatFloat(ffDecimal, 3), "s (", formatOps(n, readTime), ") (", found, " found)", compareResult(readLabel, currentResults[^1].opsPerSec, previousResults)

  db.close()

proc benchWalDurabilityModes() =
  ## Fair comparison of WAL durability policies on the same workload.
  echo "=== WAL Durability Modes (fair micro-bench) ==="
  echo "  Same N puts, same memtable size; only sync policy differs."
  let n = 50_000
  let modes = [
    (wsmNone, "none", 0),
    (wsmGroup, "group64", 64),
    (wsmGroup, "group256", 256),
    (wsmEvery, "every", 1),
  ]
  for (mode, label, ge) in modes:
    let dir = getTempDir() / ("baradb_bench_wal_" & label)
    removeDir(dir)
    var db = newLSMTree(dir, memMaxSize = 64 * 1024 * 1024,
                        walSyncMode = mode, walGroupEvery = max(1, ge))
    let t0 = getMonoTime()
    for i in 0..<n:
      db.put("k" & $i, cast[seq[byte]]("v" & $i))
    # Ensure pending group is durable before measuring end-to-end
    db.wal.sync()
    let secs = elapsed(t0)
    let name = "WAL-" & label
    recordResult(name, n, secs)
    echo "  ", label, ": ", secs.formatFloat(ffDecimal, 3), "s (",
         formatOps(n, secs), "), fsyncs=", db.wal.fsyncCount,
         compareResult(name, currentResults[^1].opsPerSec, previousResults)
    db.close()
    removeDir(dir)

proc benchBTree() =
  echo "=== B-Tree Index ==="
  var btree = newBTreeIndex[string, string]()
  let n = 100_000

  # Insert benchmark
  let start = getMonoTime()
  for i in 0..<n:
    btree.insert("key_" & $i, "value_" & $i)
  let insertTime = elapsed(start)
  let insertLabel = "BTree-Insert"
  recordResult(insertLabel, n, insertTime)
  echo "  Insert ", n, " keys: ", insertTime.formatFloat(ffDecimal, 3), "s (", formatOps(n, insertTime), ")", compareResult(insertLabel, currentResults[^1].opsPerSec, previousResults)

  # Get benchmark
  let getStart = getMonoTime()
  var found = 0
  for i in 0..<n:
    let vals = btree.get("key_" & $i)
    if vals.len > 0: inc found
  let getTime = elapsed(getStart)
  let getLabel = "BTree-Get"
  recordResult(getLabel, n, getTime)
  echo "  Get ", n, " keys: ", getTime.formatFloat(ffDecimal, 3), "s (", formatOps(n, getTime), ") (", found, " found)", compareResult(getLabel, currentResults[^1].opsPerSec, previousResults)

  # Scan benchmark
  let scanStart = getMonoTime()
  let scanResults = btree.scan("key_1000", "key_2000")
  let scanTime = elapsed(scanStart)
  let scanLabel = "BTree-Scan"
  recordResult(scanLabel, scanResults.len, scanTime)
  echo "  Scan 1000 range: ", scanTime.formatFloat(ffDecimal, 6), "s (", scanResults.len, " results)", compareResult(scanLabel, currentResults[^1].opsPerSec, previousResults)

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
  let insertLabel = "HNSW-Insert"
  recordResult(insertLabel, n, insertTime)
  echo "  Insert ", n, " vectors (dim=", dim, "): ", insertTime.formatFloat(ffDecimal, 3), "s (", formatOps(n, insertTime), ")", compareResult(insertLabel, currentResults[^1].opsPerSec, previousResults)

  # Search benchmark
  var query = newSeq[float32](dim)
  for d in 0..<dim:
    query[d] = rand(1.0)

  let searchStart = getMonoTime()
  let results = vengine.search(idx, query, 10)
  let searchTime = elapsed(searchStart)
  let searchLabel = "HNSW-Search"
  recordResult(searchLabel, 1, searchTime)
  echo "  Search top-10: ", (searchTime * 1000).formatFloat(ffDecimal, 3), "ms", compareResult(searchLabel, currentResults[^1].opsPerSec, previousResults)

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
  let cosineLabel = "SIMD-Cosine"
  recordResult(cosineLabel, n, cosineTime)
  echo "  Cosine distance (dim=768, n=10K): ", cosineTime.formatFloat(ffDecimal, 3), "s (", formatOps(n, cosineTime), ")", compareResult(cosineLabel, currentResults[^1].opsPerSec, previousResults)

  # L2 distance benchmark
  let l2Start = getMonoTime()
  for i in 0..<n:
    discard l2NormSimd(query, corpus[i])
  let l2Time = elapsed(l2Start)
  let l2Label = "SIMD-L2"
  recordResult(l2Label, n, l2Time)
  echo "  L2 distance (dim=768, n=10K): ", l2Time.formatFloat(ffDecimal, 3), "s (", formatOps(n, l2Time), ")", compareResult(l2Label, currentResults[^1].opsPerSec, previousResults)

  # Dot product benchmark
  let dotStart = getMonoTime()
  for i in 0..<n:
    discard dotProductSimd(query, corpus[i])
  let dotTime = elapsed(dotStart)
  let dotLabel = "SIMD-Dot"
  recordResult(dotLabel, n, dotTime)
  echo "  Dot product (dim=768, n=10K): ", dotTime.formatFloat(ffDecimal, 3), "s (", formatOps(n, dotTime), ")", compareResult(dotLabel, currentResults[^1].opsPerSec, previousResults)

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
  let indexLabel = "FTS-Index"
  recordResult(indexLabel, n, indexTime)
  echo "  Index ", n, " docs: ", indexTime.formatFloat(ffDecimal, 3), "s (", formatOps(n, indexTime), ")", compareResult(indexLabel, currentResults[^1].opsPerSec, previousResults)

  # Search benchmark
  let searchStart = getMonoTime()
  for i in 0..<1000:
    discard idx.search("Nim programming language")
  let searchTime = elapsed(searchStart)
  let searchLabel = "FTS-Search"
  recordResult(searchLabel, 1000, searchTime)
  echo "  Search 1000 queries: ", searchTime.formatFloat(ffDecimal, 3), "s (", formatOps(1000, searchTime), ")", compareResult(searchLabel, currentResults[^1].opsPerSec, previousResults)

  # Fuzzy search benchmark
  let fuzzyStart = getMonoTime()
  for i in 0..<100:
    discard idx.fuzzySearch("programing", maxDistance = 2)
  let fuzzyTime = elapsed(fuzzyStart)
  let fuzzyLabel = "FTS-Fuzzy"
  recordResult(fuzzyLabel, 100, fuzzyTime)
  echo "  Fuzzy search 100 queries: ", fuzzyTime.formatFloat(ffDecimal, 3), "s (", formatOps(100, fuzzyTime), ")", compareResult(fuzzyLabel, currentResults[^1].opsPerSec, previousResults)

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
  let nodeLabel = "Graph-AddNodes"
  recordResult(nodeLabel, nodeCount, nodeTime)
  echo "  Add ", nodeCount, " nodes: ", nodeTime.formatFloat(ffDecimal, 6), "s", compareResult(nodeLabel, currentResults[^1].opsPerSec, previousResults)

  # Add edges
  randomize(42)
  let edgeStart = getMonoTime()
  for i in 0..<edgeCount:
    let src = NodeId(uint64(rand(nodeCount - 1)) + 1)
    let dst = NodeId(uint64(rand(nodeCount - 1)) + 1)
    discard gengine.addEdge(g, src, dst)
  let edgeTime = elapsed(edgeStart)
  let edgeLabel = "Graph-AddEdges"
  recordResult(edgeLabel, edgeCount, edgeTime)
  echo "  Add ", edgeCount, " edges: ", edgeTime.formatFloat(ffDecimal, 6), "s", compareResult(edgeLabel, currentResults[^1].opsPerSec, previousResults)

  # BFS benchmark
  let bfsStart = getMonoTime()
  for i in 0..<100:
    discard gengine.bfs(g, NodeId(1))
  let bfsTime = elapsed(bfsStart)
  let bfsLabel = "Graph-BFS"
  recordResult(bfsLabel, 100, bfsTime)
  echo "  BFS 100 traversals: ", bfsTime.formatFloat(ffDecimal, 3), "s (", formatOps(100, bfsTime), ")", compareResult(bfsLabel, currentResults[^1].opsPerSec, previousResults)

  # PageRank benchmark
  let prStart = getMonoTime()
  discard gengine.pageRank(g, 10)
  let prTime = elapsed(prStart)
  let prLabel = "Graph-PageRank"
  recordResult(prLabel, 10, prTime)
  echo "  PageRank (10 iterations): ", prTime.formatFloat(ffDecimal, 3), "s", compareResult(prLabel, currentResults[^1].opsPerSec, previousResults)

proc main() =
  echo ""
  echo "╔══════════════════════════════════════════════════╗"
  echo "║     BaraDB Performance Benchmarks (EMBEDDED)     ║"
  echo "╚══════════════════════════════════════════════════╝"
  echo ""
  echo "Tier: embedded / in-process (no network, no wire SQL)."
  echo "For fair multi-tier numbers (SQLite / PG / HTTP):"
  echo "  python3 benchmarks/fair_bench.py"
  echo ""
  benchLSMTree()
  echo ""
  benchWalDurabilityModes()
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

  # Save results for regression tracking
  let report = BenchReport(
    version: "1.0.0",
    gitSha: gitSha(),
    results: currentResults,
  )
  saveResults(ResultsFile, report)
  echo "Results saved to ", ResultsFile
  echo "Next: python3 benchmarks/fair_bench.py"
  echo ""

when isMainModule:
  main()
