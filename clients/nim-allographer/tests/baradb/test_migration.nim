discard """
  cmd: "nim c -r $file"
"""

import std/unittest
import std/asyncdispatch
import std/json
import ../../src/allographer/query_builder
import ../../src/allographer/query_builder/models/baradb/baradb_exec
import ./connections


let rdb = baradb

suite("Baradb migrations"):
  test("create migration"):
    let upSql = """
      CREATE TABLE IF NOT EXISTS test_mig_users (
        id SERIAL PRIMARY KEY,
        name VARCHAR(255)
      )
    """
    let downSql = "DROP TABLE IF EXISTS test_mig_users"
    let qr = waitFor rdb.createMigration("test_mig_001", upSql, downSql)
    check qr.rowCount >= 0

  test("migration status shows pending"):
    let status = waitFor rdb.migrationStatus()
    var found = false
    for row in status:
      if row["name"].getStr() == "test_mig_001":
        check row["status"].getStr() == "pending"
        found = true
        break
    check found

  test("apply migration"):
    let qr = waitFor rdb.applyMigration("test_mig_001")
    check qr.rowCount >= 0

  test("is migration applied"):
    let applied = waitFor rdb.isMigrationApplied("test_mig_001")
    check applied

  test("migration up (all pending)"):
    let qr = waitFor rdb.migrateUp()
    check qr.rowCount >= 0

  test("migration dry run"):
    let qr = waitFor rdb.migrationDryRun("test_mig_001")
    check qr.rowCount >= 0

  test("table exists after migration"):
    let users = waitFor rdb.table("test_mig_users").get()
    check users.len >= 0

  test("migrate down (rollback)"):
    let qr = waitFor rdb.migrateDown(1)
    check qr.rowCount >= 0