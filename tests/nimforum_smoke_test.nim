## NimForum Adapter Smoke Test — comprehensive validation
import std/unittest
import std/osproc
import std/os
import std/strtabs
import std/times

import ../adaptors/nim/baradb_sqlite as sqlite

suite "NimForum Adapter Smoke Test":
  var serverProcess: Process
  var port: int
  var dataDir: string

  setup:
    port = 35000 + (getTime().toUnix.int mod 10000)
    dataDir = getTempDir() / "baradb_nimforum_" & $port
    createDir(dataDir)
    var env = newStringTable()
    for key, val in envPairs():
      env[key] = val
    env["BARADB_PORT"] = $port
    env["BARADB_DATA_DIR"] = dataDir
    env["BARADB_LOG_LEVEL"] = "error"
    serverProcess = startProcess("./build/baradadb", env=env, options={poStdErrToStdOut, poDaemon})
    # Wait for server to be ready (with timeout)
    var pingDb: DbConn
    var connected = false
    for i in 0 ..< 50:
      sleep(100)
      try:
        pingDb = open("127.0.0.1:" & $port, "", "", "default")
        connected = true
        break
      except:
        discard
    if not connected:
      serverProcess.terminate()
      discard serverProcess.waitForExit()
      removeDir(dataDir)
      raise newException(IOError, "Server failed to start")
    pingDb.close()

  teardown:
    if serverProcess != nil:
      serverProcess.terminate()
      discard serverProcess.waitForExit()
    removeDir(dataDir)

  test "Adapter basic CRUD over TCP":
    var db = open("127.0.0.1:" & $port, "", "", "default")

    db.exec(sql"CREATE TABLE nf_test (id INT PRIMARY KEY, name STRING)")
    db.exec(sql"INSERT INTO nf_test (id, name) VALUES (1, 'hello')")
    db.exec(sql"INSERT INTO nf_test (id, name) VALUES (2, 'world')")

    let rows = db.getAllRows(sql"SELECT * FROM nf_test")
    check rows.len == 2

    let row = db.getRow(sql"SELECT * FROM nf_test WHERE id = 1")
    check row.len == 2
    check row[0] == "1"
    check row[1] == "hello"

    let val = db.getValue(sql"SELECT name FROM nf_test WHERE id = 2")
    check val == "world"

    let cnt = db.getValue(sql"SELECT count(*) FROM nf_test")
    check cnt == "2"

    db.close()

  test "Adapter parameterized queries":
    var db = open("127.0.0.1:" & $port, "", "", "default")

    db.exec(sql"CREATE TABLE nf_params (id INT PRIMARY KEY, val STRING)")
    db.exec(sql"INSERT INTO nf_params (id, val) VALUES (?, ?)", 10, "ten")
    db.exec(sql"INSERT INTO nf_params (id, val) VALUES (?, ?)", 20, "twenty")

    let row = db.getRow(sql"SELECT val FROM nf_params WHERE id = ?", 10)
    check row.len >= 1
    check row[row.len - 1] == "ten"

    db.close()

  test "getRow returns @[] for missing rows":
    var db = open("127.0.0.1:" & $port, "", "", "default")
    db.exec(sql"CREATE TABLE nf_missing (id INT PRIMARY KEY)")
    let row = db.getRow(sql"SELECT * FROM nf_missing WHERE id = 999")
    check row.len == 0
    db.close()

  test "insertID and nextId":
    var db = open("127.0.0.1:" & $port, "", "", "default")
    db.exec(sql"CREATE TABLE nf_ids (id INT PRIMARY KEY, name STRING)")

    let id1 = db.insertID(sql"INSERT INTO nf_ids (id, name) VALUES (5, 'five')")
    check id1 == 5

    let next = db.nextId("nf_ids")
    check next == 6

    db.close()

  test "Transactions (BEGIN/COMMIT/ROLLBACK)":
    var db = open("127.0.0.1:" & $port, "", "", "default")
    db.exec(sql"CREATE TABLE nf_txn (id INT PRIMARY KEY)")

    db.dbBegin()
    db.exec(sql"INSERT INTO nf_txn (id) VALUES (1)")
    db.dbCommit()
    check db.getValue(sql"SELECT count(*) FROM nf_txn") == "1"

    db.dbBegin()
    db.exec(sql"INSERT INTO nf_txn (id) VALUES (2)")
    db.dbRollback()
    check db.getValue(sql"SELECT count(*) FROM nf_txn") == "1"

    db.close()

  test "fastRows iterator":
    var db = open("127.0.0.1:" & $port, "", "", "default")
    db.exec(sql"CREATE TABLE nf_iter (id INT PRIMARY KEY)")
    db.exec(sql"INSERT INTO nf_iter (id) VALUES (1)")
    db.exec(sql"INSERT INTO nf_iter (id) VALUES (2)")
    db.exec(sql"INSERT INTO nf_iter (id) VALUES (3)")

    var count = 0
    for r in db.fastRows(sql"SELECT id FROM nf_iter ORDER BY id"):
      count.inc
    check count == 3

    db.close()

  test "execAffectedRows":
    var db = open("127.0.0.1:" & $port, "", "", "default")
    db.exec(sql"CREATE TABLE nf_aff (id INT PRIMARY KEY, name STRING)")
    db.exec(sql"INSERT INTO nf_aff (id, name) VALUES (1, 'a')")
    db.exec(sql"INSERT INTO nf_aff (id, name) VALUES (2, 'b')")

    let affected = db.execAffectedRows(sql"DELETE FROM nf_aff WHERE id = 1")
    check affected == 1

    db.close()

  test "tryExec success and failure":
    var db = open("127.0.0.1:" & $port, "", "", "default")
    db.exec(sql"CREATE TABLE nf_try (id INT PRIMARY KEY)")

    check db.tryExec(sql"INSERT INTO nf_try (id) VALUES (1)") == true
    check db.tryExec(sql"INSERT INTO nf_try (id) VALUES (1)") == false

    db.close()

  test "NimForum schema creation":
    var db = open("127.0.0.1:" & $port, "", "", "default")

    # Create nimforum-like schema (adapter preprocesses DATETIME/TIMESTAMP/INET)
    db.exec(sql"""
      CREATE TABLE thread (
        id INT PRIMARY KEY,
        name STRING NOT NULL,
        views INT NOT NULL,
        modified DATETIME NOT NULL DEFAULT DATETIME('now')
      )
    """)
    db.exec(sql"CREATE UNIQUE INDEX ThreadNameIx ON thread (name)")

    db.exec(sql"""
      CREATE TABLE person (
        id INT PRIMARY KEY,
        name STRING NOT NULL,
        password STRING NOT NULL,
        email STRING NOT NULL,
        creation DATETIME NOT NULL DEFAULT DATETIME('now'),
        salt STRING NOT NULL,
        user_status STRING NOT NULL,
        lastOnline DATETIME NOT NULL DEFAULT DATETIME('now'),
        ban STRING NOT NULL DEFAULT ''
      )
    """)
    db.exec(sql"CREATE UNIQUE INDEX UserNameIx ON person (name)")

    db.exec(sql"""
      CREATE TABLE post (
        id INT PRIMARY KEY,
        author INT NOT NULL,
        ip STRING NOT NULL,
        header STRING NOT NULL,
        content STRING NOT NULL,
        thread INT NOT NULL,
        creation DATETIME NOT NULL DEFAULT DATETIME('now')
      )
    """)

    db.exec(sql"""
      CREATE TABLE session (
        id INT PRIMARY KEY,
        ip STRING NOT NULL,
        password STRING NOT NULL,
        userid INT NOT NULL,
        lastModified DATETIME NOT NULL DEFAULT DATETIME('now')
      )
    """)

    db.exec(sql"""
      CREATE TABLE antibot (
        id INT PRIMARY KEY,
        ip STRING NOT NULL,
        answer STRING NOT NULL,
        created DATETIME NOT NULL DEFAULT DATETIME('now')
      )
    """)

    db.exec(sql"CREATE INDEX PersonStatusIdx ON person(user_status)")
    db.exec(sql"CREATE INDEX PostByAuthorIdx ON post(thread, author)")

    # Insert and query forum data
    db.exec(sql"INSERT INTO thread (id, name, views) VALUES (1, 'First Thread', 0)")
    db.exec(sql"INSERT INTO person (id, name, password, email, salt, user_status, ban) VALUES (1, 'admin', 'pw', 'a@b.c', 'salt', 'active', '')")
    db.exec(sql"INSERT INTO post (id, author, ip, header, content, thread) VALUES (1, 1, '127.0.0.1', 'Hello', 'World', 1)")

    let threads = db.getAllRows(sql"SELECT * FROM thread")
    check threads.len == 1

    let posts = db.getAllRows(sql"SELECT * FROM post WHERE thread = 1")
    check posts.len == 1

    db.close()

  test "NimForum-like operations":
    var db = open("127.0.0.1:" & $port, "", "", "default")

    db.exec(sql"CREATE TABLE nf_ops (id INT PRIMARY KEY, views INT NOT NULL)")
    db.exec(sql"INSERT INTO nf_ops (id, views) VALUES (1, 0)")

    # Update views (like nimforum does)
    let affected = db.execAffectedRows(sql"UPDATE nf_ops SET views = views + 1 WHERE id = 1")
    check affected == 1

    let views = db.getValue(sql"SELECT views FROM nf_ops WHERE id = 1")
    check views == "1"

    # Try update with DATETIME('now') (preprocessed by adapter)
    db.exec(sql"CREATE TABLE nf_dt (id INT PRIMARY KEY, modified DATETIME)")
    db.exec(sql"INSERT INTO nf_dt (id, modified) VALUES (1, DATETIME('now'))")
    let dtRow = db.getRow(sql"SELECT modified FROM nf_dt WHERE id = 1")
    check dtRow.len == 1
    check dtRow[0].len > 0

    db.close()
