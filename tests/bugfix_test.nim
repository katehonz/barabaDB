import std/unittest
import std/strutils
import std/os
import std/tables
import ../src/barabadb/query/[parser, executor, lexer, ast]
import ../src/barabadb/query/exec/params
import ../src/barabadb/query/exec/dml
import ../src/barabadb/core/types
import ../src/barabadb/core/config
import ../src/barabadb/core/replication
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

suite "Production config gate":

  test "validateProductionConfig rejects missing secret":
    putEnv("BARADB_ENV", "production")
    defer: delEnv("BARADB_ENV")
    var cfg = defaultConfig()
    cfg.authEnabled = true
    cfg.jwtSecret = ""
    var msg = ""
    try:
      validateProductionConfig(cfg)
    except ValueError as e:
      msg = e.msg
    check "JWT" in msg or "secret" in msg.toLower()

  test "validateProductionConfig accepts strong secret":
    putEnv("BARADB_ENV", "production")
    defer: delEnv("BARADB_ENV")
    var cfg = defaultConfig()
    cfg.authEnabled = true
    cfg.jwtSecret = "a".repeat(32)
    validateProductionConfig(cfg)  # must not raise

suite "Raft peer address parsing":

  test "BARADB_RAFT_CLIENT_PEERS populates raftPeerClientAddrs":
    putEnv("BARADB_RAFT_CLIENT_PEERS", "n1@10.0.0.1:9472,n2@10.0.0.2:9472")
    defer: delEnv("BARADB_RAFT_CLIENT_PEERS")
    var cfg = defaultConfig()
    loadConfigFromEnv(cfg)
    check cfg.raftPeerClientAddrs.len == 2
    check cfg.raftPeerClientAddrs["n1"] == ("10.0.0.1", 9472)
    check cfg.raftPeerClientAddrs["n2"] == ("10.0.0.2", 9472)

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

suite "Raft put/delete encoding — empty value is not a delete":

  test "PK-only INSERT yields a put pair (deleted == false, empty value)":
    var ctx = setupCtx()
    defer: teardown(ctx)
    discard executeQuery(ctx, parse("CREATE TABLE pkonly (id INTEGER PRIMARY KEY)"))
    let r = executeQuery(ctx, parse("INSERT INTO pkonly (id) VALUES (1)"))
    check r.success
    check r.keyValuePairs.len == 1
    check r.keyValuePairs[0].value.len == 0
    check r.keyValuePairs[0].deleted == false

  test "DELETE yields a delete pair (deleted == true)":
    var ctx = setupCtx()
    defer: teardown(ctx)
    discard executeQuery(ctx, parse("INSERT INTO users (id, name) VALUES (1, 'alice')"))
    let r = executeQuery(ctx, parse("DELETE FROM users WHERE id = 1"))
    check r.success
    check r.keyValuePairs.len == 1
    check r.keyValuePairs[0].deleted == true
    check r.keyValuePairs[0].value.len == 0

  test "UPDATE yields a put pair (deleted == false)":
    var ctx = setupCtx()
    defer: teardown(ctx)
    discard executeQuery(ctx, parse("INSERT INTO users (id, name) VALUES (1, 'alice')"))
    let r = executeQuery(ctx, parse("UPDATE users SET name = 'bob' WHERE id = 1"))
    check r.success
    check r.keyValuePairs.len == 1
    check r.keyValuePairs[0].deleted == false
    check r.keyValuePairs[0].value.len > 0

  test "txn COMMIT pairs carry deleted flag for buffered writes":
    var ctx = setupCtx()
    defer: teardown(ctx)
    discard executeQuery(ctx, parse("CREATE TABLE pkonly (id INTEGER PRIMARY KEY)"))
    discard executeQuery(ctx, parse("INSERT INTO users (id, name) VALUES (1, 'alice')"))
    discard executeQuery(ctx, parse("BEGIN"))
    discard executeQuery(ctx, parse("INSERT INTO pkonly (id) VALUES (7)"))
    discard executeQuery(ctx, parse("DELETE FROM users WHERE id = 1"))
    let r = executeQuery(ctx, parse("COMMIT"))
    check r.success
    check r.keyValuePairs.len == 2
    var sawPut = false
    var sawDelete = false
    for pair in r.keyValuePairs:
      if pair.deleted:
        sawDelete = true
        check pair.value.len == 0
      else:
        sawPut = true
        check pair.key == "pkonly.id=7"
        check pair.value.len == 0  # empty value must still be a put
    check sawPut and sawDelete

  test "apply of a put with empty value keeps the PK-only row":
    var ctx = setupCtx()
    defer: teardown(ctx)
    discard executeQuery(ctx, parse("CREATE TABLE pkonly (id INTEGER PRIMARY KEY)"))
    let r = executeQuery(ctx, parse("INSERT INTO pkonly (id) VALUES (3)"))
    check r.success
    check r.keyValuePairs.len == 1
    let pair = r.keyValuePairs[0]
    # Same decode as applyCommand in src/baradadb.nim for a "put" entry.
    let encoded = pair.key & "\x00" & cast[string](pair.value)
    let parts = encoded.split("\x00")
    check parts.len >= 2
    applyReplicatedPut(ctx, parts[0], cast[seq[byte]](parts[1]))
    let sel = executeQuery(ctx, parse("SELECT * FROM pkonly WHERE id = 3"))
    check sel.success
    check sel.rows.len == 1

suite "Raft write classification":

  test "isWrite classifies DML and COMMIT":
    check isWrite(parse("INSERT INTO t (id) VALUES (1)").stmts[0])
    check isWrite(parse("UPDATE t SET id = 2").stmts[0])
    check isWrite(parse("DELETE FROM t WHERE id = 1").stmts[0])
    check isWrite(parse("COMMIT").stmts[0])
    check not isWrite(parse("SELECT * FROM t").stmts[0])
    check not isWrite(parse("CREATE TABLE t (id INT)").stmts[0])
    check not isWrite(parse("BEGIN").stmts[0])
    check not isWrite(parse("ROLLBACK").stmts[0])

  test "multi-statement queries with a trailing write are still writes":
    ## Server rejection must not look only at stmts[0] — a SELECT first
    ## would otherwise let a follower execute the INSERT.
    let ast = parse("SELECT 1; INSERT INTO t (id) VALUES (1)")
    check ast.stmts.len == 2
    check not isWrite(ast.stmts[0])
    check isWrite(ast.stmts[1])
    var anyWrite = false
    for s in ast.stmts:
      if isWrite(s): anyWrite = true
    check anyWrite

  test "isRaftDdl covers schema but not CREATE DATABASE":
    check isRaftDdl(parse("CREATE TABLE t (id INT)").stmts[0])
    check isRaftDdl(parse("CREATE INDEX i ON t (id)").stmts[0])
    check isRaftDdl(parse("DROP TABLE t").stmts[0])
    check not isRaftDdl(parse("CREATE DATABASE other").stmts[0])
    check not isRaftDdl(parse("INSERT INTO t (id) VALUES (1)").stmts[0])
    check not isRaftDdl(parse("SELECT 1").stmts[0])


suite "Raft TLS config":

  test "default config has raft TLS disabled with empty paths":
    let cfg = defaultConfig()
    check cfg.raftTlsEnabled == false
    check cfg.raftTlsCertFile == ""
    check cfg.raftTlsKeyFile == ""
    check cfg.raftTlsCaFile == ""
    check cfg.raftTlsVerifyPeer == false

  test "env vars parse into raft TLS config":
    putEnv("BARADB_RAFT_TLS_ENABLED", "true")
    putEnv("BARADB_RAFT_TLS_CERT_FILE", "/tmp/raft.crt")
    putEnv("BARADB_RAFT_TLS_KEY_FILE", "/tmp/raft.key")
    putEnv("BARADB_RAFT_TLS_CA_FILE", "/tmp/raft-ca.crt")
    putEnv("BARADB_RAFT_TLS_VERIFY_PEER", "1")
    defer:
      delEnv("BARADB_RAFT_TLS_ENABLED")
      delEnv("BARADB_RAFT_TLS_CERT_FILE")
      delEnv("BARADB_RAFT_TLS_KEY_FILE")
      delEnv("BARADB_RAFT_TLS_CA_FILE")
      delEnv("BARADB_RAFT_TLS_VERIFY_PEER")
    var cfg = defaultConfig()
    loadConfigFromEnv(cfg)
    check cfg.raftTlsEnabled == true
    check cfg.raftTlsCertFile == "/tmp/raft.crt"
    check cfg.raftTlsKeyFile == "/tmp/raft.key"
    check cfg.raftTlsCaFile == "/tmp/raft-ca.crt"
    check cfg.raftTlsVerifyPeer == true


suite "Legacy REP payload encoding — empty value is not a delete":

  test "PK-only put (empty value) round-trips as a put, not a delete":
    ## Regression: the legacy REP receiver used to infer a delete from an empty
    ## value, so PK-only rows (empty LSM value) vanished on the replica.
    let decoded = decodeRepPayload(encodeRepPayload(false, "pkonly.id=3", @[]))
    check decoded.op == ropPut
    check decoded.key == "pkonly.id=3"
    check decoded.value.len == 0

  test "delete round-trips as a delete":
    let decoded = decodeRepPayload(encodeRepPayload(true, "users.id=1", @[]))
    check decoded.op == ropDelete
    check decoded.key == "users.id=1"
    check decoded.value.len == 0

  test "put with a non-empty value preserves the value bytes":
    let decoded = decodeRepPayload(
      encodeRepPayload(false, "users.id=1", cast[seq[byte]]("bob")))
    check decoded.op == ropPut
    check decoded.key == "users.id=1"
    check cast[string](decoded.value) == "bob"

  test "value containing a null byte survives the round-trip":
    ## Decode splits on the FIRST null (the key/value separator) only.
    let value = @[byte('a'), byte(0), byte('b')]
    let decoded = decodeRepPayload(encodeRepPayload(false, "k", value))
    check decoded.op == ropPut
    check decoded.key == "k"
    check decoded.value == value

  test "empty or untagged payloads decode as invalid, not delete":
    check decodeRepPayload(@[]).op == ropInvalid
    check decodeRepPayload(cast[seq[byte]]("Xfoo")).op == ropInvalid


suite "Query operator correctness — audit batch 1":

  test "power operator ** evaluates, not lowered to equality":
    ## Regression: bkPow used to fall through to `else: irOp = irEq`, so
    ## `2 ** 3` evaluated as `2 = 3` (false) instead of 8.
    var ctx = setupCtx()
    defer: teardown(ctx)
    discard executeQuery(ctx, parse("INSERT INTO users (id, name) VALUES (1, 'a')"))
    let r = executeQuery(ctx, parse("SELECT 2 ** 3 AS x FROM users"))
    check r.success
    check r.rows.len == 1
    check parseFloat(valueToString(r.rows[0]["x"])) == 8.0

  test "concat operator ++ concatenates strings":
    ## Regression: bkConcat also fell through to irEq, so `'a' ++ 'b'`
    ## evaluated as `'a' = 'b'` (false) instead of "ab".
    var ctx = setupCtx()
    defer: teardown(ctx)
    discard executeQuery(ctx, parse("INSERT INTO users (id, name) VALUES (1, 'a')"))
    let r = executeQuery(ctx, parse("SELECT 'a' ++ 'b' AS x FROM users"))
    check r.success
    check r.rows.len == 1
    check valueToString(r.rows[0]["x"]) == "ab"

  test "!= is the complement of = for numerically equal values":
    ## Regression: irNeq short-circuited on string inequality, so `1 != 1.0`
    ## was true while `1 = 1.0` was also true (not complements).
    var ctx = setupCtx()
    defer: teardown(ctx)
    discard executeQuery(ctx, parse("INSERT INTO users (id, name) VALUES (1, 'alice')"))
    let eq = executeQuery(ctx, parse("SELECT * FROM users WHERE id = 1.0"))
    let neq = executeQuery(ctx, parse("SELECT * FROM users WHERE id != 1.0"))
    check eq.rows.len == 1   # 1 = 1.0 -> true
    check neq.rows.len == 0  # 1 != 1.0 -> false (old bug returned the row)


suite "Query correctness — audit batch 2":

  test "COUNT(DISTINCT) deduplicates values":
    ## Regression: funcDistinct was parsed but never copied to aggDistinct /
    ## never consulted during aggregation.
    var ctx = setupCtx()
    defer: teardown(ctx)
    discard executeQuery(ctx, parse("INSERT INTO users (id, name) VALUES (1, 'alice')"))
    discard executeQuery(ctx, parse("INSERT INTO users (id, name) VALUES (2, 'bob')"))
    discard executeQuery(ctx, parse("INSERT INTO users (id, name) VALUES (3, 'alice')"))
    let r = executeQuery(ctx, parse("SELECT COUNT(DISTINCT name) AS c FROM users"))
    check r.success
    check r.rows.len == 1
    check valueToString(r.rows[0]["c"]) == "2"

  test "SUM(DISTINCT) sums unique values only":
    var ctx = setupCtx()
    defer: teardown(ctx)
    discard executeQuery(ctx, parse("INSERT INTO users (id, name) VALUES (1, 'a')"))
    discard executeQuery(ctx, parse("INSERT INTO users (id, name) VALUES (2, 'b')"))
    discard executeQuery(ctx, parse("INSERT INTO users (id, name) VALUES (5, 'c')"))
    # ids 1, 2, 5 — insert another row with id-like values via a number col
    discard executeQuery(ctx, parse("CREATE TABLE nums (id INTEGER PRIMARY KEY, n INTEGER)"))
    discard executeQuery(ctx, parse("INSERT INTO nums (id, n) VALUES (1, 10)"))
    discard executeQuery(ctx, parse("INSERT INTO nums (id, n) VALUES (2, 10)"))
    discard executeQuery(ctx, parse("INSERT INTO nums (id, n) VALUES (3, 20)"))
    let r = executeQuery(ctx, parse("SELECT SUM(DISTINCT n) AS s FROM nums"))
    check r.success
    check r.rows.len == 1
    check parseFloat(valueToString(r.rows[0]["s"])) == 30.0

  test "UNION deduplicates without KeyError":
    ## Regression: set-op dedup used row["$value"] which projected rows lack.
    var ctx = setupCtx()
    defer: teardown(ctx)
    discard executeQuery(ctx, parse("INSERT INTO users (id, name) VALUES (1, 'alice')"))
    discard executeQuery(ctx, parse("INSERT INTO users (id, name) VALUES (2, 'bob')"))
    discard executeQuery(ctx, parse("INSERT INTO users (id, name) VALUES (3, 'alice')"))
    let r = executeQuery(ctx, parse(
      "SELECT name FROM users WHERE id = 1 UNION SELECT name FROM users WHERE id = 3"))
    check r.success
    check r.rows.len == 1
    check valueToString(r.rows[0]["name"]) == "alice"

  test "INTERSECT returns common rows":
    var ctx = setupCtx()
    defer: teardown(ctx)
    discard executeQuery(ctx, parse("INSERT INTO users (id, name) VALUES (1, 'alice')"))
    discard executeQuery(ctx, parse("INSERT INTO users (id, name) VALUES (2, 'bob')"))
    let r = executeQuery(ctx, parse(
      "SELECT name FROM users WHERE id <= 2 INTERSECT SELECT name FROM users WHERE id = 1"))
    check r.success
    check r.rows.len == 1
    check valueToString(r.rows[0]["name"]) == "alice"

  test "EXCEPT removes right-side rows":
    var ctx = setupCtx()
    defer: teardown(ctx)
    discard executeQuery(ctx, parse("INSERT INTO users (id, name) VALUES (1, 'alice')"))
    discard executeQuery(ctx, parse("INSERT INTO users (id, name) VALUES (2, 'bob')"))
    let r = executeQuery(ctx, parse(
      "SELECT name FROM users EXCEPT SELECT name FROM users WHERE id = 1"))
    check r.success
    check r.rows.len == 1
    check valueToString(r.rows[0]["name"]) == "bob"

  test "MERGE WHEN MATCHED THEN DELETE removes the row":
    ## Regression: mergeMatchedDelete was parsed but never executed.
    var ctx = setupCtx()
    defer: teardown(ctx)
    discard executeQuery(ctx, parse("CREATE TABLE inv (id INTEGER PRIMARY KEY, qty INTEGER)"))
    discard executeQuery(ctx, parse("INSERT INTO inv (id, qty) VALUES (1, 10)"))
    discard executeQuery(ctx, parse("INSERT INTO inv (id, qty) VALUES (2, 20)"))
    discard executeQuery(ctx, parse("CREATE TABLE deltas (id INTEGER PRIMARY KEY, qty INTEGER)"))
    discard executeQuery(ctx, parse("INSERT INTO deltas (id, qty) VALUES (1, 0)"))
    let r = executeQuery(ctx, parse("""
      MERGE INTO inv AS t
      USING deltas AS s
      ON t.id = s.id
      WHEN MATCHED THEN DELETE
    """))
    check r.success
    check r.affectedRows >= 1
    let left = executeQuery(ctx, parse("SELECT id FROM inv ORDER BY id"))
    check left.success
    check left.rows.len == 1
    check valueToString(left.rows[0]["id"]) == "2"

  test "semi-sync writeLsn returns 0 when replicas do not ack":
    var rm = newReplicationManager(rmSemiSync, syncCount = 1)
    rm.addReplica(newReplica("r1", "10.0.0.1", 9472))
    rm.connectReplica("r1")
    let lsn = rm.writeLsn(@[1'u8, 2, 3])
    check lsn == 0
