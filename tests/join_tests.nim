import std/unittest
import std/os
import std/strutils
import std/times
import std/monotimes
import std/tables
import barabadb/core/types
import barabadb/query/executor as qexec
import barabadb/query/parser
import barabadb/query/ast
import barabadb/storage/lsm

proc execSql(ctx: qexec.ExecutionContext, sql: string): qexec.ExecResult =
  qexec.executeQuery(ctx, parse(sql))

# ---------------------------------------------------------------------------
suite "JOIN execution":
  var db: LSMTree
  var ctx: qexec.ExecutionContext
  var testDir: string

  setup:
    testDir = getTempDir() / "baradb_join_test_" & $getCurrentProcessId() & "_" & $getMonoTime().ticks
    createDir(testDir)
    db = newLSMTree(testDir)
    ctx = qexec.newExecutionContext(db)
    discard execSql(ctx, "CREATE TABLE users (id INT, name TEXT)")
    discard execSql(ctx, "CREATE TABLE orders (id INT, user_id INT, total REAL)")
    discard execSql(ctx, "INSERT INTO users (id, name) VALUES (1, 'Alice')")
    discard execSql(ctx, "INSERT INTO users (id, name) VALUES (2, 'Bob')")
    discard execSql(ctx, "INSERT INTO orders (id, user_id, total) VALUES (10, 1, 99.5)")
    discard execSql(ctx, "INSERT INTO orders (id, user_id, total) VALUES (20, 1, 23.0)")
    discard execSql(ctx, "INSERT INTO orders (id, user_id, total) VALUES (30, 3, 150.0)")

  teardown:
    removeDir(testDir)

  test "INNER JOIN returns matching rows only":
    let r = execSql(ctx, "SELECT * FROM users u JOIN orders o ON u.id = o.user_id")
    check r.rows.len == 2
    check r.rows[0]["name"] == "Alice"
    check r.rows[0]["total"] == "99.5"

  test "LEFT JOIN keeps unmatched left rows":
    let r = execSql(ctx, "SELECT * FROM users u LEFT JOIN orders o ON u.id = o.user_id")
    check r.rows.len == 3
    check r.rows[0]["name"] == "Alice"
    check r.rows[1]["name"] == "Alice"
    check r.rows[2]["name"] == "Bob"
    check r.rows[2]["total"] == ""  # NULL represented as empty string

  test "RIGHT JOIN keeps unmatched right rows":
    let r = execSql(ctx, "SELECT * FROM users u RIGHT JOIN orders o ON u.id = o.user_id")
    check r.rows.len == 3
    check r.rows[2]["id"] == "30"
    check r.rows[2]["name"] == ""  # NULL
    check r.rows[2]["total"] == "150.0"

  test "FULL JOIN keeps all rows":
    let r = execSql(ctx, "SELECT * FROM users u FULL JOIN orders o ON u.id = o.user_id")
    check r.rows.len == 4

  test "CROSS JOIN cartesian product":
    let r = execSql(ctx, "SELECT * FROM users u CROSS JOIN orders o")
    check r.rows.len == 6

  test "aliased column projection":
    let r = execSql(ctx, "SELECT u.name, o.total FROM users u JOIN orders o ON u.id = o.user_id")
    check r.rows.len == 2
    check r.rows[0]["name"] == "Alice"
    check r.rows[0]["total"] == "99.5"
    check "id" notin r.rows[0]

  test "count after FULL JOIN":
    let r = execSql(ctx, "SELECT COUNT(*) AS cnt FROM users u FULL JOIN orders o ON u.id = o.user_id")
    check r.rows.len == 1
    check r.rows[0]["cnt"] == "4"

  test "count after CROSS JOIN":
    let r = execSql(ctx, "SELECT COUNT(*) AS cnt FROM users u CROSS JOIN orders o")
    check r.rows[0]["cnt"] == "6"

  test "LATERAL JOIN with correlated subquery":
    let r = execSql(ctx,
      "SELECT u.name, recent.total FROM users u JOIN LATERAL (SELECT o.total FROM orders o WHERE o.user_id = u.id ORDER BY o.total DESC LIMIT 1) AS recent ON 1=1")
    check r.rows.len == 1
    check r.rows[0]["name"] == "Alice"
    check r.rows[0]["total"] == "99.5"

  test "LATERAL JOIN returns no rows when subquery empty":
    let r = execSql(ctx,
      "SELECT u.name, x.total FROM users u JOIN LATERAL (SELECT o.total FROM orders o WHERE o.user_id = u.id AND o.total > 1000) AS x ON 1=1")
    check r.rows.len == 0

  test "LEFT LATERAL JOIN keeps unmatched rows":
    let r = execSql(ctx,
      "SELECT u.name, x.total FROM users u LEFT JOIN LATERAL (SELECT o.total FROM orders o WHERE o.user_id = u.id ORDER BY o.total DESC LIMIT 1) AS x ON 1=1")
    check r.rows.len == 2
    # Alice has match (99.5), Bob has no orders -> NULL
    var foundBob = false
    for row in r.rows:
      if row["name"] == "Bob":
        check row["total"] == ""
        foundBob = true
    check foundBob

  test "CROSS JOIN LATERAL":
    let r = execSql(ctx,
      "SELECT u.name, x.total FROM users u CROSS JOIN LATERAL (SELECT o.total FROM orders o WHERE o.user_id = u.id) AS x")
    check r.rows.len == 2  # Alice has 2 orders, Bob has 0
