## Regression: sequential wire-style INSERTs must not crash the process.
## Root cause was ORC cycle collector (markGray SIGSEGV); project uses --mm:arc.
import std/unittest
import std/os
import barabadb/storage/lsm
import barabadb/query/executor
import barabadb/query/parser

proc execSql(ctx: ExecutionContext, sql: string): ExecResult =
  executeQuery(ctx, parse(sql))

suite "Wire insert stress (ARC regression)":
  test "200 sequential INSERTs via executor survive":
    ## Mirrors the wire path (executeQuery under StorageGate each time).
    let dir = "/tmp/baradb_wire_stress"
    removeDir(dir)
    var db = newLSMTree(dir, walSyncMode = wsmNone)
    var ctx = newExecutionContext(db)
    check execSql(ctx, "CREATE TABLE stress (id INT PRIMARY KEY, v TEXT)").success
    for i in 0 ..< 200:
      let r = execSql(ctx, "INSERT INTO stress (id, v) VALUES (" & $i & ", 'v" & $i & "')")
      check r.success
    let sel = execSql(ctx, "SELECT id FROM stress")
    check sel.success
    check sel.rows.len == 200
    db.close()
