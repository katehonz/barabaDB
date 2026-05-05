## BaraDB — Test Suite
import std/unittest
import std/tables

import barabadb/core/types
import barabadb/storage/bloom
import barabadb/storage/wal
import barabadb/storage/lsm
import barabadb/query/lexer as lex
import barabadb/query/ast
import barabadb/query/parser
import barabadb/vector/engine as vengine
import barabadb/graph/engine as gengine
import barabadb/fts/engine as fts

suite "Core Types":
  test "Value creation":
    let v = Value(kind: vkInt64, int64Val: 42)
    check v.kind == vkInt64
    check v.int64Val == 42

  test "String value":
    let v = Value(kind: vkString, strVal: "hello")
    check v.strVal == "hello"

  test "RecordId creation":
    let id = newRecordId()
    check uint64(id) > 0

suite "Bloom Filter":
  test "Basic bloom filter operations":
    var bf = newBloomFilter(1000)
    let data1 = cast[seq[byte]]("hello")
    let data2 = cast[seq[byte]]("world")

    bf.add(data1)
    bf.add(data2)

    check bf.contains(data1)
    check bf.contains(data2)

suite "Write-Ahead Log":
  test "WAL creation":
    var wal = newWriteAheadLog("/tmp/baradb_test_wal")
    check wal.entryCount == 0
    wal.close()

suite "LSM-Tree Storage":
  test "Put and Get":
    var db = newLSMTree("/tmp/baradb_test_lsm")
    let key = "testkey"
    let value = cast[seq[byte]]("testvalue")
    db.put(key, value)
    let (found, val) = db.get(key)
    check found
    check val == value
    db.close()

  test "Delete":
    var db = newLSMTree("/tmp/baradb_test_lsm2")
    let key = "delkey"
    let value = cast[seq[byte]]("delval")
    db.put(key, value)
    db.delete(key)
    let (found, _) = db.get(key)
    check not found
    db.close()

  test "Contains":
    var db = newLSMTree("/tmp/baradb_test_lsm3")
    let key = "exists"
    check not db.contains(key)
    db.put(key, cast[seq[byte]]("val"))
    check db.contains(key)
    db.close()

suite "BaraQL Lexer":
  test "Tokenize simple SELECT":
    let tokens = lex.tokenize("SELECT name FROM users WHERE age > 18")
    check tokens.len > 0
    check tokens[0].kind == tkSelect
    check tokens[1].kind == tkIdent
    check tokens[1].value == "name"
    check tokens[2].kind == tkFrom
    check tokens[3].kind == tkIdent
    check tokens[3].value == "users"

  test "Tokenize string literals":
    let tokens = lex.tokenize("'hello world'")
    check tokens[0].kind == tkStringLit
    check tokens[0].value == "hello world"

  test "Tokenize operators":
    let tokens = lex.tokenize("a + b * c")
    check tokens[0].kind == tkIdent
    check tokens[1].kind == tkPlus
    check tokens[2].kind == tkIdent
    check tokens[3].kind == tkStar

suite "BaraQL Parser":
  test "Parse simple SELECT":
    let ast = parse("SELECT name FROM users WHERE age > 18")
    check ast.kind == nkStatementList
    check ast.stmts.len == 1
    check ast.stmts[0].kind == nkSelect

  test "Parse SELECT with LIMIT":
    let ast = parse("SELECT * FROM items LIMIT 10")
    check ast.stmts[0].selLimit != nil

suite "Vector Engine":
  test "Distance metrics":
    let a = @[1.0'f32, 0.0'f32, 0.0'f32]
    let b = @[0.0'f32, 1.0'f32, 0.0'f32]
    let c = @[1.0'f32, 0.0'f32, 0.0'f32]

    check vengine.cosineDistance(a, b) > 0.9
    check vengine.cosineDistance(a, c) < 0.1
    check vengine.euclideanDistance(a, b) > 1.0
    check vengine.euclideanDistance(a, c) < 0.1

  test "HNSW index insert and search":
    var idx = vengine.newHNSWIndex(3)
    vengine.insert(idx, 1, @[1.0'f32, 0.0'f32, 0.0'f32])
    vengine.insert(idx, 2, @[0.0'f32, 1.0'f32, 0.0'f32])
    vengine.insert(idx, 3, @[0.0'f32, 0.0'f32, 1.0'f32])

    let results = vengine.search(idx, @[1.0'f32, 0.1'f32, 0.0'f32], 2)
    check results.len == 2

suite "Graph Engine":
  test "Add nodes and edges":
    var g = gengine.newGraph()
    let n1 = gengine.addNode(g, "Person", {"name": "Alice"}.toTable)
    let n2 = gengine.addNode(g, "Person", {"name": "Bob"}.toTable)
    let e1 = gengine.addEdge(g, n1, n2, "knows")

    check gengine.nodeCount(g) == 2
    check gengine.edgeCount(g) == 1

  test "BFS traversal":
    var g = gengine.newGraph()
    let n1 = gengine.addNode(g, "A")
    let n2 = gengine.addNode(g, "B")
    let n3 = gengine.addNode(g, "C")
    let n4 = gengine.addNode(g, "D")
    discard gengine.addEdge(g, n1, n2)
    discard gengine.addEdge(g, n1, n3)
    discard gengine.addEdge(g, n2, n4)

    let traversal = gengine.bfs(g, n1)
    check traversal.len == 4
    check traversal[0] == n1

  test "DFS traversal":
    var g = gengine.newGraph()
    let n1 = gengine.addNode(g, "A")
    let n2 = gengine.addNode(g, "B")
    let n3 = gengine.addNode(g, "C")
    discard gengine.addEdge(g, n1, n2)
    discard gengine.addEdge(g, n1, n3)

    let traversal = gengine.dfs(g, n1)
    check traversal.len == 3

  test "Shortest path":
    var g = gengine.newGraph()
    let n1 = gengine.addNode(g, "A")
    let n2 = gengine.addNode(g, "B")
    let n3 = gengine.addNode(g, "C")
    discard gengine.addEdge(g, n1, n2)
    discard gengine.addEdge(g, n2, n3)

    let path = gengine.shortestPath(g, n1, n3)
    check path.len == 3

  test "PageRank":
    var g = gengine.newGraph()
    let n1 = gengine.addNode(g, "A")
    let n2 = gengine.addNode(g, "B")
    let n3 = gengine.addNode(g, "C")
    discard gengine.addEdge(g, n1, n2)
    discard gengine.addEdge(g, n2, n3)
    discard gengine.addEdge(g, n3, n1)

    let ranks = gengine.pageRank(g)
    check ranks.len == 3
    for nodeId, rank in ranks:
      check rank > 0.0

  test "Dijkstra":
    var g = gengine.newGraph()
    let n1 = gengine.addNode(g, "A")
    let n2 = gengine.addNode(g, "B")
    let n3 = gengine.addNode(g, "C")
    discard gengine.addEdge(g, n1, n2, weight = 1.0)
    discard gengine.addEdge(g, n2, n3, weight = 2.0)
    discard gengine.addEdge(g, n1, n3, weight = 10.0)

    let dists = gengine.dijkstra(g, n1)
    check dists[n1] == 0.0
    check dists[n2] == 1.0
    check dists[n3] == 3.0

suite "Full-Text Search":
  test "Tokenization":
    let tokens = fts.tokenize("The quick brown fox jumps over the lazy dog")
    check tokens.len > 0
    check "the" notin tokens

  test "Inverted index operations":
    var idx = fts.newInvertedIndex()
    fts.addDocument(idx, 1, "The quick brown fox")
    fts.addDocument(idx, 2, "The lazy brown dog")
    fts.addDocument(idx, 3, "The quick red car")

    check fts.documentCount(idx) == 3
    check fts.termCount(idx) > 0

  test "Search results":
    var idx = fts.newInvertedIndex()
    fts.addDocument(idx, 1, "Nim programming language is fast")
    fts.addDocument(idx, 2, "Python is popular for data science")
    fts.addDocument(idx, 3, "Rust is a systems programming language")

    let results = fts.search(idx, "programming language")
    check results.len > 0
    check results[0].score > 0

  test "Document removal":
    var idx = fts.newInvertedIndex()
    fts.addDocument(idx, 1, "test document")
    fts.addDocument(idx, 2, "another document")
    check fts.documentCount(idx) == 2

    fts.removeDocument(idx, 1)
    check fts.documentCount(idx) == 1
