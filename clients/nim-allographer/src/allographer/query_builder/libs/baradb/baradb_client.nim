## BaraDB driver glue for nim-allographer.
## All wire/socket logic lives in the canonical `baradb/client` package.
import std/asyncdispatch
import baradb/client
export client

# === Migration helpers (allographer-specific) ===

proc createMigration*(client: BaraClient, name: string, upBody: string,
                      downBody: string = ""): Future[QueryResult] {.async.} =
  var sql = "CREATE MIGRATION " & name & " { UP: " & upBody & ";"
  if downBody.len > 0:
    sql &= " DOWN: " & downBody & ";"
  sql &= " }"
  return await client.query(sql)

proc applyMigration*(client: BaraClient, name: string): Future[QueryResult] {.async.} =
  return await client.query("APPLY MIGRATION " & name)

proc migrateUp*(client: BaraClient, count: int = 0): Future[QueryResult] {.async.} =
  var sql = "MIGRATION UP"
  if count > 0:
    sql &= " " & $count
  return await client.query(sql)

proc migrateDown*(client: BaraClient, count: int = 1): Future[QueryResult] {.async.} =
  return await client.query("MIGRATION DOWN " & $count)

proc migrationStatus*(client: BaraClient): Future[QueryResult] {.async.} =
  return await client.query("MIGRATION STATUS")

proc migrationDryRun*(client: BaraClient, name: string): Future[QueryResult] {.async.} =
  return await client.query("MIGRATION DRY RUN " & name)
