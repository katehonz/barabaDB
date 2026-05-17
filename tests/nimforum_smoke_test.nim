## NimForum Adapter Smoke Test
import std/unittest
import std/osproc
import std/os
import std/strutils
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
    sleep(800)

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
