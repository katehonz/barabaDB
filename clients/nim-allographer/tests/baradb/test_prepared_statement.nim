discard """
  cmd: "nim c -r $file"
"""

import std/unittest
import std/asyncdispatch
import std/json
import std/options
import ../../src/allographer/query_builder
import ../../src/allographer/query_builder/models/baradb/baradb_exec
import ../../src/allographer/query_builder/libs/baradb/baradb_client
import ./connections


let rdb = baradb

suite("Baradb prepared statements"):
  setup:
    # Ensure test table exists
    let createSql = """
      CREATE TABLE IF NOT EXISTS test_prep_data (
        id SERIAL PRIMARY KEY,
        label VARCHAR(255),
        count INTEGER
      )
    """
    waitFor rdb.raw(createSql).exec()

  test("prepare statement"):
    let stmt = waitFor rdb.prepare(
      "SELECT * FROM test_prep_data WHERE count > ?", nArgs = 1
    )
    check not stmt.isClosed

  test("ensureStmt"):
    let entry = rdb.ensureStmt(
      "SELECT * FROM test_prep_data WHERE label = ?", nArgs = 1
    )
    check entry.sql.len > 0
    check entry.nArgs == 1

  test("preparedGet with params"):
    # Insert test data
    waitFor rdb.table("test_prep_data").insert(%*{
      "label": "alpha", "count": 5
    })
    waitFor rdb.table("test_prep_data").insert(%*{
      "label": "beta", "count": 15
    })

    # Query via prepared statement
    let stmt = waitFor rdb.prepare(
      "SELECT * FROM test_prep_data WHERE count > ?", nArgs = 1
    )
    let results = waitFor stmt.preparedGet(@[
      WireValue(kind: fkInt32, int32Val: 10)
    ])
    check results.len >= 1
    if results.len > 0:
      check results[0]["label"].getStr() == "beta"

  test("preparedExec insert"):
    let stmt = waitFor rdb.prepare(
      "INSERT INTO test_prep_data (label, count) VALUES (?, ?)", nArgs = 2
    )
    let affected = waitFor stmt.preparedExec(@[
      WireValue(kind: fkString, strVal: "gamma"),
      WireValue(kind: fkInt32, int32Val: 25)
    ])
    check affected >= 0

  test("flush statement"):
    let stmt = waitFor rdb.prepare(
      "SELECT * FROM test_prep_data", nArgs = 0
    )
    stmt.flushStmt()
    check stmt.isClosed

  test("clear statement cache"):
    rdb.clearStmtCache()
    check true

  test("cleanup"):
    waitFor rdb.raw("DROP TABLE IF EXISTS test_prep_data").exec()
    check true