## Schema persistence — CREATE TABLE / data survive reopen
import std/unittest
import std/os
import std/strutils
import std/tables
import barabadb/storage/lsm
import barabadb/query/executor
import barabadb/query/parser
import barabadb/fts/engine
import barabadb/vector/engine as vengine
import barabadb/graph/engine as gengine

proc execSql(ctx: ExecutionContext, sql: string): ExecResult =
  let node = parse(sql)
  result = executeQuery(ctx, node)

suite "Schema persistence":
  test "CREATE TABLE survives flush + reopen":
    let dir = "/tmp/baradb_schema_persist_1"
    removeDir(dir)
    block:
      var db = newLSMTree(dir, 1024)  # small memtable → forces flush
      var ctx = newExecutionContext(db)
      let r = execSql(ctx, "CREATE TABLE users (id INT PRIMARY KEY, name TEXT NOT NULL)")
      check r.success
      check ctx.tables.hasKey("users")
      check ctx.tables["users"].columns.len == 2
      discard execSql(ctx, "INSERT INTO users (id, name) VALUES (1, 'Alice')")
      discard execSql(ctx, "INSERT INTO users (id, name) VALUES (2, 'Bob')")
      db.flush()
      # Schema key must be durable
      let (found, _) = db.get(tableSchemaKey("users"))
      check found
      db.close()

    # Reopen fresh context (simulates process restart)
    block:
      var db2 = newLSMTree(dir, 1024)
      var ctx2 = newExecutionContext(db2)
      check ctx2.tables.hasKey("users")
      check ctx2.tables["users"].columns.len == 2
      check ctx2.tables["users"].pkColumns.len == 1
      let sel = execSql(ctx2, "SELECT id, name FROM users ORDER BY id")
      check sel.success
      check sel.rows.len == 2
      db2.close()

  test "DROP TABLE removes schema and data":
    let dir = "/tmp/baradb_schema_persist_drop"
    removeDir(dir)
    var db = newLSMTree(dir)
    var ctx = newExecutionContext(db)
    check execSql(ctx, "CREATE TABLE t (id INT PRIMARY KEY)").success
    check execSql(ctx, "INSERT INTO t (id) VALUES (1)").success
    check execSql(ctx, "DROP TABLE t").success
    check not ctx.tables.hasKey("t")
    let (found, _) = db.get(tableSchemaKey("t"))
    check not found
    # Reopen — table must not reappear
    db.close()
    var db2 = newLSMTree(dir)
    var ctx2 = newExecutionContext(db2)
    check not ctx2.tables.hasKey("t")
    db2.close()

  test "ALTER TABLE ADD COLUMN is persisted":
    let dir = "/tmp/baradb_schema_persist_alter"
    removeDir(dir)
    block:
      var db = newLSMTree(dir)
      var ctx = newExecutionContext(db)
      check execSql(ctx, "CREATE TABLE items (id INT PRIMARY KEY)").success
      check execSql(ctx, "ALTER TABLE items ADD COLUMN label TEXT").success
      check ctx.tables["items"].columns.len == 2
      db.flush()
      db.close()
    block:
      var db2 = newLSMTree(dir)
      var ctx2 = newExecutionContext(db2)
      check ctx2.tables.hasKey("items")
      check ctx2.tables["items"].columns.len == 2
      var names: seq[string] = @[]
      for c in ctx2.tables["items"].columns:
        names.add(c.name)
      check "label" in names
      db2.close()

  test "Multiple tables all restored":
    let dir = "/tmp/baradb_schema_persist_multi"
    removeDir(dir)
    block:
      var db = newLSMTree(dir, 512)
      var ctx = newExecutionContext(db)
      check execSql(ctx, "CREATE TABLE a (id INT PRIMARY KEY)").success
      check execSql(ctx, "CREATE TABLE b (id INT PRIMARY KEY, a_id INT)").success
      check execSql(ctx, "CREATE TABLE c (name TEXT)").success
      for i in 0..20:
        discard execSql(ctx, "INSERT INTO a (id) VALUES (" & $i & ")")
      db.flush()
      db.close()
    block:
      var db2 = newLSMTree(dir)
      var ctx2 = newExecutionContext(db2)
      check ctx2.tables.hasKey("a")
      check ctx2.tables.hasKey("b")
      check ctx2.tables.hasKey("c")
      let sel = execSql(ctx2, "SELECT id FROM a")
      check sel.success
      check sel.rows.len == 21
      db2.close()

  test "FTS index survives reopen":
    let dir = "/tmp/baradb_schema_persist_fts"
    removeDir(dir)
    block:
      var db = newLSMTree(dir)
      var ctx = newExecutionContext(db)
      check execSql(ctx, "CREATE TABLE docs (id INTEGER PRIMARY KEY, content TEXT)").success
      check execSql(ctx, "INSERT INTO docs (id, content) VALUES (1, 'quick brown fox')").success
      check execSql(ctx, "CREATE INDEX docs_fts ON docs (content) USING FTS").success
      check ctx.ftsIndexes.hasKey("docs.content")
      db.close()
    # Reopen fresh context (simulates process restart)
    block:
      var db2 = newLSMTree(dir)
      var ctx2 = newExecutionContext(db2)
      # Index must be rebuilt from the persisted schema key — today it is
      # silently missing, so FTS queries return empty results after reopen.
      check ctx2.ftsIndexes.hasKey("docs.content")
      if ctx2.ftsIndexes.hasKey("docs.content"):
        check ctx2.ftsIndexes["docs.content"].search("quick", limit = 10).len >= 1
      let r = execSql(ctx2, "SELECT id FROM docs WHERE content @@ 'quick'")
      check r.success
      check r.rows.len == 1
      # index keeps updating after reopen
      check execSql(ctx2, "INSERT INTO docs (id, content) VALUES (2, 'quick red fox')").success
      if ctx2.ftsIndexes.hasKey("docs.content"):
        check ctx2.ftsIndexes["docs.content"].search("red", limit = 10).len >= 1
      db2.close()
    removeDir(dir)

  test "HNSW vector index survives reopen":
    let dir = "/tmp/baradb_schema_persist_vec"
    removeDir(dir)
    block:
      var db = newLSMTree(dir)
      var ctx = newExecutionContext(db)
      check execSql(ctx, "CREATE TABLE vecs (id INTEGER PRIMARY KEY, embedding TEXT)").success
      check execSql(ctx, "INSERT INTO vecs (id, embedding) VALUES (1, '[1.0, 0.0, 0.0]')").success
      check execSql(ctx, "CREATE INDEX vecs_hnsw ON vecs (embedding) USING HNSW").success
      check ctx.vectorIndexes.hasKey("vecs.embedding")
      db.close()
    # Reopen fresh context (simulates process restart)
    block:
      var db2 = newLSMTree(dir)
      var ctx2 = newExecutionContext(db2)
      # Index must be rebuilt from the persisted schema key — today it is
      # silently missing, so vector searches return empty results after reopen.
      check ctx2.vectorIndexes.hasKey("vecs.embedding")
      if ctx2.vectorIndexes.hasKey("vecs.embedding"):
        check vengine.search(ctx2.vectorIndexes["vecs.embedding"],
                             @[1.0'f32, 0.0'f32, 0.0'f32], k = 5).len >= 1
      # index keeps updating after reopen
      check execSql(ctx2, "INSERT INTO vecs (id, embedding) VALUES (2, '[0.0, 1.0, 0.0]')").success
      if ctx2.vectorIndexes.hasKey("vecs.embedding"):
        check vengine.search(ctx2.vectorIndexes["vecs.embedding"],
                             @[0.0'f32, 1.0'f32, 0.0'f32], k = 5).len >= 1
      db2.close()
    removeDir(dir)

  test "Unnamed FTS index survives reopen":
    let dir = "/tmp/baradb_schema_persist_fts_noname"
    removeDir(dir)
    block:
      var db = newLSMTree(dir)
      var ctx = newExecutionContext(db)
      check execSql(ctx, "CREATE TABLE docs (id INTEGER PRIMARY KEY, content TEXT)").success
      check execSql(ctx, "INSERT INTO docs (id, content) VALUES (1, 'quick brown fox')").success
      # No index name — idxName defaults to colKey (docs.content) at execution
      check execSql(ctx, "CREATE INDEX ON docs (content) USING FTS").success
      check ctx.ftsIndexes.hasKey("docs.content")
      db.close()
    # Reopen fresh context (simulates process restart)
    block:
      var db2 = newLSMTree(dir)
      var ctx2 = newExecutionContext(db2)
      # Persisted DDL must be replayable — the dotted fallback name is not.
      check ctx2.ftsIndexes.hasKey("docs.content")
      if ctx2.ftsIndexes.hasKey("docs.content"):
        check ctx2.ftsIndexes["docs.content"].search("quick", limit = 10).len >= 1
      # Nameless persisted DDL must not confuse DROP INDEX name matching
      let d = execSql(ctx2, "DROP INDEX content")
      check d.success
      check "docs.content" notin ctx2.ftsIndexes
      let (found, _) = db2.get(SchemaFtsIndexPrefix & "docs.content")
      check not found
      db2.close()
    block:
      var db3 = newLSMTree(dir)
      var ctx3 = newExecutionContext(db3)
      check "docs.content" notin ctx3.ftsIndexes  # no ghost rebuild
      db3.close()
    removeDir(dir)

  test "Unnamed HNSW index survives reopen":
    let dir = "/tmp/baradb_schema_persist_vec_noname"
    removeDir(dir)
    block:
      var db = newLSMTree(dir)
      var ctx = newExecutionContext(db)
      check execSql(ctx, "CREATE TABLE vecs (id INTEGER PRIMARY KEY, embedding TEXT)").success
      check execSql(ctx, "INSERT INTO vecs (id, embedding) VALUES (1, '[1.0, 0.0, 0.0]')").success
      # No index name — idxName defaults to colKey (vecs.embedding)
      check execSql(ctx, "CREATE INDEX ON vecs (embedding) USING HNSW").success
      check ctx.vectorIndexes.hasKey("vecs.embedding")
      db.close()
    # Reopen fresh context (simulates process restart)
    block:
      var db2 = newLSMTree(dir)
      var ctx2 = newExecutionContext(db2)
      check ctx2.vectorIndexes.hasKey("vecs.embedding")
      if ctx2.vectorIndexes.hasKey("vecs.embedding"):
        check vengine.search(ctx2.vectorIndexes["vecs.embedding"],
                             @[1.0'f32, 0.0'f32, 0.0'f32], k = 5).len >= 1
      let d = execSql(ctx2, "DROP INDEX embedding")
      check d.success
      check "vecs.embedding" notin ctx2.vectorIndexes
      let (found, _) = db2.get(SchemaVecIndexPrefix & "vecs.embedding")
      check not found
      db2.close()
    block:
      var db3 = newLSMTree(dir)
      var ctx3 = newExecutionContext(db3)
      check "vecs.embedding" notin ctx3.vectorIndexes  # no ghost rebuild
      db3.close()
    removeDir(dir)

  test "Graph survives reopen":
    let dir = "/tmp/baradb_schema_persist_graph"
    removeDir(dir)
    block:
      var db = newLSMTree(dir)
      var ctx = newExecutionContext(db)
      check execSql(ctx, "CREATE GRAPH social").success
      check execSql(ctx, "INSERT INTO social_nodes (id, node_label) VALUES (1, 'person')").success
      check execSql(ctx, "INSERT INTO social_nodes (id, node_label) VALUES (2, 'person')").success
      check execSql(ctx, "INSERT INTO social_edges (source_id, dest_id, edge_label, weight) VALUES (1, 2, 'knows', 1.0)").success
      check "social" in ctx.graphs
      db.close()
    # Reopen fresh context (simulates process restart)
    block:
      var db2 = newLSMTree(dir)
      var ctx2 = newExecutionContext(db2)
      # Graph must be rebuilt from the backing tables — today it is
      # silently missing after reopen.
      check "social" in ctx2.graphs
      if "social" in ctx2.graphs:
        check gengine.nodeCount(ctx2.graphs["social"]) == 2
        check gengine.edgeCount(ctx2.graphs["social"]) == 1
      db2.close()
    removeDir(dir)

  test "DROP INDEX removes FTS index and its schema key (custom name)":
    let dir = "/tmp/baradb_schema_persist_dropfts"
    removeDir(dir)
    block:
      var db = newLSMTree(dir)
      var ctx = newExecutionContext(db)
      check execSql(ctx, "CREATE TABLE docs (id INTEGER PRIMARY KEY, content TEXT)").success
      check execSql(ctx, "INSERT INTO docs (id, content) VALUES (1, 'quick brown fox')").success
      check execSql(ctx, "CREATE INDEX docs_fts ON docs (content) USING FTS").success
      check ctx.ftsIndexes.hasKey("docs.content")
      # Drop by the custom index name — the in-memory key is table.col
      let d = execSql(ctx, "DROP INDEX docs_fts")
      check d.success
      check "docs.content" notin ctx.ftsIndexes
      let (found, _) = db.get(SchemaFtsIndexPrefix & "docs.content")
      check not found
      db.close()
    block:
      var db2 = newLSMTree(dir)
      var ctx2 = newExecutionContext(db2)
      check "docs.content" notin ctx2.ftsIndexes  # no ghost rebuild
      db2.close()
    removeDir(dir)

  test "DROP INDEX removes FTS index by column key":
    let dir = "/tmp/baradb_schema_persist_dropfts_col"
    removeDir(dir)
    block:
      var db = newLSMTree(dir)
      var ctx = newExecutionContext(db)
      check execSql(ctx, "CREATE TABLE docs (id INTEGER PRIMARY KEY, content TEXT)").success
      check execSql(ctx, "INSERT INTO docs (id, content) VALUES (1, 'quick brown fox')").success
      # No custom name — idxName defaults to colKey (docs.content)
      check execSql(ctx, "CREATE INDEX ON docs (content) USING FTS").success
      check ctx.ftsIndexes.hasKey("docs.content")
      # Drop by column name — matches endsWith(".content")
      let d = execSql(ctx, "DROP INDEX content")
      check d.success
      check "docs.content" notin ctx.ftsIndexes
      let (found, _) = db.get(SchemaFtsIndexPrefix & "docs.content")
      check not found
      db.close()
    block:
      var db2 = newLSMTree(dir)
      var ctx2 = newExecutionContext(db2)
      check "docs.content" notin ctx2.ftsIndexes  # no ghost rebuild
      db2.close()
    removeDir(dir)

  test "DROP INDEX removes HNSW index and its schema key":
    let dir = "/tmp/baradb_schema_persist_drophnsw"
    removeDir(dir)
    block:
      var db = newLSMTree(dir)
      var ctx = newExecutionContext(db)
      check execSql(ctx, "CREATE TABLE vecs (id INTEGER PRIMARY KEY, embedding TEXT)").success
      check execSql(ctx, "INSERT INTO vecs (id, embedding) VALUES (1, '[1.0, 0.0, 0.0]')").success
      check execSql(ctx, "CREATE INDEX vecs_hnsw ON vecs (embedding) USING HNSW").success
      check ctx.vectorIndexes.hasKey("vecs.embedding")
      let d = execSql(ctx, "DROP INDEX vecs_hnsw")
      check d.success
      check "vecs.embedding" notin ctx.vectorIndexes
      let (found, _) = db.get(SchemaVecIndexPrefix & "vecs.embedding")
      check not found
      db.close()
    block:
      var db2 = newLSMTree(dir)
      var ctx2 = newExecutionContext(db2)
      check "vecs.embedding" notin ctx2.vectorIndexes  # no ghost rebuild
      db2.close()
    removeDir(dir)

  test "DROP TABLE removes engine indexes for that table":
    let dir = "/tmp/baradb_schema_persist_droptbl"
    removeDir(dir)
    block:
      var db = newLSMTree(dir)
      var ctx = newExecutionContext(db)
      check execSql(ctx, "CREATE TABLE docs (id INTEGER PRIMARY KEY, content TEXT)").success
      check execSql(ctx, "INSERT INTO docs (id, content) VALUES (1, 'quick brown fox')").success
      check execSql(ctx, "CREATE INDEX docs_fts ON docs (content) USING FTS").success
      check execSql(ctx, "CREATE TABLE vecs (id INTEGER PRIMARY KEY, embedding TEXT)").success
      check execSql(ctx, "INSERT INTO vecs (id, embedding) VALUES (1, '[1.0, 0.0, 0.0]')").success
      check execSql(ctx, "CREATE INDEX vecs_hnsw ON vecs (embedding) USING HNSW").success
      check ctx.ftsIndexes.hasKey("docs.content")
      check ctx.vectorIndexes.hasKey("vecs.embedding")
      check execSql(ctx, "DROP TABLE docs").success
      check "docs.content" notin ctx.ftsIndexes
      check execSql(ctx, "DROP TABLE vecs").success
      check "vecs.embedding" notin ctx.vectorIndexes
      let (ftsFound, _) = db.get(SchemaFtsIndexPrefix & "docs.content")
      check not ftsFound
      let (vecFound, _) = db.get(SchemaVecIndexPrefix & "vecs.embedding")
      check not vecFound
      db.close()
    block:
      var db2 = newLSMTree(dir)
      var ctx2 = newExecutionContext(db2)
      check "docs.content" notin ctx2.ftsIndexes    # no ghost rebuild
      check "vecs.embedding" notin ctx2.vectorIndexes
      db2.close()
    removeDir(dir)

  test "Stable schema key format":
    check tableSchemaKey("users") == "_schema:tables:users"
    check serializeTableDdl(TableDef(
      name: "t",
      columns: @[ColumnDef(name: "id", colType: "INT", isPk: true)],
      pkColumns: @["id"],
    )).contains("PRIMARY KEY")
