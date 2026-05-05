## BaraDB — Test Suite
import std/unittest
import std/tables
import std/strutils

import barabadb/core/types
import barabadb/core/mvcc
import barabadb/core/deadlock
import barabadb/storage/bloom
import barabadb/storage/wal
import barabadb/storage/lsm
import barabadb/query/lexer as lex
import barabadb/query/ast
import barabadb/query/parser
import barabadb/vector/engine as vengine
import barabadb/graph/engine as gengine
import barabadb/fts/engine as fts
import barabadb/protocol/wire
import barabadb/schema/schema as schema

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

suite "MVCC Transactions":
  test "Begin and commit transaction":
    var tm = newTxnManager()
    let txn = tm.beginTxn()
    check txn.state == tsActive
    check tm.write(txn, "key1", cast[seq[byte]]("value1"))
    check tm.commit(txn)
    check txn.state == tsCommitted

  test "Read own writes":
    var tm = newTxnManager()
    let txn = tm.beginTxn()
    discard tm.write(txn, "key1", cast[seq[byte]]("value1"))
    let (found, val) = tm.read(txn, "key1")
    check found
    check val == cast[seq[byte]]("value1")
    discard tm.commit(txn)

  test "Abort transaction":
    var tm = newTxnManager()
    let txn = tm.beginTxn()
    discard tm.write(txn, "key1", cast[seq[byte]]("value1"))
    discard tm.abortTxn(txn)
    check txn.state == tsAborted

  test "Snapshot isolation — no dirty reads":
    var tm = newTxnManager()
    let txn1 = tm.beginTxn()
    discard tm.write(txn1, "key1", cast[seq[byte]]("value1"))

    let txn2 = tm.beginTxn()
    let (found, _) = tm.read(txn2, "key1")
    check not found  # txn2 can't see txn1's uncommitted write

    discard tm.commit(txn1)
    # txn2 still can't see it (snapshot taken before commit)
    let (found2, _) = tm.read(txn2, "key1")
    check not found2
    discard tm.abortTxn(txn2)

  test "Committed writes visible to new transactions":
    var tm = newTxnManager()
    let txn1 = tm.beginTxn()
    discard tm.write(txn1, "key1", cast[seq[byte]]("value1"))
    discard tm.commit(txn1)

    let txn2 = tm.beginTxn()
    let (found, val) = tm.read(txn2, "key1")
    check found
    check val == cast[seq[byte]]("value1")
    discard tm.commit(txn2)

  test "Savepoint and rollback":
    var tm = newTxnManager()
    let txn = tm.beginTxn()
    discard tm.write(txn, "key1", cast[seq[byte]]("value1"))
    tm.savepoint(txn)
    discard tm.write(txn, "key2", cast[seq[byte]]("value2"))
    check tm.rollbackToSavepoint(txn)
    let (found1, _) = tm.read(txn, "key1")
    check found1
    let (found2, _) = tm.read(txn, "key2")
    check not found2
    discard tm.commit(txn)

  test "Delete via xmax":
    var tm = newTxnManager()
    let txn1 = tm.beginTxn()
    discard tm.write(txn1, "key1", cast[seq[byte]]("value1"))
    discard tm.commit(txn1)

    let txn2 = tm.beginTxn()
    discard tm.delete(txn2, "key1")
    discard tm.commit(txn2)

    let txn3 = tm.beginTxn()
    let (found, _) = tm.read(txn3, "key1")
    check not found
    discard tm.commit(txn3)

suite "Deadlock Detection":
  test "No deadlock without cycles":
    var dd = newDeadlockDetector()
    dd.addWait(1, 2)
    dd.addWait(2, 3)
    check not dd.hasDeadlock()

  test "Detect simple deadlock":
    var dd = newDeadlockDetector()
    dd.addWait(1, 2)
    dd.addWait(2, 1)
    check dd.hasDeadlock()

  test "Find deadlock victim":
    var dd = newDeadlockDetector()
    dd.addWait(1, 2)
    dd.addWait(2, 3)
    dd.addWait(3, 1)
    let victim = dd.findDeadlockVictim()
    check victim == 3  # youngest txn

  test "Remove transaction clears edges":
    var dd = newDeadlockDetector()
    dd.addWait(1, 2)
    dd.addWait(2, 1)
    dd.removeTxn(2)
    check not dd.hasDeadlock()

suite "Wire Protocol":
  test "Value serialization roundtrip":
    var buf: seq[byte] = @[]
    let val = WireValue(kind: fkString, strVal: "hello world")
    buf.serializeValue(val)
    var pos = 0
    let decoded = buf.deserializeValue(pos)
    check decoded.kind == fkString
    check decoded.strVal == "hello world"

  test "Int64 serialization":
    var buf: seq[byte] = @[]
    let val = WireValue(kind: fkInt64, int64Val: 42)
    buf.serializeValue(val)
    var pos = 0
    let decoded = buf.deserializeValue(pos)
    check decoded.kind == fkInt64
    check decoded.int64Val == 42

  test "Array serialization":
    var buf: seq[byte] = @[]
    let val = WireValue(kind: fkArray, arrayVal: @[
      WireValue(kind: fkInt32, int32Val: 1),
      WireValue(kind: fkInt32, int32Val: 2),
      WireValue(kind: fkInt32, int32Val: 3),
    ])
    buf.serializeValue(val)
    var pos = 0
    let decoded = buf.deserializeValue(pos)
    check decoded.kind == fkArray
    check decoded.arrayVal.len == 3
    check decoded.arrayVal[1].int32Val == 2

  test "Vector serialization":
    var buf: seq[byte] = @[]
    let val = WireValue(kind: fkVector, vecVal: @[1.0'f32, 2.0'f32, 3.0'f32])
    buf.serializeValue(val)
    var pos = 0
    let decoded = buf.deserializeValue(pos)
    check decoded.kind == fkVector
    check decoded.vecVal.len == 3

  test "Query message creation":
    let msg = makeQueryMessage(1, "SELECT * FROM users")
    check msg.len > 0
    check msg[3] == byte(mkQuery)  # big-endian uint32, last byte

suite "Schema System":
  test "Create type with properties":
    var s = newSchema()
    let person = newType("Person")
    person.addProperty("name", "str", required = true)
    person.addProperty("age", "int32")
    s.addType("default", person)
    check s.getType("Person") != nil
    check s.getType("Person").properties.len == 2

  test "Create type with links":
    var s = newSchema()
    let person = newType("Person")
    person.addProperty("name", "str", required = true)
    s.addType("default", person)

    let movie = newType("Movie")
    movie.addProperty("title", "str", required = true)
    movie.addLink("actors", "Person", multi = true)
    s.addType("default", movie)

    check movie.links.len == 1
    check movie.links["actors"].target == "Person"

  test "Schema diff":
    let s1 = newSchema()
    let t1 = newType("Person")
    t1.addProperty("name", "str")
    s1.addType("default", t1)

    let s2 = newSchema()
    let t2 = newType("Person")
    t2.addProperty("name", "str")
    t2.addProperty("age", "int32")
    s2.addType("default", t2)
    let movieT = newType("Movie")
    movieT.addProperty("title", "str")
    s2.addType("default", movieT)

    let d = diff(s1, s2)
    check d.addedTypes.len == 1
    check d.addedTypes[0] == "Movie"
    check d.modifiedTypes.len == 1
    check d.modifiedTypes[0].addedProperties.len == 1

  test "Type validation":
    let t = newType("Person")
    t.addProperty("name", "str", required = true)
    t.addLink("friend", "")  # empty target
    let errors = t.validateType()
    check errors.len == 1  # empty link target

  test "Migration creation":
    var s = newSchema()
    let m1 = s.createMigration("initial", "CREATE TYPE Person { name: str }")
    check m1.id == 1
    let m2 = s.createMigration("add age", "ALTER TYPE Person { ADD age: int32 }")
    check m2.id == 2
    check m2.parentId == 1

  test "Type to string":
    let t = newType("Person")
    t.addProperty("name", "str", required = true)
    t.addProperty("age", "int32")
    t.addLink("friend", "Person")
    let s = $t
    check s.find("Person") >= 0
    check s.find("name") >= 0
    check s.find("str") >= 0
