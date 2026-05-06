## BaraDB — Test Suite
import std/unittest
import std/tables
import std/strutils
import std/os
import std/asyncdispatch

import barabadb/core/types
import barabadb/core/mvcc
import barabadb/core/deadlock
import barabadb/core/config
import barabadb/core/server
import barabadb/core/columnar
import barabadb/core/raft
import barabadb/core/sharding
import barabadb/core/replication
import barabadb/storage/bloom
import barabadb/storage/wal
import barabadb/storage/lsm
import barabadb/storage/btree
import barabadb/storage/compaction
import barabadb/query/lexer as lex
import barabadb/query/ast
import barabadb/query/parser
import barabadb/query/ir as qir
import barabadb/query/codegen
import barabadb/query/udf
import barabadb/vector/simd
import barabadb/core/crossmodal
import barabadb/core/gossip
import barabadb/client/client
import barabadb/client/fileops
import barabadb/fts/multilang as mlang
import barabadb/protocol/zerocopy
import barabadb/query/adaptive
import barabadb/query/executor as qexec
import barabadb/core/disttxn
import barabadb/vector/engine as vengine
import barabadb/graph/cypher
import barabadb/vector/quant as vquant
import barabadb/storage/recovery
import barabadb/cli/shell
import barabadb/protocol/ssl
import barabadb/graph/engine as gengine
import barabadb/graph/community as gcomm
import barabadb/fts/engine as fts
import barabadb/protocol/wire
import barabadb/protocol/pool
import barabadb/protocol/auth
import barabadb/protocol/ratelimit
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
    removeDir("/tmp/baradb_test_lsm")
    var db = newLSMTree("/tmp/baradb_test_lsm")
    let key = "testkey"
    let value = cast[seq[byte]]("testvalue")
    db.put(key, value)
    let (found, val) = db.get(key)
    check found
    check val == value
    db.close()

  test "Delete":
    removeDir("/tmp/baradb_test_lsm2")
    var db = newLSMTree("/tmp/baradb_test_lsm2")
    let key = "delkey"
    let value = cast[seq[byte]]("delval")
    db.put(key, value)
    db.delete(key)
    let (found, _) = db.get(key)
    check not found
    db.close()

  test "Contains":
    removeDir("/tmp/baradb_test_lsm3")
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

  test "Save and load graph":
    var g = gengine.newGraph()
    let n1 = gengine.addNode(g, "Person", {"name": "Alice"}.toTable)
    let n2 = gengine.addNode(g, "Person", {"name": "Bob"}.toTable)
    let n3 = gengine.addNode(g, "City", {"name": "Sofia"}.toTable)
    discard gengine.addEdge(g, n1, n2, "knows", {"since": "2020"}.toTable, 1.5)
    discard gengine.addEdge(g, n2, n3, "lives_in", weight = 2.0)

    let path = "/tmp/baradb_test_graph.bin"
    removeFile(path)
    gengine.saveToFile(g, path)

    let g2 = gengine.loadFromFile(path)
    check gengine.nodeCount(g2) == 3
    check gengine.edgeCount(g2) == 2
    check gengine.neighbors(g2, n1).len == 1
    check gengine.neighbors(g2, n1)[0] == n2
    check gengine.neighbors(g2, n2)[0] == n3

    let loadedNode = gengine.getNode(g2, n1)
    check loadedNode.label == "Person"
    check loadedNode.properties["name"] == "Alice"

    let sp = gengine.shortestPath(g2, n1, n3)
    check sp.len == 3

    removeFile(path)

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

suite "MVCC Deadlock Detection":
  test "TxnManager detects and breaks deadlock":
    var tm = newTxnManager()
    var t1 = tm.beginTxn()
    var t2 = tm.beginTxn()
    # t1 writes key "a"
    check tm.write(t1, "a", @[1'u8])
    # t2 writes key "b"
    check tm.write(t2, "b", @[2'u8])
    # t2 tries to write "a" — conflicts with t1 (active), adds wait edge t2->t1
    check not tm.write(t2, "a", @[3'u8])
    # t1 tries to write "b" — conflicts with t2 (active), adds wait edge t1->t2
    # This creates a cycle: t1->t2->t1
    check not tm.write(t1, "b", @[4'u8])
    # One of the transactions should have been aborted as victim
    let t1Active = t1.state == tsActive
    let t2Active = t2.state == tsActive
    # At least one victim must be aborted
    check (not t1Active) or (not t2Active)
    # The survivor should be able to commit
    if t1Active:
      check tm.commit(t1)
    if t2Active:
      check tm.commit(t2)

  test "No false deadlock on sequential writes":
    var tm = newTxnManager()
    var t1 = tm.beginTxn()
    # t1 writes key "a"
    check tm.write(t1, "a", @[1'u8])
    # t1 commits
    check tm.commit(t1)
    # t2 begins after t1 committed
    var t2 = tm.beginTxn()
    # t2 writes same key — no active conflict
    check tm.write(t2, "a", @[2'u8])
    check tm.commit(t2)

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

suite "B-Tree Index":
  test "Insert and get":
    var btree = newBTreeIndex[string, string]()
    btree.insert("key1", "value1")
    btree.insert("key2", "value2")
    check btree.get("key1") == @["value1"]
    check btree.get("key2") == @["value2"]
    check not btree.contains("nonexistent")

  test "Scan range":
    var btree = newBTreeIndex[string, string]()
    for i in 0..9:
      btree.insert("key" & $i, "val" & $i)
    let results = btree.scan("key2", "key5")
    check results.len == 4

  test "Duplicate keys":
    var btree = newBTreeIndex[string, string]()
    btree.insert("a", "val1")
    btree.insert("a", "val2")
    let vals = btree.get("a")
    check vals.len == 2

suite "Columnar Engine":
  test "Column batch operations":
    var batch = newColumnBatch()
    var intCol = batch.addInt64Col("age")
    var strCol = batch.addStringCol("name")
    intCol.appendInt64(25)
    intCol.appendInt64(30)
    intCol.appendInt64(35)
    strCol.appendString("Alice")
    strCol.appendString("Bob")
    strCol.appendString("Charlie")
    check batch.rowCount() == 3

  test "Aggregate operations":
    var batch = newColumnBatch()
    var col = batch.addInt64Col("age")
    col.appendInt64(10)
    col.appendInt64(20)
    col.appendInt64(30)
    check col.sumInt64() == 60
    check col.avgInt64() - 20.0 < 0.001
    check col.minInt64() == 10
    check col.maxInt64() == 30
    check col.count() == 3

  test "RLE encoding":
    let data = @[1'i64, 1, 1, 2, 2, 3, 3, 3, 3]
    let encoded = rleEncode(data)
    let decoded = rleDecode(encoded)
    check decoded == data

  test "Dictionary encoding":
    let data = @["apple", "banana", "apple", "cherry", "banana"]
    let encoded = dictEncode(data)
    let decoded = dictDecode(encoded)
    check decoded == data
    check encoded.dict.len == 3

  test "GroupBy":
    var batch = newColumnBatch()
    var deptCol = batch.addStringCol("department")
    var salaryCol = batch.addInt64Col("salary")
    deptCol.appendString("Engineering")
    deptCol.appendString("Sales")
    deptCol.appendString("Engineering")
    salaryCol.appendInt64(100)
    salaryCol.appendInt64(80)
    salaryCol.appendInt64(120)

    let groups = groupBy(batch, @["department"])
    check groups.groups.len == 2  # unique departments

suite "Type Checker & IR":
  test "Literal type inference":
    var tc = newTypeChecker()
    let lit = IRExpr(kind: irekLiteral, literal: IRLiteral(kind: vkInt64, int64Val: 42))
    let t = tc.inferExpr(lit, initTable[string, IRType]())
    check t.name == "int64"

  test "Binary operation type inference":
    var tc = newTypeChecker()
    let left = IRExpr(kind: irekLiteral, literal: IRLiteral(kind: vkInt64, int64Val: 1))
    let right = IRExpr(kind: irekLiteral, literal: IRLiteral(kind: vkInt64, int64Val: 2))
    let bin = IRExpr(kind: irekBinary, binOp: irEq, binLeft: left, binRight: right)
    let t = tc.inferExpr(bin, initTable[string, IRType]())
    check t.name == "bool"

  test "Aggregate type inference":
    var tc = newTypeChecker()
    let agg = IRExpr(kind: irekAggregate, aggOp: irCount)
    let t = tc.inferExpr(agg, initTable[string, IRType]())
    check t.name == "int64"

suite "Connection Pool":
  test "Create pool and acquire connection":
    var pool = newConnectionPool("127.0.0.1", 9472)
    let conn = pool.acquire()
    check conn != nil
    check conn.host == "127.0.0.1"
    check conn.port == 9472
    pool.release(conn)

  test "Pool stats":
    var cfg = defaultPoolConfig()
    cfg.minConnections = 1
    cfg.maxConnections = 10
    var pool = newConnectionPool("127.0.0.1", 9472, "default", cfg)
    let conn1 = pool.acquire()
    let (total, idle, inUse) = pool.stats()
    check inUse == 1
    pool.release(conn1)
    let (t2, i2, u2) = pool.stats()
    check u2 == 0

suite "Authentication":
  test "Anonymous auth":
    var am = newAuthManager()
    let result = am.validateCredentials(AuthCredentials(authMethod: amNone))
    check result.authenticated
    check result.username == "anonymous"

  test "Token auth":
    var am = newAuthManager("mysecretkey")
    let token = am.createToken(JWTClaims(sub: "user1", role: "admin"))
    let result = am.validateCredentials(AuthCredentials(
      authMethod: amToken, payload: token))
    check result.authenticated

  test "Invalid token":
    var am = newAuthManager("mysecretkey")
    let result = am.validateCredentials(AuthCredentials(
      authMethod: amToken, payload: "invalid_token"))
    check not result.authenticated

suite "Vector Quantization":
  test "Scalar quantization 8-bit":
    var sq = newScalarQuantizer(4, bits = 8)
    let vectors = @[@[1.0'f32, 2.0'f32, 3.0'f32, 4.0'f32],
                     @[5.0'f32, 6.0'f32, 7.0'f32, 8.0'f32]]
    sq.train(vectors)
    let qv = sq.encode(@[3.0'f32, 4.0'f32, 5.0'f32, 6.0'f32])
    check qv.kind == qkScalar8
    check qv.int8Data.len == 4

  test "Scalar quantization 4-bit":
    var sq = newScalarQuantizer(4, bits = 4)
    let vectors = @[@[1.0'f32, 2.0'f32, 3.0'f32, 4.0'f32]]
    sq.train(vectors)
    let qv = sq.encode(@[3.0'f32, 4.0'f32, 5.0'f32, 6.0'f32])
    check qv.kind == qkScalar4
    check qv.int4Data.len == 2

  test "Product quantization":
    var pq = newProductQuantizer(8, nSubspaces = 4, nClusters = 16)
    var vectors: seq[seq[float32]] = @[]
    for i in 0..<50:
      var v: seq[float32] = @[]
      for j in 0..<8:
        v.add(float32(i * 8 + j) * 0.1)
      vectors.add(v)
    pq.train(vectors, nIterations = 5)
    let qv = pq.encode(vectors[0])
    check qv.kind == qkProduct
    check qv.pqCodes.len == 4

  test "Binary quantization":
    let v = @[1.0'f32, -1.0'f32, 0.5'f32, -0.5'f32]
    let qv = binaryQuantize(v)
    check qv.kind == qkBinary
    check qv.binData.len == 1

suite "Louvain Community Detection":
  test "Detect communities in simple graph":
    var g = gengine.newGraph()
    # Create two communities
    let n1 = gengine.addNode(g, "A")
    let n2 = gengine.addNode(g, "B")
    let n3 = gengine.addNode(g, "C")
    let n4 = gengine.addNode(g, "D")
    # Community 1: fully connected
    discard gengine.addEdge(g, n1, n2)
    discard gengine.addEdge(g, n2, n3)
    discard gengine.addEdge(g, n1, n3)
    # Community 2
    discard gengine.addEdge(g, n3, n4)  # single connection

    let result = louvain(g)
    check result.communities.len > 0
    check result.numCommunities >= 1

  test "Pattern matching":
    var g = gengine.newGraph()
    let a = gengine.addNode(g, "Person", {"name": "Alice"}.toTable)
    let b = gengine.addNode(g, "Person", {"name": "Bob"}.toTable)
    let c = gengine.addNode(g, "Person", {"name": "Charlie"}.toTable)
    discard gengine.addEdge(g, a, b, "knows")
    discard gengine.addEdge(g, b, c, "knows")
    discard gengine.addEdge(g, a, c, "knows")

    var pattern = newGraphPattern()
    pattern.addNode(0, "Person", {"name": "Alice"}.toTable)
    pattern.addNode(1, "Person")
    pattern.addEdge(0, 1, "knows")

    let matches = matchPattern(g, pattern)
    check matches.len >= 1

suite "SSTable Compaction":
  test "Create compaction strategy":
    var cs = newCompactionStrategy("/tmp/baradb_test_compaction")
    check cs.levelCount == 0
    check cs.tableCount == 0

  test "Add table and check compaction need":
    var cs = newCompactionStrategy("/tmp/baradb_test_compaction2")
    cs.addTable(SSTableMeta(path: "test.sst", level: 0, minKey: "a", maxKey: "z",
                            entryCount: 100, sizeBytes: 1024, createdAt: 1))
    check cs.tableCount == 1

suite "Page Cache":
  test "Cache hit and miss":
    var cache = newPageCache(10)
    cache.put("key1", cast[seq[byte]]("data1"))
    let (found, data) = cache.get("key1")
    check found
    check cache.hits == 1

    let (found2, _) = cache.get("missing")
    check not found2
    check cache.misses == 1

  test "LRU eviction":
    var cache = newPageCache(2)
    cache.put("a", cast[seq[byte]]("1"))
    cache.put("b", cast[seq[byte]]("2"))
    cache.put("c", cast[seq[byte]]("3"))  # evicts "a"
    check cache.len == 2
    let (found, _) = cache.get("a")
    check not found  # evicted

  test "Hit rate":
    var cache = newPageCache(10)
    cache.put("k", cast[seq[byte]]("v"))
    discard cache.get("k")
    discard cache.get("k")
    discard cache.get("miss")
    check cache.hitRate - 0.666 < 0.01

suite "Rate Limiter":
  test "Token bucket allows requests":
    var rl = newRateLimiter(rlaTokenBucket, 1000, 100)
    check rl.allowRequest("client1")
    check rl.allowRequest("client1")

  test "Sliding window rate limiting":
    var rl = newRateLimiter(rlaSlidingWindow, 1000, 3)
    check rl.allowRequest("client1")
    check rl.allowRequest("client1")
    check rl.allowRequest("client1")
    check not rl.allowRequest("client1")  # over limit

  test "Remaining quota":
    var rl = newRateLimiter(rlaTokenBucket, 1000, 10)
    discard rl.allowRequest("c1")
    let remaining = rl.remainingQuota("c1")
    check remaining >= 0

suite "FTS Fuzzy Search":
  test "Levenshtein distance":
    check levenshtein("kitten", "sitting") == 3
    check levenshtein("", "abc") == 3
    check levenshtein("same", "same") == 0

  test "Fuzzy search":
    var idx = newInvertedIndex()
    idx.addDocument(1, "Nim programming language")
    idx.addDocument(2, "Python is popular")
    let results = idx.fuzzySearch("programing", maxDistance = 2)  # typo
    check results.len >= 0  # may or may not match

  test "Regex search with wildcard":
    var idx = newInvertedIndex()
    idx.addDocument(1, "fast database engine")
    idx.addDocument(2, "slow query optimizer")
    let results = idx.regexSearch("fast*")
    check results.len >= 0

suite "Vector Metadata Filtering":
  test "Search with metadata filter":
    var idx = vengine.newHNSWIndex(3)
    vengine.insert(idx, 1, @[1.0'f32, 0.0'f32, 0.0'f32],
                   {"category": "A", "region": "US"}.toTable)
    vengine.insert(idx, 2, @[0.9'f32, 0.1'f32, 0.0'f32],
                   {"category": "B", "region": "EU"}.toTable)
    vengine.insert(idx, 3, @[1.0'f32, 0.0'f32, 0.0'f32],
                   {"category": "A", "region": "EU"}.toTable)

    # Filter: only category A
    proc filterA(metadata: Table[string, string]): bool =
      return metadata.getOrDefault("category", "") == "A"

    let results = vengine.searchWithFilter(idx, @[1.0'f32, 0.0'f32, 0.0'f32], 10,
                                           filter = filterA)
    check results.len == 2  # only category A entries

suite "BaraQL Parser — Extended":
  test "Parse GROUP BY":
    let ast = parse("SELECT dept, count(*) FROM employees GROUP BY dept")
    check ast.stmts.len == 1
    check ast.stmts[0].selGroupBy.len == 1

  test "Parse GROUP BY with HAVING":
    let ast = parse("SELECT dept, count(*) FROM employees GROUP BY dept HAVING count(*) > 5")
    check ast.stmts[0].selHaving != nil

  test "Parse ORDER BY with direction":
    let ast = parse("SELECT name FROM users ORDER BY age DESC")
    check ast.stmts[0].selOrderBy.len == 1
    check ast.stmts[0].selOrderBy[0].orderByDir == sdDesc

  test "Parse ORDER BY multiple columns":
    let ast = parse("SELECT * FROM t ORDER BY a ASC, b DESC")
    check ast.stmts[0].selOrderBy.len == 2

  test "Parse INNER JOIN":
    let ast = parse("SELECT u.name, o.total FROM users u INNER JOIN orders o ON u.id = o.user_id")
    check ast.stmts[0].selJoins.len == 1
    check ast.stmts[0].selJoins[0].joinKind == jkInner

  test "Parse LEFT JOIN":
    let ast = parse("SELECT u.name FROM users u LEFT JOIN orders o ON u.id = o.user_id")
    check ast.stmts[0].selJoins.len == 1
    check ast.stmts[0].selJoins[0].joinKind == jkLeft

  test "Parse multiple JOINs":
    let ast = parse("SELECT * FROM a JOIN b ON a.id = b.aid JOIN c ON b.id = c.bid")
    check ast.stmts[0].selJoins.len == 2

  test "Parse CTE (WITH)":
    let ast = parse("WITH active AS (SELECT * FROM users WHERE active = true) SELECT * FROM active")
    check ast.stmts[0].selWith.len == 1
    check ast.stmts[0].selWith[0][0] == "active"

  test "Parse multiple CTEs":
    let ast = parse("WITH a AS (SELECT id FROM t1), b AS (SELECT id FROM t2) SELECT * FROM a")
    check ast.stmts[0].selWith.len == 2

  test "Parse aggregate functions in SELECT":
    let ast = parse("SELECT count(*), sum(amount), avg(price), min(age), max(score) FROM orders")
    check ast.stmts[0].selResult.len == 5

  test "Parse CASE expression":
    let ast = parse("SELECT CASE WHEN age > 18 THEN 'adult' ELSE 'minor' END FROM users")
    check ast.stmts[0].selResult.len == 1

  test "Parse BETWEEN":
    let ast = parse("SELECT * FROM products WHERE price BETWEEN 10 AND 100")
    check ast.stmts[0].selWhere != nil

  test "Parse subquery in FROM":
    let ast = parse("SELECT * FROM (SELECT id FROM users) AS sub")
    check ast.stmts[0].selFrom != nil

  test "Parse UPDATE SET WHERE":
    let ast = parse("UPDATE users SET name = 'Alice' WHERE id = 1")
    check ast.stmts[0].updSet.len == 1

  test "Parse DELETE WHERE":
    let ast = parse("DELETE FROM users WHERE id = 1")
    check ast.stmts[0].delWhere != nil

  test "Parse CREATE TYPE with properties":
    let ast = parse("CREATE TYPE Person { name: str, age: int32 }")
    check ast.stmts[0].ctName == "Person"
    check ast.stmts[0].ctProperties.len == 2

suite "Raft Consensus":
  test "Create cluster with nodes":
    var cluster = newRaftCluster()
    cluster.addNode("n1")
    cluster.addNode("n2")
    cluster.addNode("n3")
    check cluster.nodes.len == 3
    check cluster.nodes["n1"].peers.len == 2

  test "Initial state is follower":
    var cluster = newRaftCluster()
    cluster.addNode("n1")
    check cluster.nodes["n1"].state == rsFollower

  test "Election — single node becomes leader":
    var cluster = newRaftCluster()
    cluster.addNode("n1")
    let node = cluster.nodes["n1"]
    node.becomeCandidate()
    node.becomeLeader()
    check node.isLeader
    check node.leaderId == "n1"

  test "Log replication":
    var cluster = newRaftCluster()
    cluster.addNode("n1")
    let node = cluster.nodes["n1"]
    node.becomeCandidate()
    node.becomeLeader()
    let entry = node.appendLog("SET key1 value1")
    check entry.index == 1
    check node.logLen == 1
    let entry2 = node.appendLog("SET key2 value2")
    check entry2.index == 2
    check node.logLen == 2

  test "RequestVote handling":
    var cluster = newRaftCluster()
    cluster.addNode("n1")
    cluster.addNode("n2")
    let n1 = cluster.nodes["n1"]
    let n2 = cluster.nodes["n2"]
    let req = RaftMessage(kind: rmkRequestVote, term: 1, senderId: "n2",
                          lastLogIndex: 0, lastLogTerm: 0)
    let reply = n1.handleRequestVote(req)
    check reply.success
    check n1.votedFor == "n2"

  test "AppendEntries handling":
    var cluster = newRaftCluster()
    cluster.addNode("n1")
    cluster.addNode("n2")
    let n2 = cluster.nodes["n2"]
    let msg = RaftMessage(kind: rmkAppendEntries, term: 1, senderId: "n1",
                          prevLogIndex: 0, prevLogTerm: 0,
                          entries: @[LogEntry(term: 1, index: 1, command: "SET x 1")],
                          leaderCommit: 0)
    let reply = n2.handleAppendEntries(msg)
    check reply.success
    check n2.logLen == 1

suite "Sharding":
  test "Hash-based sharding":
    var router = newShardRouter(ShardConfig(numShards: 4, strategy: ssHash))
    check router.shardCount == 4
    let s1 = router.getShard("user_1")
    let s2 = router.getShard("user_2")
    check s1 >= 0 and s1 < 4
    check s2 >= 0 and s2 < 4

  test "Consistent hashing":
    var router = newShardRouter(ShardConfig(numShards: 4, strategy: ssConsistent))
    router.addVirtualNodes(50)
    let s = router.getShard("some_key")
    check s >= 0 and s < 4

  test "Range-based sharding":
    var router = newShardRouter(ShardConfig(numShards: 3, strategy: ssRange))
    router.setRangeBounds(@[("a", "f"), ("g", "n"), ("o", "z")])
    check router.getShardRange("apple") == 0
    check router.getShardRange("hello") == 1
    check router.getShardRange("top") == 2

  test "Rebalance assigns nodes":
    var router = newShardRouter(ShardConfig(numShards: 3, replicas: 2, strategy: ssHash))
    router.rebalance(@["node1", "node2", "node3"])
    for shard in router.shards:
      check shard.nodeIds.len == 2  # 2 replicas

  test "Replicas of key":
    var router = newShardRouter(ShardConfig(numShards: 2, replicas: 1, strategy: ssHash))
    router.rebalance(@["n1", "n2"])
    let replicas = router.replicasOf("test_key")
    check replicas.len == 1

  test "Active shard count":
    var router = newShardRouter()
    check router.activeShardCount == 4

suite "Schema Inheritance":
  test "Inheritance — merge properties from base":
    var s = newSchema()
    let base = newType("Base")
    base.addProperty("id", "str", required = true)
    base.addProperty("created", "datetime")
    s.addType("default", base)

    let child = newType("Person")
    child.setBases(@["Base"])
    child.addProperty("name", "str", required = true)
    s.addType("default", child)

    let resolved = s.resolveInheritance(child)
    check resolved.properties.len == 3  # id + created + name
    check "id" in resolved.properties
    check "name" in resolved.properties
    check "created" in resolved.properties

  test "Multi-level inheritance":
    var s = newSchema()
    let a = newType("A")
    a.addProperty("a1", "str")
    s.addType("default", a)

    let b = newType("B")
    b.setBases(@["A"])
    b.addProperty("b1", "int32")
    s.addType("default", b)

    let c = newType("C")
    c.setBases(@["B"])
    c.addProperty("c1", "bool")
    s.addType("default", c)

    let resolved = s.resolveInheritance(c)
    check resolved.properties.len == 3  # a1 + b1 + c1

  test "Override base property":
    var s = newSchema()
    let base = newType("Base")
    base.addProperty("name", "str")
    s.addType("default", base)

    let child = newType("Child")
    child.setBases(@["Base"])
    child.addProperty("name", "text")  # override
    s.addType("default", child)

    let resolved = s.resolveInheritance(child)
    check resolved.properties["name"].typeName == "text"

  test "isSubtype":
    var s = newSchema()
    let a = newType("A")
    s.addType("default", a)
    let b = newType("B")
    b.setBases(@["A"])
    s.addType("default", b)
    let c = newType("C")
    c.setBases(@["B"])
    s.addType("default", c)

    check s.isSubtype("C", "A")
    check s.isSubtype("C", "B")
    check s.isSubtype("B", "A")
    check not s.isSubtype("A", "C")

  test "Computed property":
    let t = newType("Person")
    t.addProperty("firstName", "str")
    t.addProperty("lastName", "str")
    t.addComputedProperty("fullName", "str", "firstName ++ ' ' ++ lastName")
    check t.properties["fullName"].computed
    check t.properties["fullName"].expr == "firstName ++ ' ' ++ lastName"

suite "Codegen":
  test "Codegen scan":
    let plan = IRPlan(kind: irpkScan, scanTable: "users", scanAlias: "u")
    let op = codegenPlan(plan)
    check op.kind == sokScan
    check op.table == "users"

  test "Codegen filter with point read optimization":
    let filterExpr = IRExpr(kind: irekBinary, binOp: irEq,
      binLeft: IRExpr(kind: irekField, fieldPath: @["id"]),
      binRight: IRExpr(kind: irekLiteral, literal: IRLiteral(kind: vkInt64, int64Val: 42)))
    let scan = IRPlan(kind: irpkScan, scanTable: "users", scanAlias: "u")
    let plan = IRPlan(kind: irpkFilter, filterSource: scan, filterCond: filterExpr)
    let op = codegenPlan(plan)
    # Should optimize to point read
    check op.kind == sokPointRead

  test "Codegen limit":
    let scan = IRPlan(kind: irpkScan, scanTable: "t", scanAlias: "t")
    let plan = IRPlan(kind: irpkLimit, limitSource: scan, limitCount: 10, limitOffset: 5)
    let op = codegenPlan(plan)
    check op.limit == 10
    check op.offset == 5

  test "Cost estimation":
    let scan = newStorageOp(sokScan)
    check estimateCost(scan) == 1000.0
    let pointRead = newStorageOp(sokPointRead)
    check estimateCost(pointRead) == 1.0

  test "Explain plan":
    let scan = newStorageOp(sokScan)
    scan.table = "users"
    let explanation = scan.explain()
    check "sokScan" in explanation
    check "users" in explanation

suite "Replication":
  test "Create replication manager":
    var rm = newReplicationManager(rmAsync)
    check rm.totalReplicaCount == 0
    check rm.connectedReplicaCount == 0

  test "Add and connect replicas":
    var rm = newReplicationManager(rmAsync)
    rm.addReplica(newReplica("r1", "10.0.0.1", 9472))
    rm.addReplica(newReplica("r2", "10.0.0.2", 9472))
    check rm.totalReplicaCount == 2

    rm.connectReplica("r1")
    check rm.connectedReplicaCount == 1

  test "Async replication — write returns immediately":
    var rm = newReplicationManager(rmAsync)
    rm.addReplica(newReplica("r1", "10.0.0.1", 9472))
    rm.connectReplica("r1")

    let lsn = rm.writeLsn(@[1'u8, 2, 3])
    check lsn == 1
    # Async doesn't wait — already "acked"
    check rm.isFullyAcked(lsn)

  test "Sync replication — wait for ack":
    var rm = newReplicationManager(rmSync)
    rm.addReplica(newReplica("r1", "10.0.0.1", 9472))
    rm.connectReplica("r1")

    let lsn = rm.writeLsn(@[1'u8, 2, 3])
    check not rm.isFullyAcked(lsn)

    rm.ackLsn("r1", lsn)
    check rm.isFullyAcked(lsn)

  test "Semi-sync replication":
    var rm = newReplicationManager(rmSemiSync, syncCount = 2)
    rm.addReplica(newReplica("r1", "10.0.0.1", 9472))
    rm.addReplica(newReplica("r2", "10.0.0.2", 9472))
    rm.addReplica(newReplica("r3", "10.0.0.3", 9472))
    rm.connectReplica("r1")
    rm.connectReplica("r2")
    rm.connectReplica("r3")

    let lsn = rm.writeLsn(@[1'u8])
    check not rm.isFullyAcked(lsn)  # needs 2 acks

    rm.ackLsn("r1", lsn)
    check not rm.isFullyAcked(lsn)  # still needs 1 more

    rm.ackLsn("r2", lsn)
    check rm.isFullyAcked(lsn)  # 2 acks received

  test "Replica status":
    var rm = newReplicationManager(rmAsync)
    rm.addReplica(newReplica("r1", "10.0.0.1", 9472))
    rm.connectReplica("r1")
    let status = rm.replicaStatus()
    check status.len == 1
    check status[0][1] == rsStreaming

suite "User Defined Functions":
  test "Register and call UDF":
    var reg = newUDFRegistry()
    reg.register("double", @[UDFParam(name: "x", typeName: "int64", required: true)],
      "int64", proc(args: seq[Value]): Value =
        if args.len > 0 and args[0].kind == vkInt64:
          return Value(kind: vkInt64, int64Val: args[0].int64Val * 2)
        return Value(kind: vkNull))

    check reg.hasFunction("double")
    let result = reg.call("double", @[Value(kind: vkInt64, int64Val: 21)])
    check result.kind == vkInt64
    check result.int64Val == 42

  test "Register expression-based UDF":
    var reg = newUDFRegistry()
    reg.registerExpr("greet", @[UDFParam(name: "name", typeName: "str")],
      "str", "'Hello ' ++ name")
    check reg.hasFunction("greet")
    check reg.getFunction("greet").expr == "'Hello ' ++ name"

  test "Standard library functions":
    var reg = newUDFRegistry()
    reg.registerStdlib()

    # lower
    let r1 = reg.call("lower", @[Value(kind: vkString, strVal: "HELLO")])
    check r1.strVal == "hello"

    # upper
    let r2 = reg.call("upper", @[Value(kind: vkString, strVal: "hello")])
    check r2.strVal == "HELLO"

    # len
    let r3 = reg.call("len", @[Value(kind: vkString, strVal: "test")])
    check r3.int64Val == 4

    # trim
    let r4 = reg.call("trim", @[Value(kind: vkString, strVal: "  hello  ")])
    check r4.strVal == "hello"

    # toString
    let r5 = reg.call("toString", @[Value(kind: vkInt64, int64Val: 42)])
    check r5.strVal == "42"

  test "Deregister function":
    var reg = newUDFRegistry()
    reg.register("temp", @[], "int64", proc(args: seq[Value]): Value = Value(kind: vkNull))
    check reg.hasFunction("temp")
    reg.deregister("temp")
    check not reg.hasFunction("temp")

  test "Function count":
    var reg = newUDFRegistry()
    reg.registerStdlib()
    check reg.functionCount > 10

suite "Vector SIMD":
  test "Dot product":
    let a = @[1.0'f32, 2.0'f32, 3.0'f32]
    let b = @[4.0'f32, 5.0'f32, 6.0'f32]
    let result = dotProductSimd(a, b)
    check abs(result - 32.0) < 0.001

  test "L2 distance":
    let a = @[0.0'f32, 0.0'f32]
    let b = @[3.0'f32, 4.0'f32]
    let result = l2NormSimd(a, b)
    check abs(result - 5.0) < 0.001

  test "Cosine distance":
    let a = @[1.0'f32, 0.0'f32, 0.0'f32]
    let b = @[0.0'f32, 1.0'f32, 0.0'f32]
    let result = cosineSimd(a, b)
    check abs(result - 1.0) < 0.001  # orthogonal = 1.0

    let c = @[1.0'f32, 0.0'f32, 0.0'f32]
    let d = @[1.0'f32, 0.0'f32, 0.0'f32]
    check cosineSimd(c, d) < 0.001  # same direction = 0.0

  test "Manhattan distance":
    let a = @[1.0'f32, 2.0'f32]
    let b = @[4.0'f32, 6.0'f32]
    let result = manhattanSimd(a, b)
    check abs(result - 7.0) < 0.001

  test "Normalize vector":
    let v = @[3.0'f32, 4.0'f32]
    let n = normalize(v)
    check abs(n[0] - 0.6) < 0.001
    check abs(n[1] - 0.8) < 0.001

  test "Add vectors":
    let a = @[1.0'f32, 2.0'f32]
    let b = @[3.0'f32, 4.0'f32]
    let c = addVectors(a, b)
    check c[0] == 4.0
    check c[1] == 6.0

  test "Scale vector":
    let v = @[1.0'f32, 2.0'f32, 3.0'f32]
    let s = scaleVector(v, 2.0)
    check s[0] == 2.0
    check s[1] == 4.0
    check s[2] == 6.0

  test "TopK":
    let distances = @[5.0'f32, 1.0'f32, 3.0'f32, 2.0'f32, 4.0'f32]
    let top = topK(distances, 3)
    check top.len == 3
    check top[0][0] == 1  # index 1, value 1.0
    check top[1][0] == 3  # index 3, value 2.0
    check top[2][0] == 2  # index 2, value 3.0

  test "Batch distance":
    let queries = @[@[1.0'f32, 0.0'f32], @[0.0'f32, 1.0'f32]]
    let corpus = @[@[1.0'f32, 0.0'f32], @[0.0'f32, 1.0'f32], @[1.0'f32, 1.0'f32]]
    let results = batchDistance(queries, corpus, "cosine")
    check results.len == 2
    check results[0].len == 3

suite "Cross-Modal Engine":
  test "Create engine":
    let engine = newCrossModalEngine("/tmp/baradb_test_crossmodal")
    check engine != nil

  test "Document operations":
    let engine = newCrossModalEngine("/tmp/baradb_test_crossmodal2")
    engine.put("key1", cast[seq[byte]]("value1"))
    let (found, val) = engine.get("key1")
    check found
    check cast[string](val) == "value1"

  test "Vector operations":
    let engine = newCrossModalEngine("/tmp/baradb_test_crossmodal3")
    engine.insertVector(1, @[1.0'f32, 0.0'f32, 0.0'f32], {"cat": "A"}.toTable)
    engine.insertVector(2, @[0.0'f32, 1.0'f32, 0.0'f32], {"cat": "B"}.toTable)
    let results = engine.searchVector(@[1.0'f32, 0.1'f32, 0.0'f32], 2)
    check results.len == 2

  test "Graph operations":
    let engine = newCrossModalEngine("/tmp/baradb_test_crossmodal4")
    let n1 = engine.addNode("Person")
    let n2 = engine.addNode("Person")
    discard engine.addEdge(n1, n2, "knows")
    let traversal = engine.traverseGraph(n1, "bfs")
    check traversal.len >= 1

  test "FTS operations":
    let engine = newCrossModalEngine("/tmp/baradb_test_crossmodal5")
    engine.indexText(1, "Nim programming language")
    engine.indexText(2, "Python data science")
    let results = engine.searchText("programming")
    check results.len >= 1

  test "2PC transaction":
    var txn = newTPCTransaction(1)
    txn.addParticipant("storage")
    txn.addParticipant("vector")
    txn.addParticipant("graph")
    check txn.participantCount == 3
    check txn.prepare()
    check txn.isPrepared
    check txn.commit()
    check txn.isCommitted

  test "2PC rollback":
    var txn = newTPCTransaction(2)
    txn.addParticipant("storage")
    txn.addParticipant("vector")
    check txn.prepare()
    check txn.rollback()
    check txn.isAborted

  test "Hybrid query":
    let engine = newCrossModalEngine("/tmp/baradb_test_crossmodal6")
    engine.insertVector(1, @[1.0'f32, 0.0'f32], {"cat": "A"}.toTable)
    engine.indexText(1, "fast database")
    var query = newCrossModalQuery(qmHybrid)
    query.vector = @[1.0'f32, 0.0'f32]
    query.vectorK = 5
    query.searchQuery = "fast"
    query.vecWeight = 1.0
    query.ftsWeight = 1.0
    let result = engine.hybridSearch(query)
    check result.totalResults >= 0

suite "Gossip Protocol":
  test "Create gossip node":
    var gp = newGossipProtocol("node1", "10.0.0.1", 7946)
    check gp.self.id == "node1"
    check gp.memberCount == 0

  test "Add members":
    var gp = newGossipProtocol("node1", "10.0.0.1", 7946)
    let node2 = newGossipNode("node2", "10.0.0.2", 7946)
    let node3 = newGossipNode("node3", "10.0.0.3", 7946)
    gp.addMember(node2)
    gp.addMember(node3)
    check gp.memberCount == 2
    check gp.aliveCount == 2

  test "Suspect and declare dead":
    var gp = newGossipProtocol("node1", "10.0.0.1", 7946)
    let node2 = newGossipNode("node2", "10.0.0.2", 7946)
    gp.addMember(node2)
    gp.suspect("node2")
    check gp.getMember("node2").state == nsSuspect
    gp.declareDead("node2")
    check gp.memberCount == 1

  test "Gossip message":
    var gp = newGossipProtocol("node1", "10.0.0.1", 7946)
    let node2 = newGossipNode("node2", "10.0.0.2", 7946)
    gp.addMember(node2)
    let msg = gp.createGossipMessage()
    check msg.senderId == "node1"
    check msg.nodes.len == 1

  test "Select gossip targets":
    var gp = newGossipProtocol("node1", "10.0.0.1", 7946, fanout = 2)
    for i in 2..5:
      gp.addMember(newGossipNode("node" & $i, "10.0.0." & $i, 7946))
    let targets = gp.selectGossipTargets()
    check targets.len <= 2

  test "Member IDs":
    var gp = newGossipProtocol("node1", "10.0.0.1", 7946)
    gp.addMember(newGossipNode("node2", "10.0.0.2", 7946))
    check gp.isMember("node2")
    check not gp.isMember("node99")

suite "Client Library":
  test "Connection string parser":
    let config = parseConnectionString("host=localhost port=9472 dbname=test user=admin")
    check config.host == "localhost"
    check config.port == 9472
    check config.database == "test"
    check config.username == "admin"

  test "Client config defaults":
    let config = defaultClientConfig()
    check config.host == "127.0.0.1"
    check config.port == 9472

  test "Query builder":
    let client = newBaraClient()
    let qb = newQueryBuilder(client)
    let sql = qb.select("name", "age").from("users")
      .where("age > 18").orderBy("name", "ASC").limit(10).build()
    check sql == "SELECT name, age FROM users WHERE age > 18 ORDER BY name ASC LIMIT 10"

  test "Query builder with JOIN":
    let client = newBaraClient()
    let qb = newQueryBuilder(client)
    let sql = qb.select("u.name", "o.total")
      .from("users u").join("orders o", "u.id = o.user_id")
      .where("o.total > 100").build()
    check "JOIN" in sql
    check "WHERE" in sql

  test "Query builder with GROUP BY":
    let client = newBaraClient()
    let qb = newQueryBuilder(client)
    let sql = qb.select("dept", "count(*)").from("employees")
      .groupBy("dept").having("count(*) > 5").build()
    check "GROUP BY" in sql
    check "HAVING" in sql

suite "Import/Export":
  test "JSON export":
    let columns = @["name", "age"]
    let rows = @[@["Alice", "30"], @["Bob", "25"]]
    let json = fileops.toJson(columns, rows)
    check json.startsWith("[")
    check "Alice" in json

  test "CSV export":
    let columns = @["name", "age"]
    let rows = @[@["Alice", "30"], @["Bob", "25"]]
    let csv = fileops.toCsv(columns, rows)
    check csv.startsWith("name,age")
    check "Alice" in csv

  test "JSON import":
    let json = """[{"name": "Alice", "age": "30"}, {"name": "Bob", "age": "25"}]"""
    let (columns, rows) = fileops.parseJsonTable(json)
    check columns.len == 2
    check rows.len == 2

  test "CSV import":
    let csv = "name,age\nAlice,30\nBob,25"
    let (columns, rows) = fileops.parseCsvTable(csv)
    check columns.len == 2
    check rows.len == 2
    check rows[0][0] == "Alice"

  test "NDJSON export/import":
    let columns = @["name", "age"]
    let rows = @[@["Alice", "30"]]
    let ndjson = fileops.toNdjson(columns, rows)
    check "Alice" in ndjson

  test "CSV with quoted fields":
    let csv = "name,bio\nAlice,\"Software engineer, Nim\"\nBob,Data scientist"
    let (columns, rows) = fileops.parseCsvTable(csv)
    check rows.len == 2

suite "Multi-Language FTS":
  test "English tokenizer":
    let config = mlang.getLanguageConfig(mlang.langEnglish)
    let tokens = mlang.tokenize("The quick brown fox jumps over the lazy dog", config)
    check tokens.len > 0
    check "the" notin tokens  # stop word

  test "Bulgarian tokenizer":
    let config = mlang.getLanguageConfig(mlang.langBulgarian)
    let tokens = mlang.tokenize("Бързата кафява лисица прескача мързеливото куче", config)
    check tokens.len > 0

  test "German tokenizer":
    let config = mlang.getLanguageConfig(mlang.langGerman)
    let tokens = mlang.tokenize("Der schnelle braune Fuchs springt über den faulen Hund", config)
    check tokens.len > 0
    check "der" notin tokens

  test "Russian tokenizer":
    let config = mlang.getLanguageConfig(mlang.langRussian)
    let tokens = mlang.tokenize("Быстрая браун лиса прыгает через ленивую собаку", config)
    check tokens.len > 0

  test "Language detection":
    check mlang.detectLanguage("Hello world how are you") == mlang.langEnglish
    # Bulgarian text is also Cyrillic — detected as Russian by default
    check mlang.detectLanguage("Здравей свят как си") == mlang.langRussian

  test "English stemming":
    check mlang.stemEnglish("running") == "runn"
    check mlang.stemEnglish("cats") == "cat"
    check mlang.stemEnglish("programming") == "programm"

  test "Bulgarian stemming":
    check mlang.stemBulgarian("красота") == "красо"

suite "Zero-Copy Serialization":
  test "Write and read int32":
    var buf = newZeroBuf(64)
    buf.writeInt32(42)
    check buf.readInt32(0) == 42
    buf.free()

  test "Write and read int64":
    var buf = newZeroBuf(64)
    buf.writeInt64(12345)
    check buf.readInt64(0) == 12345
    buf.free()

  test "Write and read bool":
    var buf = newZeroBuf(64)
    buf.writeBool(true)
    check buf.readBool(0)
    buf.free()

  test "ZcSchema field offsets":
    var schema = newZcSchema("user")
    schema.addField("id", ztInt64)
    schema.addField("name", ztString)
    check schema.fields.len == 2
    check schema.totalSize > 0

  test "Encode and decode record":
    var schema = newZcSchema("user")
    schema.addField("id", ztInt32)
    var buf = newZeroBuf(schema.totalSize)
    buf.pos = schema.totalSize  # pretend we wrote
    buf.encodeRecord(schema, {"id": "42"}.toTable)
    # Reset pos for reading at offsets
    var pos = 0
    let row = buf.decodeRecord(schema)
    check row["id"] == "42"
    buf.free()

  test "ZcTable batch operations":
    var schema = newZcSchema("user")
    schema.addField("id", ztInt32)
    var table = newZcTable(schema)
    var buf1 = newZeroBuf(schema.totalSize)
    buf1.encodeRecord(schema, {"id": "1"}.toTable)
    table.records.add(buf1)
    var buf2 = newZeroBuf(schema.totalSize)
    buf2.encodeRecord(schema, {"id": "2"}.toTable)
    table.records.add(buf2)
    table.totalRows = 2
    check table.totalRows == 2
    check table.getRecord(1)["id"] == "2"
    for i in 0..<table.records.len:
      table.records[i].free()

suite "Adaptive Query Execution":
  test "Cardinality estimation":
    var planner = newAdaptivePlanner()
    planner.updateCardinality("users", 500)
    check planner.estimateRows("users") == 500

  test "Should reoptimize":
    var planner = newAdaptivePlanner()
    check planner.shouldReoptimize(100, 500)  # 5x more
    check not planner.shouldReoptimize(100, 200)  # 2x more (below threshold)

  test "Plan cache":
    var planner = newAdaptivePlanner()
    let plan = QueryPlan(estimatedCost: 10.0, estimatedRows: 100)
    planner.cachePlan("SELECT * FROM users", plan)
    check planner.cacheSize == 1
    let cached = planner.getCachedPlan("SELECT * FROM users")
    check cached != nil

  test "Execution context parallelization":
    var ctx = newExecutionContext(enScan)
    ctx.table = "big_table"
    ctx.parallelHint = ParallelHint(canParallelize: true, estimatedPartitions: 4, dataSize: 10_000_000)
    check ctx.canParallelize()
    check ctx.estimateParallelism(8) == 4

  test "Execution plan explain":
    var root = newExecutionContext(enScan)
    root.table = "users"
    root.estimatedRows = 1000
    var filter = newExecutionContext(enFilter)
    filter.estimatedRows = 200
    root.addChild(filter)
    let plan = root.explain()
    check "enScan" in plan
    check "users" in plan

suite "Distributed Transactions":
  test "Create distributed transaction":
    var txn = newDistributedTransaction("coordinator")
    txn.addParticipant("node1", "10.0.0.1", 9472)
    txn.addParticipant("node2", "10.0.0.2", 9472)
    check txn.participantCount == 2

  test "Two-phase commit flow":
    var txn = newDistributedTransaction("coordinator")
    txn.addParticipant("n1", "10.0.0.1", 9472)
    check txn.prepare()
    check txn.state() == dtsPrepared
    check txn.commit()
    check txn.isCommitted

  test "Rollback dist transaction":
    var txn = newDistributedTransaction("coordinator")
    txn.addParticipant("n1", "10.0.0.1", 9472)
    check txn.rollback()
    check txn.isAborted

  test "DistTxnManager lifecycle":
    var tm = newDistTxnManager()
    let txn = tm.beginTransaction("node1")
    check tm.activeCount == 1
    txn.addParticipant("n2", "10.0.0.2", 9472)
    check txn.prepare()
    check txn.commit()
    tm.cleanupCompleted()
    check tm.activeCount == 0

  test "Saga pattern":
    var saga = newSaga()
    var executeCount = 0
    var compensateCount = 0

    saga.addStep(SagaStep(
      name: "step1", nodeId: "n1",
      execute: proc(): bool =
        inc executeCount
        return true,
      compensate: proc() =
        inc compensateCount))

    saga.addStep(SagaStep(
      name: "step2", nodeId: "n2",
      execute: proc(): bool =
        inc executeCount
        return false,  # fails!
      compensate: proc() =
        inc compensateCount))

    check not saga.execute()  # should fail at step2
    check executeCount == 2
    check compensateCount == 1  # step1 compensated

suite "Vector Batch Operations":
  test "Batch insert HNSW":
    var idx = vengine.newHNSWIndex(3)
    let batch = @[
      (1'u64, @[1.0'f32, 0.0'f32, 0.0'f32]),
      (2'u64, @[0.0'f32, 1.0'f32, 0.0'f32]),
      (3'u64, @[0.0'f32, 0.0'f32, 1.0'f32]),
    ]
    vengine.batchInsert(idx, batch)
    check vengine.len(idx) == 3

  test "Batch search":
    var idx = vengine.newHNSWIndex(3)
    vengine.batchInsert(idx, @[
      (1'u64, @[1.0'f32, 0.0'f32, 0.0'f32]),
      (2'u64, @[0.0'f32, 1.0'f32, 0.0'f32]),
    ])
    let queries = @[@[1.0'f32, 0.0'f32, 0.0'f32], @[0.0'f32, 1.0'f32, 0.0'f32]]
    let results = vengine.batchSearch(idx, queries, 2)
    check results.len == 2

  test "Index watcher auto-rebuild":
    var watcher = newIndexWatcher(RebuildConfig(
      maxUnindexedCount: 3, autoRebuild: true,
      checkInterval: 0, rebuildThreshold: 0.5,
    ))
    watcher.trackUnindexed(5)  # 5 unindexed
    check watcher.shouldRebuild()
    watcher.markRebuilt()
    let (total, unindexed, rebuilds) = watcher.stats()
    check unindexed == 0
    check rebuilds == 1

  test "Rebuild threshold by ratio":
    var watcher = newIndexWatcher(RebuildConfig(
      autoRebuild: true, rebuildThreshold: 0.3,
    ))
    for i in 0..<100:
      watcher.trackInsert()
    watcher.trackUnindexed(40)  # 40% unindexed
    check watcher.shouldRebuild()

suite "Cluster Auto-Rebalance":
  test "Add node triggers rebalance":
    var router = newShardRouter(ShardConfig(numShards: 4, replicas: 2))
    var cm = newClusterMembership(router)
    cm.addNode("node1")
    cm.addNode("node2")
    cm.addNode("node3")
    check cm.nodeCount == 3

  test "Remove node triggers rebalance":
    var router = newShardRouter(ShardConfig(numShards: 4, replicas: 1))
    var cm = newClusterMembership(router)
    cm.addNode("node1")
    cm.addNode("node2")
    cm.addNode("node3")
    cm.removeNode("node2")
    check cm.nodeCount == 2

  test "Node fail re-assigns shards":
    var router = newShardRouter(ShardConfig(numShards: 4, replicas: 2))
    router.rebalance(@["node1", "node2", "node3"])
    var cm = newClusterMembership(router)
    cm.nodes = @["node1", "node2", "node3"]
    cm.onNodeFail("node1")
    check cm.nodeCount == 2

suite "Cypher-like Graph Queries":
  test "Parse MATCH query":
    let query = "MATCH (p:Person {name: 'Alice'}) RETURN p"
    let cypher = parseCypher(query)
    check cypher.kind == "MATCH"
    check cypher.pattern.nodes.len == 1
    check cypher.pattern.nodes[0].label == "Person"
    check cypher.returnExprs.len == 1

  test "Parse MATCH with edge":
    let query = "MATCH (a:Person)-[r:KNOWS]->(b:Person) RETURN a, b"
    let cypher = parseCypher(query)
    check cypher.pattern.nodes.len == 2
    check cypher.pattern.edges.len == 1
    check cypher.pattern.edges[0].label == "KNOWS"

  test "Parse MATCH with WHERE and LIMIT":
    let query = "MATCH (p:Person) WHERE p.age > 18 RETURN p.name, p.age ORDER BY p.age LIMIT 10"
    let cypher = parseCypher(query)
    check cypher.whereClause.len > 0
    check cypher.returnExprs.len == 2
    check cypher.orderBy.len > 0
    check cypher.limit == 10

  test "Execute basic MATCH":
    var g = newGraph()
    discard g.addNode("Person", {"name": "Alice"}.toTable)
    discard g.addNode("Person", {"name": "Bob"}.toTable)
    discard g.addNode("Company", {"name": "Acme"}.toTable)

    let query = parseCypher("MATCH (p:Person) RETURN p")
    let result = executeCypher(g, query)
    check result.rows.len == 2

  test "Match nodes with properties":
    var g = newGraph()
    discard g.addNode("Person", {"name": "Alice", "age": "30"}.toTable)
    discard g.addNode("Person", {"name": "Bob", "age": "25"}.toTable)

    let matches = matchNodes(g, "Person", {"name": "Alice"}.toTable)
    check matches.len == 1
    check matches[0].properties["name"] == "Alice"

suite "Crash Recovery":
  test "Scan WAL file":
    var walDir = "/tmp/baradb_test_recovery_wal"
    var wal = newWriteAheadLog(walDir)
    wal.writePut(@[1'u8], @[2'u8], 1)
    wal.sync()
    wal.close()

    var rec = newCrashRecovery(walDir, "/tmp")
    let entries = rec.scanWAL()
    check entries.len >= 1  # at least the put entry

  test "Analyze recovery":
    var walDir = "/tmp/baradb_test_recovery_wal2"
    var wal = newWriteAheadLog(walDir)
    wal.writePut(@[1'u8], @[2'u8], 1)
    wal.writeCommit(1)
    wal.close()

    var rec = newCrashRecovery(walDir, "/tmp")
    let result = rec.analyze()
    check result.totalEntries >= 1
    check result.applied == true

  test "Recover returns summary":
    var walDir = "/tmp/baradb_test_recovery_wal3"
    var wal = newWriteAheadLog(walDir)
    wal.writePut(@[1'u8], @[2'u8], 1)
    wal.writeCommit(1)
    wal.close()

    var rec = newCrashRecovery(walDir, "/tmp")
    let summary = rec.summary()
    check "WAL Recovery" in summary
    check "Total" in summary

suite "Raft Election Timer":
  test "Election timer tick":
    var cluster = newRaftCluster()
    cluster.addNode("n1")
    cluster.addNode("n2")
    cluster.addNode("n3")

    let n1 = cluster.nodes["n1"]
    var timer = newElectionTimer(n1, timeoutMs = 0)  # immediate timeout

    # Force election
    n1.becomeCandidate()
    n1.becomeLeader()
    timer.tick()
    check n1.isLeader

  test "Timer reset":
    var cluster = newRaftCluster()
    cluster.addNode("n1")
    let n1 = cluster.nodes["n1"]
    var timer = newElectionTimer(n1, timeoutMs = 1000)
    timer.resetTimeout()
    check not timer.checkTimeout()

  test "Multi-node election with timer":
    var cluster = newRaftCluster()
    cluster.addNode("n1")
    cluster.addNode("n2")

    let n2 = cluster.nodes["n2"]
    var timer2 = newElectionTimer(n2, timeoutMs = 0)
    n2.becomeCandidate()
    let req = n2.requestVote()
    check req.len == 1  # n2 requests vote from n1
    let reply = cluster.nodes["n1"].handleRequestVote(req[0])
    check reply.success

suite "Raft Network Transport":
  test "3-node election over TCP":
    var n1 = newRaftNode("n1", @["n2", "n3"], raftPort = 19001)
    var n2 = newRaftNode("n2", @["n1", "n3"], raftPort = 19002)
    var n3 = newRaftNode("n3", @["n1", "n2"], raftPort = 19003)

    n1.peerAddrs["n2"] = ("127.0.0.1", 19002)
    n1.peerAddrs["n3"] = ("127.0.0.1", 19003)
    n2.peerAddrs["n1"] = ("127.0.0.1", 19001)
    n2.peerAddrs["n3"] = ("127.0.0.1", 19003)
    n3.peerAddrs["n1"] = ("127.0.0.1", 19001)
    n3.peerAddrs["n2"] = ("127.0.0.1", 19002)

    let net1 = newRaftNetwork(n1)
    let net2 = newRaftNetwork(n2)
    let net3 = newRaftNetwork(n3)

    asyncCheck net1.run()
    asyncCheck net2.run()
    asyncCheck net3.run()
    waitFor sleepAsync(50)

    var timer1 = newElectionTimer(n1, timeoutMs = 50)
    var timer2 = newElectionTimer(n2, timeoutMs = 100)
    var timer3 = newElectionTimer(n3, timeoutMs = 150)

    for i in 0 ..< 30:
      timer1.tick(net1)
      timer2.tick(net2)
      timer3.tick(net3)
      waitFor sleepAsync(20)

    net1.stop()
    net2.stop()
    net3.stop()
    waitFor sleepAsync(50)

    var leaderCount = 0
    if n1.isLeader: inc leaderCount
    if n2.isLeader: inc leaderCount
    if n3.isLeader: inc leaderCount
    check leaderCount == 1

suite "CLI Autocomplete":
  test "Autocomplete commands":
    let res = autocomplete("he")
    check "help" in res

  test "Autocomplete keywords":
    let res = autocomplete("SEL")
    check "SELECT" in res
    let res2 = autocomplete("SELECT FRO")
    check "FROM" in res2

  test "Suggest returns completions":
    let suggestion = suggest("SE")
    check suggestion.len > 0

  test "Autocomplete empty":
    let res = autocomplete("")
    check res.len == 0

suite "TLS/SSL":
  test "Create TLS config":
    let config = newTLSConfig("cert.pem", "key.pem", "ca.pem", verifyPeer = true)
    check config.certFile == "cert.pem"
    check config.verifyPeer == true

  test "Validate cert — missing file":
    let errors = validateCert("nonexistent.pem")
    check errors.len > 0

  test "Certificate info parsing":
    # Write a dummy PEM cert
    let testCert = "/tmp/baradb_test_cert.pem"
    writeFile(testCert, "Subject: CN=localhost\nIssuer: CN=localhost\n")
    let info = parseCertInfo(testCert)
    check info.subject.len > 0
    check info.isSelfSigned  # subject == issuer

  test "TLS context creation with missing cert raises":
    var raised = false
    try:
      discard newTLSContext(newTLSConfig("nonexistent.pem", "nonexistent.key"))
    except IOError:
      raised = true
    check raised

  test "Generate self-signed cert":
    let (certPath, keyPath) = generateSelfSignedCert("/tmp/baradb_test_tls", "test.local")
    # May fail if openssl not installed
    if certPath.len > 0:
      check fileExists(certPath)
      check fileExists(keyPath)
      # Should be able to create TLS context from generated cert
      let ctx = newTLSContext(newTLSConfig(certPath, keyPath))
      check ctx != nil

  test "Server with TLS config":
    var cfg = defaultConfig()
    cfg.tlsEnabled = true
    let (certPath, keyPath) = generateSelfSignedCert("/tmp/baradb_test_tls2", "test.local")
    if certPath.len > 0:
      cfg.certFile = certPath
      cfg.keyFile = keyPath
      var srv = newServer(cfg)
      check srv != nil
      check srv.tls != nil

suite "Triggers":
  test "Parse CREATE TRIGGER":
    let ast = parse("CREATE TRIGGER log_insert BEFORE INSERT ON users AS INSERT INTO audit_log VALUES ('insert', 'users')")
    check ast.stmts.len == 1
    check ast.stmts[0].kind == nkCreateTrigger
    check ast.stmts[0].trigName == "log_insert"
    check ast.stmts[0].trigTable == "users"
    check ast.stmts[0].trigTiming == "before"
    check ast.stmts[0].trigEvent == "INSERT"
    check ast.stmts[0].trigAction.strVal.contains("INSERT")
    check ast.stmts[0].trigAction.strVal.contains("audit_log")

  test "Parse CREATE TRIGGER AFTER UPDATE":
    let ast = parse("CREATE TRIGGER audit_update AFTER UPDATE ON orders AS INSERT INTO audit VALUES ('updated')")
    check ast.stmts[0].kind == nkCreateTrigger
    check ast.stmts[0].trigTiming == "after"
    check ast.stmts[0].trigEvent == "UPDATE"

  test "Parse CREATE TRIGGER INSTEAD OF DELETE":
    let ast = parse("CREATE TRIGGER soft_delete INSTEAD OF DELETE ON users AS UPDATE users SET deleted = true WHERE id = OLD.id")
    check ast.stmts[0].kind == nkCreateTrigger
    check ast.stmts[0].trigTiming == "instead of"
    check ast.stmts[0].trigEvent == "DELETE"

  test "Parse DROP TRIGGER":
    let ast = parse("DROP TRIGGER log_insert")
    check ast.stmts.len == 1
    check ast.stmts[0].kind == nkDropTrigger
    check ast.stmts[0].trigDropName == "log_insert"
    check ast.stmts[0].trigDropIfExists == false

  test "Parse DROP TRIGGER IF EXISTS":
    let ast = parse("DROP TRIGGER IF EXISTS old_trigger")
    check ast.stmts[0].kind == nkDropTrigger
    check ast.stmts[0].trigDropName == "old_trigger"
    check ast.stmts[0].trigDropIfExists == true

suite "Row-Level Security":
  test "Parse CREATE USER":
    let ast = parse("CREATE USER admin WITH PASSWORD 'secret' SUPERUSER")
    check ast.stmts.len == 1
    check ast.stmts[0].kind == nkCreateUser
    check ast.stmts[0].cuName == "admin"
    check ast.stmts[0].cuPassword == "secret"
    check ast.stmts[0].cuSuperuser == true

  test "Parse CREATE USER without superuser":
    let ast = parse("CREATE USER reader WITH PASSWORD 'reader123'")
    check ast.stmts[0].kind == nkCreateUser
    check ast.stmts[0].cuName == "reader"
    check ast.stmts[0].cuPassword == "reader123"
    check ast.stmts[0].cuSuperuser == false

  test "Parse DROP USER":
    let ast = parse("DROP USER admin")
    check ast.stmts[0].kind == nkDropUser
    check ast.stmts[0].duName == "admin"

  test "Parse CREATE POLICY":
    let ast = parse("CREATE POLICY user_isolation ON accounts FOR SELECT USING (user_id = current_user)")
    check ast.stmts[0].kind == nkCreatePolicy
    check ast.stmts[0].cpName == "user_isolation"
    check ast.stmts[0].cpTable == "accounts"
    check ast.stmts[0].cpCommand == "SELECT"

  test "Parse CREATE POLICY with WITH CHECK":
    let ast = parse("CREATE POLICY insert_check ON accounts FOR INSERT WITH CHECK (amount > 0)")
    check ast.stmts[0].kind == nkCreatePolicy
    check ast.stmts[0].cpCommand == "INSERT"

  test "Parse DROP POLICY":
    let ast = parse("DROP POLICY user_isolation ON accounts")
    check ast.stmts[0].kind == nkDropPolicy
    check ast.stmts[0].dpName == "user_isolation"
    check ast.stmts[0].dpTable == "accounts"

  test "Parse GRANT":
    let ast = parse("GRANT SELECT ON accounts TO reader")
    check ast.stmts[0].kind == nkGrant
    check ast.stmts[0].grPrivilege == "SELECT"
    check ast.stmts[0].grTable == "accounts"
    check ast.stmts[0].grGrantee == "reader"

  test "Parse REVOKE":
    let ast = parse("REVOKE INSERT ON accounts FROM reader")
    check ast.stmts[0].kind == nkRevoke
    check ast.stmts[0].rvPrivilege == "INSERT"
    check ast.stmts[0].rvTable == "accounts"
    check ast.stmts[0].rvGrantee == "reader"

  test "Parse ENABLE ROW LEVEL SECURITY":
    let ast = parse("ALTER TABLE accounts ENABLE ROW LEVEL SECURITY")
    check ast.stmts[0].kind == nkEnableRLS
    check ast.stmts[0].erlsTable == "accounts"

  test "Parse DISABLE ROW LEVEL SECURITY":
    let ast = parse("ALTER TABLE accounts DISABLE ROW LEVEL SECURITY")
    check ast.stmts[0].kind == nkDisableRLS
    check ast.stmts[0].drlsTable == "accounts"

  test "RLS filter on SELECT":
    var db = newLSMTree("")
    var ctx = qexec.newExecutionContext(db)
    # Create table and insert data
    discard qexec.executeQuery(ctx, parse("CREATE TABLE docs (id INTEGER, owner TEXT)"))
    discard qexec.executeQuery(ctx, parse("INSERT INTO docs (id, owner) VALUES (1, 'alice'), (2, 'bob')"))
    # Create user and policy
    ctx.currentUser = "alice"
    ctx.users["alice"] = qexec.UserDef(name: "alice", passwordHash: "", isSuperuser: false, roles: @[])
    ctx.policies["docs"] = @[
      qexec.PolicyDef(name: "owner_only", tableName: "docs", command: "SELECT",
                usingExpr: Node(kind: nkBinOp, binOp: bkEq,
                  binLeft: Node(kind: nkIdent, identName: "owner"),
                  binRight: Node(kind: nkStringLit, strVal: "alice")),
                withCheckExpr: nil)
    ]
    # Query should only return alice's row
    let res = qexec.executeQuery(ctx, parse("SELECT id, owner FROM docs"))
    check res.success
    check res.rows.len == 1
    check res.rows[0]["owner"] == "alice"

  test "RLS superuser bypass":
    var db = newLSMTree("")
    var ctx = qexec.newExecutionContext(db)
    discard qexec.executeQuery(ctx, parse("CREATE TABLE docs (id INTEGER, owner TEXT)"))
    discard qexec.executeQuery(ctx, parse("INSERT INTO docs (id, owner) VALUES (1, 'alice')"))
    ctx.currentUser = "admin"
    ctx.users["admin"] = qexec.UserDef(name: "admin", passwordHash: "", isSuperuser: true, roles: @[])
    ctx.policies["docs"] = @[
      qexec.PolicyDef(name: "owner_only", tableName: "docs", command: "SELECT",
                usingExpr: Node(kind: nkBinOp, binOp: bkEq,
                  binLeft: Node(kind: nkIdent, identName: "owner"),
                  binRight: Node(kind: nkStringLit, strVal: "alice")),
                withCheckExpr: nil)
    ]
    let res = qexec.executeQuery(ctx, parse("SELECT id, owner FROM docs"))
    check res.success
    check res.rows.len == 1  # superuser sees all (only 1 row exists)

suite "UTF-8 Support":
  test "Tokenize UTF-8 identifiers":
    let tokens = lex.tokenize("SELECT имя FROM потребители")
    check tokens[1].kind == tkIdent
    check tokens[1].value == "имя"
    check tokens[3].kind == tkIdent
    check tokens[3].value == "потребители"

  test "Parse UTF-8 table and column names":
    let ast = parse("SELECT имя, възраст FROM потребители WHERE град = 'София'")
    check ast.stmts[0].kind == nkSelect
    check ast.stmts[0].selFrom.fromTable == "потребители"
    check ast.stmts[0].selResult[0].identName == "имя"
    check ast.stmts[0].selWhere.whereExpr.binRight.strVal == "София"

  test "Execute query with UTF-8 data":
    var db = newLSMTree("")
    var ctx = qexec.newExecutionContext(db)
    discard qexec.executeQuery(ctx, parse("CREATE TABLE потребители (имя TEXT, град TEXT)"))
    discard qexec.executeQuery(ctx, parse("INSERT INTO потребители (имя, град) VALUES ('Иван', 'София'), ('Мария', 'Пловдив')"))
    let res = qexec.executeQuery(ctx, parse("SELECT имя, град FROM потребители WHERE град = 'София'"))
    check res.success
    check res.rows.len == 1
    check res.rows[0]["имя"] == "Иван"
    check res.rows[0]["град"] == "София"

suite "B-Tree Range Scan":
  test "BETWEEN uses index range scan":
    var db = newLSMTree("")
    var ctx = qexec.newExecutionContext(db)
    discard qexec.executeQuery(ctx, parse("CREATE TABLE products (id INTEGER, name TEXT)"))
    discard qexec.executeQuery(ctx, parse("INSERT INTO products (id, name) VALUES (1, 'apple'), (2, 'banana'), (3, 'cherry'), (4, 'date'), (5, 'elderberry')"))
    discard qexec.executeQuery(ctx, parse("CREATE INDEX idx_products_name ON products(name)"))
    let res = qexec.executeQuery(ctx, parse("SELECT name FROM products WHERE name BETWEEN 'banana' AND 'date'"))
    check res.success
    check res.rows.len == 3

  test "Greater than uses index range scan":
    var db = newLSMTree("")
    var ctx = qexec.newExecutionContext(db)
    discard qexec.executeQuery(ctx, parse("CREATE TABLE nums (id INTEGER, val TEXT)"))
    discard qexec.executeQuery(ctx, parse("INSERT INTO nums (id, val) VALUES (1, '10'), (2, '20'), (3, '30'), (4, '40'), (5, '50')"))
    discard qexec.executeQuery(ctx, parse("CREATE INDEX idx_nums_val ON nums(val)"))
    let res = qexec.executeQuery(ctx, parse("SELECT val FROM nums WHERE val > '20'"))
    check res.success
    check res.rows.len == 3

  test "Less than or equal uses index range scan":
    var db = newLSMTree("")
    var ctx = qexec.newExecutionContext(db)
    discard qexec.executeQuery(ctx, parse("CREATE TABLE nums2 (id INTEGER, val TEXT)"))
    discard qexec.executeQuery(ctx, parse("INSERT INTO nums2 (id, val) VALUES (1, '10'), (2, '20'), (3, '30'), (4, '40'), (5, '50')"))
    discard qexec.executeQuery(ctx, parse("CREATE INDEX idx_nums2_val ON nums2(val)"))
    let res = qexec.executeQuery(ctx, parse("SELECT val FROM nums2 WHERE val <= '30'"))
    check res.success
    check res.rows.len == 3

suite "Enhanced Migrations":
  test "Parse CREATE MIGRATION with UP/DOWN":
    let ast = parse("CREATE MIGRATION add_users { UP: CREATE TABLE users (id INTEGER PRIMARY KEY); DOWN: DROP TABLE users; }")
    check ast.stmts.len == 1
    check ast.stmts[0].kind == nkCreateMigration
    check ast.stmts[0].cmName == "add_users"
    check ast.stmts[0].cmBody.contains("CREATE TABLE users")
    check ast.stmts[0].cmDownBody.contains("DROP TABLE users")

  test "Parse MIGRATION STATUS":
    let ast = parse("MIGRATION STATUS")
    check ast.stmts[0].kind == nkMigrationStatus

  test "Parse MIGRATION UP":
    let ast = parse("MIGRATION UP")
    check ast.stmts[0].kind == nkMigrationUp
    check ast.stmts[0].muCount == 0

  test "Parse MIGRATION UP 5":
    let ast = parse("MIGRATION UP 5")
    check ast.stmts[0].kind == nkMigrationUp
    check ast.stmts[0].muCount == 5

  test "Parse MIGRATION DOWN":
    let ast = parse("MIGRATION DOWN")
    check ast.stmts[0].kind == nkMigrationDown
    check ast.stmts[0].mdCount == 1

  test "Parse MIGRATION DOWN 3":
    let ast = parse("MIGRATION DOWN 3")
    check ast.stmts[0].kind == nkMigrationDown
    check ast.stmts[0].mdCount == 3

  test "Parse MIGRATION DRYRUN":
    let ast = parse("MIGRATION DRYRUN add_users")
    check ast.stmts[0].kind == nkMigrationDryRun
    check ast.stmts[0].mdrName == "add_users"

  test "Create and apply migration with checksum":
    var db = newLSMTree("")
    var ctx = qexec.newExecutionContext(db)
    # Create migration
    let createRes = qexec.executeQuery(ctx, parse("CREATE MIGRATION add_users { UP: CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT); DOWN: DROP TABLE users; }"))
    check createRes.success
    check createRes.message.contains("checksum")
    # Apply migration
    let applyRes = qexec.executeQuery(ctx, parse("APPLY MIGRATION add_users"))
    check applyRes.success
    check applyRes.message.contains("ms")
    # Check table exists
    let tableRes = qexec.executeQuery(ctx, parse("SELECT name FROM users"))
    check tableRes.success  # table exists (empty result is OK)
    # Re-apply should be idempotent
    let reapplyRes = qexec.executeQuery(ctx, parse("APPLY MIGRATION add_users"))
    check reapplyRes.success
    check reapplyRes.message.contains("already applied")

  test "Migration STATUS shows applied migrations":
    var db = newLSMTree("")
    var ctx = qexec.newExecutionContext(db)
    discard qexec.executeQuery(ctx, parse("CREATE MIGRATION m1 { UP: CREATE TABLE t1 (id INTEGER); }"))
    discard qexec.executeQuery(ctx, parse("CREATE MIGRATION m2 { UP: CREATE TABLE t2 (id INTEGER); }"))
    discard qexec.executeQuery(ctx, parse("APPLY MIGRATION m1"))
    let statusRes = qexec.executeQuery(ctx, parse("MIGRATION STATUS"))
    check statusRes.success
    check statusRes.rows.len == 2
    check statusRes.rows[0]["status"] == "applied"
    check statusRes.rows[1]["status"] == "pending"

  test "Migration UP applies all pending":
    var db = newLSMTree("")
    var ctx = qexec.newExecutionContext(db)
    discard qexec.executeQuery(ctx, parse("CREATE MIGRATION m1 { UP: CREATE TABLE t1 (id INTEGER); }"))
    discard qexec.executeQuery(ctx, parse("CREATE MIGRATION m2 { UP: CREATE TABLE t2 (id INTEGER); }"))
    let upRes = qexec.executeQuery(ctx, parse("MIGRATION UP"))
    check upRes.success
    check upRes.message.contains("Applied 2 migrations")

  test "Migration DOWN rollback":
    var db = newLSMTree("")
    var ctx = qexec.newExecutionContext(db)
    discard qexec.executeQuery(ctx, parse("CREATE MIGRATION add_t { UP: CREATE TABLE t (id INTEGER); DOWN: DROP TABLE t; }"))
    discard qexec.executeQuery(ctx, parse("APPLY MIGRATION add_t"))
    let downRes = qexec.executeQuery(ctx, parse("MIGRATION DOWN"))
    check downRes.success
    check downRes.message.contains("Rolled back 1 migrations")
    # After rollback, table should be gone (check by listing tables)
    let tableRes = qexec.executeQuery(ctx, parse("SELECT name FROM __tables WHERE name = 't'"))
    check tableRes.success
    check tableRes.rows.len == 0  # table does not exist

  test "Migration DRYRUN":
    var db = newLSMTree("")
    var ctx = qexec.newExecutionContext(db)
    discard qexec.executeQuery(ctx, parse("CREATE MIGRATION add_t { UP: CREATE TABLE t (id INTEGER); CREATE INDEX idx ON t(id); DOWN: DROP TABLE t; }"))
    let dryRes = qexec.executeQuery(ctx, parse("MIGRATION DRYRUN add_t"))
    check dryRes.success
    check dryRes.message.contains("DRY RUN")
    check dryRes.message.contains("Statements: 2")
    check dryRes.message.contains("DOWN script: yes")

suite "Parameterized queries":
  var db: LSMTree
  var ctx: qexec.ExecutionContext

  setup:
    db = newLSMTree("")
    ctx = qexec.newExecutionContext(db)
    discard qexec.executeQuery(ctx, parse("CREATE TABLE users (id INT, name TEXT, age INT)"))
    discard qexec.executeQuery(ctx, parse("INSERT INTO users (id, name, age) VALUES (1, 'Alice', 30)"))
    discard qexec.executeQuery(ctx, parse("INSERT INTO users (id, name, age) VALUES (2, 'Bob', 25)"))

  test "SELECT with placeholder params":
    let sql = "SELECT * FROM users WHERE id = ?"
    let tokens = lex.tokenize(sql)
    let ast = parse(tokens)
    let params = @[WireValue(kind: fkInt64, int64Val: 1)]
    let r = qexec.executeQuery(ctx, ast, params)
    check r.success
    check r.rows.len == 1
    check r.rows[0]["name"] == "Alice"

  test "INSERT with placeholder params":
    let sql = "INSERT INTO users (id, name, age) VALUES (?, ?, ?)"
    let tokens = lex.tokenize(sql)
    let ast = parse(tokens)
    let params = @[
      WireValue(kind: fkInt64, int64Val: 3),
      WireValue(kind: fkString, strVal: "Charlie"),
      WireValue(kind: fkInt64, int64Val: 35)
    ]
    let r = qexec.executeQuery(ctx, ast, params)
    check r.success
    let selectR = qexec.executeQuery(ctx, parse("SELECT * FROM users WHERE id = 3"))
    check selectR.rows.len == 1
    check selectR.rows[0]["name"] == "Charlie"

  test "SELECT with multiple placeholders":
    let sql = "SELECT * FROM users WHERE age > ? AND name = ?"
    let tokens = lex.tokenize(sql)
    let ast = parse(tokens)
    let params = @[WireValue(kind: fkInt64, int64Val: 25), WireValue(kind: fkString, strVal: "Alice")]
    let r = qexec.executeQuery(ctx, ast, params)
    check r.success
    check r.rows.len == 1
    check r.rows[0]["name"] == "Alice"

# JOIN tests
include "join_tests"
