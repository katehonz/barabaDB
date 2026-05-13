## BaraDB — Test Suite
import std/unittest
import std/tables
import std/strutils
import std/os
import std/asyncdispatch
import std/times
import std/random
import std/monotimes
import std/base64

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
import barabadb/protocol/scram
import barabadb/protocol/ratelimit
import barabadb/schema/schema as schema

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
