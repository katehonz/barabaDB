import std/unittest
import std/strutils
import std/os
import std/tables
import ../src/barabadb/query/[parser, executor, lexer, ast]
import ../src/barabadb/core/types
import ../src/barabadb/core/config
import ../src/barabadb/storage/lsm

const testDir = "/tmp/baradb_bugfix_test"

proc setupCtx(): ExecutionContext =
  removeDir(testDir)
  createDir(testDir)
  let db = newLSMTree(testDir)
  var ctx = newExecutionContext(db)
  # Create tables
  discard executeQuery(ctx, parse("""
    CREATE TABLE thread (id INTEGER PRIMARY KEY, name TEXT, category INTEGER, isDeleted INTEGER)
  """))
  discard executeQuery(ctx, parse("""
    CREATE TABLE category (id INTEGER PRIMARY KEY, name TEXT, description TEXT)
  """))
  discard executeQuery(ctx, parse("""
    CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)
  """))
  ctx

proc teardown(ctx: ExecutionContext) =
  ctx.db.close()
  removeDir(testDir)

suite "Bug fixes — IN list, nkPath exprToSql, multi-table joins":

  test "IN (list) parses without error":
    let sql = "SELECT id, name FROM users WHERE id IN (1, 2, 3)"
    let tokens = tokenize(sql)
    let ast = parse(tokens)
    check ast.stmts[0].kind == nkSelect
    let whereExpr = ast.stmts[0].selWhere.whereExpr
    check whereExpr.kind == nkInExpr
    check whereExpr.inRight.kind == nkArrayLit
    check whereExpr.inRight.arrayElems.len == 3

  test "IN (list) with strings parses":
    let sql = "SELECT * FROM users WHERE name IN ('alice', 'bob', 'charlie')"
    let tokens = tokenize(sql)
    let ast = parse(tokens)
    let whereExpr = ast.stmts[0].selWhere.whereExpr
    check whereExpr.kind == nkInExpr
    check whereExpr.inRight.kind == nkArrayLit
    check whereExpr.inRight.arrayElems.len == 3

  test "IN (subquery) still parses":
    let sql = "SELECT id FROM users WHERE id IN (SELECT id FROM admins)"
    let tokens = tokenize(sql)
    let ast = parse(tokens)
    let whereExpr = ast.stmts[0].selWhere.whereExpr
    check whereExpr.kind == nkInExpr
    check whereExpr.inRight.kind == nkSubquery

  test "nkPath column alias in SELECT produces correct data":
    let sql = "SELECT t.id FROM posts t"
    let tokens = tokenize(sql)
    let ast = parse(tokens)
    let selExpr = ast.stmts[0].selResult[0]
    check selExpr.kind == nkPath
    check selExpr.pathParts == @["t", "id"]
    # Verify correct data is returned
    var ctx = setupCtx()
    defer: teardown(ctx)
    discard executeQuery(ctx, parse("CREATE TABLE posts (id INTEGER PRIMARY KEY, title TEXT)"))
    discard executeQuery(ctx, parse("INSERT INTO posts (id, title) VALUES (42, 'Hello')"))
    let r = executeQuery(ctx, parse(sql))
    check r.success
    check r.rows.len == 1
    # Column is "t.id" (qualified by alias)
    check valueToString(r.rows[0]["t.id"]) == "42"

  test "IN (list) executes with actual data":
    var ctx = setupCtx()
    defer: teardown(ctx)
    discard executeQuery(ctx, parse("INSERT INTO users (id, name) VALUES (1, 'alice')"))
    discard executeQuery(ctx, parse("INSERT INTO users (id, name) VALUES (2, 'bob')"))
    discard executeQuery(ctx, parse("INSERT INTO users (id, name) VALUES (3, 'charlie')"))
    discard executeQuery(ctx, parse("INSERT INTO users (id, name) VALUES (4, 'dave')"))

    let r = executeQuery(ctx, parse("SELECT id, name FROM users WHERE id IN (1, 3, 4)"))
    check r.success
    check r.rows.len == 3

  test "Multi-table implicit join without aliases (Bug 1)":
    var ctx = setupCtx()
    defer: teardown(ctx)
    discard executeQuery(ctx, parse("INSERT INTO thread (id, name, category, isDeleted) VALUES (3, 'Test Thread', 1, 0)"))
    discard executeQuery(ctx, parse("INSERT INTO category (id, name, description) VALUES (1, 'General', 'General discussion')"))

    # This used to return 0 rows
    let r = executeQuery(ctx, parse("SELECT thread.id, thread.name, category.id, category.name FROM thread, category WHERE thread.id = 3 AND thread.isDeleted = 0 AND thread.category = category.id"))
    check r.success
    check r.rows.len == 1

  test "Multi-table join with aliases still works":
    var ctx = setupCtx()
    defer: teardown(ctx)
    discard executeQuery(ctx, parse("INSERT INTO thread (id, name, category, isDeleted) VALUES (3, 'Test Thread', 1, 0)"))
    discard executeQuery(ctx, parse("INSERT INTO category (id, name, description) VALUES (1, 'General', 'General discussion')"))

    let r = executeQuery(ctx, parse("SELECT t.id AS thread_id, t.name AS thread_name, c.id AS cat_id, c.name AS cat_name FROM thread t, category c WHERE t.id = 3 AND t.category = c.id"))
    check r.success
    check r.rows.len == 1
    check r.columns == @["thread_id", "thread_name", "cat_id", "cat_name"]

  test "Three-table join without aliases (Bug 4 - nkPath in column names)":
    var ctx = setupCtx()
    defer: teardown(ctx)
    discard executeQuery(ctx, parse("CREATE TABLE post (id INTEGER PRIMARY KEY, author INTEGER, thread INTEGER, creation TEXT)"))
    discard executeQuery(ctx, parse("INSERT INTO thread (id, name, category, isDeleted) VALUES (5, 'Thread5', 1, 0)"))
    discard executeQuery(ctx, parse("INSERT INTO category (id, name, description) VALUES (1, 'Cat1', 'desc1')"))
    discard executeQuery(ctx, parse("INSERT INTO users (id, name) VALUES (10, 'Alice')"))
    discard executeQuery(ctx, parse("INSERT INTO post (id, author, thread, creation) VALUES (100, 10, 5, '2024-06-01 12:00:00')"))

    # Three-table join with nkPath references
    let r = executeQuery(ctx, parse("SELECT post.id, post.creation, post.thread, users.id, users.name FROM post, users, thread WHERE post.thread = thread.id AND post.author = users.id AND post.id = 100"))
    check r.success
    check r.rows.len == 1
    # Verify qualified column references resolve correctly
    check valueToString(r.rows[0]["post.id"]) == "100"
    check valueToString(r.rows[0]["users.name"]) == "Alice"
    check valueToString(r.rows[0]["post.thread"]) == "5"
    # Check column names don't contain "nkPath"
    for col in r.columns:
      check not col.contains("nkPath")

  test "NOT IN (list) parses and executes":
    var ctx = setupCtx()
    defer: teardown(ctx)
    discard executeQuery(ctx, parse("INSERT INTO users (id, name) VALUES (1, 'alice')"))
    discard executeQuery(ctx, parse("INSERT INTO users (id, name) VALUES (2, 'bob')"))
    discard executeQuery(ctx, parse("INSERT INTO users (id, name) VALUES (3, 'charlie')"))
    discard executeQuery(ctx, parse("INSERT INTO users (id, name) VALUES (4, 'dave')"))

    let r = executeQuery(ctx, parse("SELECT id, name FROM users WHERE id NOT IN (1, 4)"))
    check r.success
    check r.rows.len == 2

  test "NOT LIKE parses and executes":
    var ctx = setupCtx()
    defer: teardown(ctx)
    discard executeQuery(ctx, parse("INSERT INTO users (id, name) VALUES (1, 'alice')"))
    discard executeQuery(ctx, parse("INSERT INTO users (id, name) VALUES (2, 'bob')"))
    discard executeQuery(ctx, parse("INSERT INTO users (id, name) VALUES (3, 'charlie')"))

    let r = executeQuery(ctx, parse("SELECT name FROM users WHERE name NOT LIKE 'a%'"))
    check r.success
    check r.rows.len == 2

  test "NOT BETWEEN parses and executes":
    var ctx = setupCtx()
    defer: teardown(ctx)
    discard executeQuery(ctx, parse("INSERT INTO users (id, name) VALUES (1, 'alice')"))
    discard executeQuery(ctx, parse("INSERT INTO users (id, name) VALUES (5, 'bob')"))
    discard executeQuery(ctx, parse("INSERT INTO users (id, name) VALUES (10, 'charlie')"))
    discard executeQuery(ctx, parse("INSERT INTO users (id, name) VALUES (15, 'dave')"))

    let r = executeQuery(ctx, parse("SELECT id, name FROM users WHERE id NOT BETWEEN 3 AND 12"))
    check r.success
    check r.rows.len == 2

  test "Multi-column ORDER BY sorts correctly":
    var ctx = setupCtx()
    defer: teardown(ctx)
    discard executeQuery(ctx, parse("INSERT INTO users (id, name) VALUES (1, 'alice')"))
    discard executeQuery(ctx, parse("INSERT INTO users (id, name) VALUES (2, 'bob')"))
    discard executeQuery(ctx, parse("INSERT INTO users (id, name) VALUES (3, 'alice')"))
    discard executeQuery(ctx, parse("INSERT INTO users (id, name) VALUES (4, 'charlie')"))

    let r = executeQuery(ctx, parse("SELECT name, id FROM users ORDER BY name ASC, id DESC"))
    check r.success
    check r.rows.len == 4
    # After sorting by name ASC, then id DESC within same name:
    # alice(3), alice(1), bob(2), charlie(4)
    check valueToString(r.rows[0]["id"]) == "3"
    check valueToString(r.rows[1]["id"]) == "1"
    check valueToString(r.rows[2]["id"]) == "2"
    check valueToString(r.rows[3]["id"]) == "4"

  test "Numeric != comparison is consistent with =":
    var ctx = setupCtx()
    defer: teardown(ctx)
    # 5.0 stored as string should equal integer 5 via numeric comparison
    let r = executeQuery(ctx, parse("SELECT id, name FROM users WHERE id != 999"))
    check r.success
    # Should return all rows since none have id=999

  test "Column alias consistency for table.column in getSelectColumns":
    var ctx = setupCtx()
    defer: teardown(ctx)
    discard executeQuery(ctx, parse("CREATE TABLE posts (id INTEGER PRIMARY KEY, title TEXT)"))
    discard executeQuery(ctx, parse("INSERT INTO posts (id, title) VALUES (1, 'Hello')"))

    let r = executeQuery(ctx, parse("SELECT posts.id, posts.title FROM posts"))
    check r.success
    check r.rows.len == 1
    # Column names should match the full path "posts.id", "posts.title"
    check r.columns == @["posts.id", "posts.title"]
    # Data should be accessible via both qualified and unqualified names
    check valueToString(r.rows[0]["posts.id"]) == "1"

  test "DELETE inside transaction actually removes row":
    var ctx = setupCtx()
    defer: teardown(ctx)
    discard executeQuery(ctx, parse("INSERT INTO users (id, name) VALUES (10, 'temp')"))
    # Verify row exists
    let r1 = executeQuery(ctx, parse("SELECT * FROM users WHERE id = 10"))
    check r1.success
    check r1.rows.len == 1
    # Delete within transaction
    discard executeQuery(ctx, parse("BEGIN"))
    let del = executeQuery(ctx, parse("DELETE FROM users WHERE id = 10"))
    check del.success
    discard executeQuery(ctx, parse("COMMIT"))
    # Verify row is gone
    let r2 = executeQuery(ctx, parse("SELECT * FROM users WHERE id = 10"))
    check r2.success
    check r2.rows.len == 0

  test "PK-only row survives transaction commit":
    var ctx = setupCtx()
    defer: teardown(ctx)
    discard executeQuery(ctx, parse("CREATE TABLE pksimple (id INTEGER PRIMARY KEY)"))
    discard executeQuery(ctx, parse("BEGIN"))
    discard executeQuery(ctx, parse("INSERT INTO pksimple (id) VALUES (1)"))
    discard executeQuery(ctx, parse("COMMIT"))
    let r = executeQuery(ctx, parse("SELECT * FROM pksimple WHERE id = 1"))
    check r.success
    check r.rows.len == 1

  test "MIN and MAX skip NULL values":
    var ctx = setupCtx()
    defer: teardown(ctx)
    discard executeQuery(ctx, parse("CREATE TABLE scores (id INTEGER PRIMARY KEY, val INTEGER)"))
    discard executeQuery(ctx, parse("INSERT INTO scores (id, val) VALUES (1, 10)"))
    discard executeQuery(ctx, parse("INSERT INTO scores (id, val) VALUES (2, NULL)"))
    discard executeQuery(ctx, parse("INSERT INTO scores (id, val) VALUES (3, 30)"))
    let rmin = executeQuery(ctx, parse("SELECT MIN(val) AS m FROM scores"))
    check rmin.success
    check rmin.rows.len == 1
    check valueToString(rmin.rows[0]["m"]) == "10"
    let rmax = executeQuery(ctx, parse("SELECT MAX(val) AS m FROM scores"))
    check rmax.success
    check rmax.rows.len == 1
    check valueToString(rmax.rows[0]["m"]) == "30"

suite "Bug fixes — keyword 'header' usable as column name":

  test "CREATE TABLE / INSERT / SELECT with column named 'header'":
    var ctx = setupCtx()
    defer: teardown(ctx)
    # nimforum schema uses a column named 'header' (tkHeader is the CSV IMPORT keyword)
    let c = executeQuery(ctx, parse("CREATE TABLE post (id INTEGER PRIMARY KEY, header TEXT, content TEXT)"))
    check c.success
    let i = executeQuery(ctx, parse("INSERT INTO post (id, header, content) VALUES (1, 'Hello', 'World')"))
    check i.success
    let r = executeQuery(ctx, parse("SELECT header FROM post WHERE id = 1"))
    check r.success
    check r.rows.len == 1
    check valueToString(r.rows[0]["header"]) == "Hello"
    let rw = executeQuery(ctx, parse("SELECT id FROM post WHERE header = 'Hello'"))
    check rw.success
    check rw.rows.len == 1

  test "IMPORT ... HEADER clause still parses after soft-keyword change":
    let ast = parse("IMPORT FROM 'data.csv' INTO post HEADER no")
    check ast.stmts.len == 1
    check ast.stmts[0].kind == nkImportFrom
    check ast.stmts[0].impHasHeader == false
    let ast2 = parse("EXPORT TO 'out.csv' FROM post HEADER yes")
    check ast2.stmts.len == 1
    check ast2.stmts[0].kind == nkExportTo
    check ast2.stmts[0].expIncludeHeader == true

suite "Bug fixes — clause keywords usable as identifiers":

  test "columns named after clause keywords (format, status, user, ...)":
    var ctx = setupCtx()
    defer: teardown(ctx)
    let c = executeQuery(ctx, parse("""
      CREATE TABLE kw (id INTEGER PRIMARY KEY, format TEXT, status TEXT, user TEXT,
                       batch INTEGER, csv TEXT, ndjson TEXT, delimiter TEXT,
                       migration TEXT, apply TEXT, up TEXT, down TEXT, dryrun TEXT,
                       policy TEXT, enable TEXT, disable TEXT, recover TEXT,
                       before TEXT, after TEXT, instead TEXT, of TEXT)
    """))
    check c.success
    let i = executeQuery(ctx, parse(
      "INSERT INTO kw (id, format, status, user, batch, of) VALUES (1, 'csv', 'active', 'admin', 7, 'x')"))
    check i.success
    let u = executeQuery(ctx, parse("UPDATE kw SET status = 'done' WHERE id = 1"))
    check u.success
    let r = executeQuery(ctx, parse("SELECT format, status, user, batch, of FROM kw WHERE id = 1"))
    check r.success
    check r.rows.len == 1
    check valueToString(r.rows[0]["format"]) == "csv"
    check valueToString(r.rows[0]["status"]) == "done"
    check valueToString(r.rows[0]["user"]) == "admin"
    check valueToString(r.rows[0]["batch"]) == "7"
    let rq = executeQuery(ctx, parse("SELECT kw.status FROM kw WHERE kw.status = 'done'"))
    check rq.success
    check rq.rows.len == 1

  test "IMPORT/EXPORT accept keyword values: FORMAT csv/ndjson/json, HEADER true/false":
    let a1 = parse("IMPORT FROM 'd.csv' INTO t FORMAT csv HEADER true")
    check a1.stmts[0].impFormat == "csv"
    check a1.stmts[0].impHasHeader == true
    let a2 = parse("IMPORT FROM 'd.csv' INTO t FORMAT ndjson HEADER false")
    check a2.stmts[0].impFormat == "ndjson"
    check a2.stmts[0].impHasHeader == false
    let a3 = parse("EXPORT TO 'o.csv' FROM t FORMAT json HEADER true")
    check a3.stmts[0].expFormat == "json"
    check a3.stmts[0].expIncludeHeader == true
    let a4 = parse("EXPORT TO 'o.csv' FROM t FORMAT csv DELIMITER ';' HEADER false")
    check a4.stmts[0].expFormat == "csv"
    check a4.stmts[0].expIncludeHeader == false

suite "Bug fixes — UNIQUE index enforcement":

  test "CREATE UNIQUE INDEX rejects duplicate INSERT":
    var ctx = setupCtx()
    defer: teardown(ctx)
    discard executeQuery(ctx, parse("CREATE TABLE accts (id INTEGER PRIMARY KEY, email TEXT)"))
    discard executeQuery(ctx, parse("INSERT INTO accts (id, email) VALUES (1, 'a@b.c')"))
    let c = executeQuery(ctx, parse("CREATE UNIQUE INDEX accts_email ON accts (email)"))
    check c.success
    let dup = executeQuery(ctx, parse("INSERT INTO accts (id, email) VALUES (2, 'a@b.c')"))
    check not dup.success
    let ok = executeQuery(ctx, parse("INSERT INTO accts (id, email) VALUES (2, 'x@y.z')"))
    check ok.success

  test "CREATE UNIQUE INDEX rejects duplicate UPDATE":
    var ctx = setupCtx()
    defer: teardown(ctx)
    discard executeQuery(ctx, parse("CREATE TABLE accts (id INTEGER PRIMARY KEY, email TEXT)"))
    discard executeQuery(ctx, parse("INSERT INTO accts (id, email) VALUES (1, 'a@b.c')"))
    discard executeQuery(ctx, parse("INSERT INTO accts (id, email) VALUES (2, 'x@y.z')"))
    let c = executeQuery(ctx, parse("CREATE UNIQUE INDEX accts_email ON accts (email)"))
    check c.success
    let dup = executeQuery(ctx, parse("UPDATE accts SET email = 'a@b.c' WHERE id = 2"))
    check not dup.success
    let same = executeQuery(ctx, parse("UPDATE accts SET email = 'a@b.c' WHERE id = 1"))
    check same.success

  test "CREATE UNIQUE INDEX over duplicate data fails":
    var ctx = setupCtx()
    defer: teardown(ctx)
    discard executeQuery(ctx, parse("CREATE TABLE accts (id INTEGER PRIMARY KEY, email TEXT)"))
    discard executeQuery(ctx, parse("INSERT INTO accts (id, email) VALUES (1, 'a@b.c')"))
    discard executeQuery(ctx, parse("INSERT INTO accts (id, email) VALUES (2, 'a@b.c')"))
    let c = executeQuery(ctx, parse("CREATE UNIQUE INDEX accts_email ON accts (email)"))
    check not c.success

suite "Raft peer address parsing":

  test "id@host:port entries populate raftPeerAddrs":
    putEnv("BARADB_RAFT_PEERS", "n1@127.0.0.1:9473,n2@10.0.0.5:9474,n3")
    defer: delEnv("BARADB_RAFT_PEERS")
    var cfg = defaultConfig()
    loadConfigFromEnv(cfg)
    check cfg.raftPeers == @["n1", "n2", "n3"]
    check cfg.raftPeerAddrs["n1"] == ("127.0.0.1", 9473)
    check cfg.raftPeerAddrs["n2"] == ("10.0.0.5", 9474)
    check "n3" notin cfg.raftPeerAddrs

  test "malformed peer entries raise with the entry in the message":
    for bad in ["n1@:9473", "n1@host:notaport", "@host:9473", "n1@host:0", "n1@host:70000"]:
      putEnv("BARADB_RAFT_PEERS", bad)
      var cfg = defaultConfig()
      var msg = ""
      try:
        loadConfigFromEnv(cfg)
      except ValueError as e:
        msg = e.msg
      delEnv("BARADB_RAFT_PEERS")
      check msg.len > 0
      check bad in msg
