import std/asyncdispatch
import std/strformat
import ../../../query_builder/models/baradb/baradb_types
import ../../../query_builder/models/baradb/baradb_exec
import ../../../query_builder/error
import ../../models/table

proc exec*(rdb: BaradbConnections, queries: seq[string]) =
  for sql in queries:
    discard waitFor rdb.raw(sql).exec()

proc execThenSaveHistory*(rdb: BaradbConnections, name: string, queries: seq[string], checksum: string) =
  ## Register and apply a migration via BaraQL native migration system.
  ## The server handles checksums, locking, rollback, and status tracking.
  let upBody = queries.join("; ")
  var downBody = ""
  # Generate DOWN script: DROP TABLE for CREATE TABLE
  for sql in queries:
    if sql.toLower().startsWith("create table"):
      let parts = sql.split(" ")
      if parts.len >= 3:
        let tableName = parts[2]  # CREATE TABLE `name` ...
        downBody &= &"DROP TABLE IF EXISTS {tableName}; "

  # Register migration on server
  var qr = waitFor rdb.createMigration(name, upBody, downBody)
  if qr.affectedRows < 0:
    raise newException(DbError, "Failed to create migration: " & name)

  # Apply migration
  qr = waitFor rdb.applyMigration(name)
  if qr.affectedRows < 0:
    raise newException(DbError, "Failed to apply migration: " & name)

proc execThenSaveHistory*(rdb: BaradbConnections, name: string, query: string, checksum: string) =
  execThenSaveHistory(rdb, name, @[query], checksum)

proc shouldRun*(rdb: BaradbConnections, table: Table, checksum: string, isReset: bool): bool =
  ## Check with the server whether this migration has already been applied.
  if isReset:
    return true
  try:
    let applied = waitFor rdb.isMigrationApplied(table.name)
    return not applied
  except CatchableError:
    # If server is unavailable or migration doesn't exist, run it
    return true