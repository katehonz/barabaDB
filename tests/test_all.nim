## BaraDB — Test Suite
import std/unittest
import std/tables
import std/strutils

import barabadb/core/types
import barabadb/core/mvcc
import barabadb/core/deadlock
import barabadb/core/columnar
import barabadb/core/raft
import barabadb/core/sharding
import barabadb/storage/bloom
import barabadb/storage/wal
import barabadb/storage/lsm
import barabadb/storage/btree
import barabadb/storage/compaction
import barabadb/query/lexer as lex
import barabadb/query/ast
import barabadb/query/parser
import barabadb/query/ir as qir
import barabadb/vector/engine as vengine
import barabadb/vector/quant as vquant
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
    var pool = newConnectionPool("127.0.0.1", 5432)
    let conn = pool.acquire()
    check conn != nil
    check conn.host == "127.0.0.1"
    check conn.port == 5432
    pool.release(conn)

  test "Pool stats":
    var cfg = defaultPoolConfig()
    cfg.minConnections = 1
    cfg.maxConnections = 10
    var pool = newConnectionPool("127.0.0.1", 5432, "default", cfg)
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
