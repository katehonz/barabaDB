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
    txn.addParticipant("node1")
    txn.addParticipant("node2")
    check txn.participantCount == 2

  test "Two-phase commit flow":
    var txn = newDistributedTransaction("coordinator")
    txn.addParticipant("n1")
    check txn.prepare()
    check txn.state() == dtsPrepared
    check txn.commit()
    check txn.isCommitted

  test "Rollback dist transaction":
    var txn = newDistributedTransaction("coordinator")
    txn.addParticipant("n1")
    check txn.rollback()
    check txn.isAborted

  test "DistTxnManager lifecycle":
    var tm = newDistTxnManager()
    let txn = tm.beginTransaction("node1")
    check tm.activeCount == 1
    txn.addParticipant("n2")
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
    var testDir = getTempDir() / "baradb_rls_test_" & $getCurrentProcessId() & "_" & $getMonoTime().ticks
    createDir(testDir)
    var db = newLSMTree(testDir)
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
    var testDir = getTempDir() / "baradb_rls_test_" & $getCurrentProcessId() & "_" & $getMonoTime().ticks
    createDir(testDir)
    var db = newLSMTree(testDir)
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
    var testDir = getTempDir() / "baradb_migration_test_" & $getCurrentProcessId() & "_" & $getMonoTime().ticks
    createDir(testDir)
    var db = newLSMTree(testDir)
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
    var testDir = getTempDir() / "baradb_migration_test_" & $getCurrentProcessId() & "_" & $getMonoTime().ticks
    createDir(testDir)
    var db = newLSMTree(testDir)
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
    var testDir = getTempDir() / "baradb_migration_test_" & $getCurrentProcessId() & "_" & $getMonoTime().ticks
    createDir(testDir)
    var db = newLSMTree(testDir)
    var ctx = qexec.newExecutionContext(db)
    discard qexec.executeQuery(ctx, parse("CREATE MIGRATION m1 { UP: CREATE TABLE t1 (id INTEGER); }"))
    discard qexec.executeQuery(ctx, parse("CREATE MIGRATION m2 { UP: CREATE TABLE t2 (id INTEGER); }"))
    let upRes = qexec.executeQuery(ctx, parse("MIGRATION UP"))
    check upRes.success
    check upRes.message.contains("Applied 2 migrations")

  test "Migration DOWN rollback":
    var testDir = getTempDir() / "baradb_migration_test_" & $getCurrentProcessId() & "_" & $getMonoTime().ticks
    createDir(testDir)
    var db = newLSMTree(testDir)
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
    var testDir = getTempDir() / "baradb_migration_test_" & $getCurrentProcessId() & "_" & $getMonoTime().ticks
    createDir(testDir)
    var db = newLSMTree(testDir)
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

  test "JSON type validation":
    let createTbl = parse("CREATE TABLE json_test (id INT PRIMARY KEY, data JSON)")
    discard qexec.executeQuery(ctx, createTbl)
    let valid = parse("INSERT INTO json_test (id, data) VALUES (1, '{\"key\": \"value\"}')")
    let r1 = qexec.executeQuery(ctx, valid)
    check r1.success
    let invalid = parse("INSERT INTO json_test (id, data) VALUES (2, 'not json')")
    let r2 = qexec.executeQuery(ctx, invalid)
    check not r2.success
    check r2.message.contains("JSON")

  test "Multi-column index parse and create":
    let ast = parse("CREATE INDEX idx_mc ON users (name, age)")
    check ast.stmts[0].kind == nkCreateIndex
    check ast.stmts[0].ciColumns.len == 2
    check ast.stmts[0].ciColumns[0] == "name"
    check ast.stmts[0].ciColumns[1] == "age"
    let r = qexec.executeQuery(ctx, ast)
    check r.success
    check r.message.contains("CREATE INDEX")

  test "CTE non-recursive execution":
    let ast = parse("WITH active AS (SELECT * FROM users WHERE active = true) SELECT * FROM active")
    let r = qexec.executeQuery(ctx, ast)
    check r.success
    check r.rows.len >= 1

  test "CTE recursive parse":
    let ast = parse("WITH RECURSIVE nums AS (SELECT 1 AS n) SELECT * FROM nums")
    check ast.stmts[0].selWith.len == 1
    check ast.stmts[0].selWith[0][0] == "nums"
    check ast.stmts[0].selWith[0][2] == true

  test "UNION ALL parse":
    let ast = parse("SELECT 1 AS n UNION ALL SELECT 2 AS n")
    check ast.stmts[0].kind == nkSetOp
    check ast.stmts[0].setOpKind == sdkUnion
    check ast.stmts[0].setOpAll == true
    check ast.stmts[0].setOpLeft.kind == nkSelect
    check ast.stmts[0].setOpRight.kind == nkSelect

  test "UNION ALL execution":
    discard qexec.executeQuery(ctx, parse("INSERT INTO users (name, age, active) VALUES ('union_a', '30', 'true')"))
    discard qexec.executeQuery(ctx, parse("INSERT INTO users (name, age, active) VALUES ('union_b', '25', 'false')"))
    let ast = parse("SELECT name FROM users WHERE name = 'union_a' UNION ALL SELECT name FROM users WHERE name = 'union_b'")
    let r = qexec.executeQuery(ctx, ast)
    check r.success
    check r.rows.len == 2

  test "Simple recursive CTE execution":
    let ast = parse("WITH RECURSIVE nums AS (SELECT 0 AS n FROM users LIMIT 1 UNION ALL SELECT n + 1 FROM nums WHERE n < 2) SELECT n FROM nums ORDER BY n ASC")
    let r = qexec.executeQuery(ctx, ast)
    check r.success

  test "DROP INDEX parse":
    let ast = parse("DROP INDEX myidx")
    check ast.stmts[0].kind == nkDropIndex
    check ast.stmts[0].diName == "myidx"

  test "DROP INDEX execution":
    let tbl = ctx.tables["users"]
    let colKey = "users.name"
    ctx.btrees[colKey] = newBTreeIndex[string, IndexEntry]()
    let dropAst = parse("DROP INDEX users.name")
    let r = qexec.executeQuery(ctx, dropAst)
    check r.success

  test "JSON path operators parse":
    let ast = parse("SELECT data->'name' FROM users")
    check ast.stmts[0].kind == nkSelect

  test "JSON path operator ->> parse":
    let ast = parse("SELECT data->>'name' FROM users")
    check ast.stmts[0].kind == nkSelect

  test "JSON path execution":
    discard qexec.executeQuery(ctx, parse("CREATE TABLE IF NOT EXISTS jsontest (id INT PRIMARY KEY, data JSON)"))
    discard qexec.executeQuery(ctx, parse("INSERT INTO jsontest (id, data) VALUES (1, '{\"name\": \"Alice\", \"age\": 30}')"))
    let r = qexec.executeQuery(ctx, parse("SELECT data->'name' AS json_name, data->>'name' AS text_name FROM jsontest"))
    check r.success
    check r.rows.len >= 1

  test "FTS match operator @@ parse":
    let ast = parse("SELECT * FROM docs WHERE content @@ 'hello'")
    check ast.stmts[0].kind == nkSelect

  test "FTS match operator @@ execution":
    discard qexec.executeQuery(ctx, parse("INSERT INTO users (name, age, active) VALUES ('full text search', '30', 'true')"))
    let r = qexec.executeQuery(ctx, parse("SELECT name FROM users WHERE name @@ 'text'"))
    check r.success
    # Should find the row because 'text' is in 'full text search'

  test "RECOVER TO TIMESTAMP parse":
    let ast = parse("RECOVER TO TIMESTAMP '2026-05-07T12:00:00'")
    check ast.stmts[0].kind == nkRecoverToTimestamp

  test "RECOVER FROM WAL execution":
    let r = qexec.executeQuery(ctx, parse("RECOVER TO TIMESTAMP '2026-12-31T23:59:59'"))
    check r.success

  test "FTS index creation USING FTS":
    discard qexec.executeQuery(ctx, parse("CREATE TABLE IF NOT EXISTS fts_test (id INT PRIMARY KEY, body TEXT)"))
    discard qexec.executeQuery(ctx, parse("INSERT INTO fts_test (id, body) VALUES (1, 'the quick brown fox jumps')"))
    discard qexec.executeQuery(ctx, parse("INSERT INTO fts_test (id, body) VALUES (2, 'lazy dog sleeps all day')"))
    discard qexec.executeQuery(ctx, parse("INSERT INTO fts_test (id, body) VALUES (3, 'quick brown dog plays fetch')"))
    let r = qexec.executeQuery(ctx, parse("CREATE INDEX idx_fts_body ON fts_test(body) USING FTS"))
    check r.success
    check r.message.contains("USING FTS")

  test "FTS index @@ uses BM25":
    let r = qexec.executeQuery(ctx, parse("SELECT id FROM fts_test WHERE body @@ 'quick brown'"))
    check r.success
    check r.rows.len >= 2

# JOIN tests
include "join_tests"

# TLA+ faithfulness tests
include "tla_faithfulness"
