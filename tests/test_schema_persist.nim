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

  test "Stable schema key format":
    check tableSchemaKey("users") == "_schema:tables:users"
    check serializeTableDdl(TableDef(
      name: "t",
      columns: @[ColumnDef(name: "id", colType: "INT", isPk: true)],
      pkColumns: @["id"],
    )).contains("PRIMARY KEY")
