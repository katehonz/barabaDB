## Schema persistence — CREATE TABLE / data survive reopen
import std/unittest
import std/os
import std/strutils
import std/tables
import barabadb/storage/lsm
import barabadb/query/executor
import barabadb/query/parser
import barabadb/query/ast

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

  test "Stable schema key format":
    check tableSchemaKey("users") == "_schema:tables:users"
    check serializeTableDdl(TableDef(
      name: "t",
      columns: @[ColumnDef(name: "id", colType: "INT", isPk: true)],
      pkColumns: @["id"],
    )).contains("PRIMARY KEY")
