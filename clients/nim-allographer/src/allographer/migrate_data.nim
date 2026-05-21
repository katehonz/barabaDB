## Cross-DB Migration Engine — migrate data between any allographer-supported DB and BaraDB.
##
## Usage:
##   migrate(sourceRdb, targetRdb, tables)           — migrate specific tables
##   migrateAll(sourceRdb, targetRdb)                 — migrate all tables
##   migrateFromUrl(sourceUrl, targetUrl)             — URL-based migration
##
## Supported source databases: PostgreSQL, MySQL, MariaDB, SQLite, SurrealDB
## Target: BaraDB (native migration system via CREATE MIGRATION + MIGRATION UP)

import std/asyncdispatch
import std/json
import std/options
import std/strformat
import std/strutils
import std/tables
import std/times

import ./env
import ./query_builder/libs/database_url
import ./query_builder/models/baradb/baradb_types
import ./query_builder/models/baradb/baradb_query
import ./query_builder/models/baradb/baradb_exec

when isExistsPostgres:
  import ./query_builder/models/postgres/postgres_types
  import ./query_builder/models/postgres/postgres_query
  import ./query_builder/models/postgres/postgres_exec
  import ./query_builder/models/postgres/postgres_open

when isExistsMysql:
  import ./query_builder/models/mysql/mysql_types
  import ./query_builder/models/mysql/mysql_query
  import ./query_builder/models/mysql/mysql_exec
  import ./query_builder/models/mysql/mysql_open

when isExistsMariadb:
  import ./query_builder/models/mariadb/mariadb_types
  import ./query_builder/models/mariadb/mariadb_query
  import ./query_builder/models/mariadb/mariadb_exec
  import ./query_builder/models/mariadb/mariadb_open

when isExistsSqlite:
  import ./query_builder/models/sqlite/sqlite_types
  import ./query_builder/models/sqlite/sqlite_query
  import ./query_builder/models/sqlite/sqlite_exec
  import ./query_builder/models/sqlite/sqlite_open

when isExistsSurrealdb:
  import ./query_builder/models/surreal/surreal_types
  import ./query_builder/models/surreal/surreal_query
  import ./query_builder/models/surreal/surreal_exec
  import ./query_builder/models/surreal/surreal_open

# ==============================================================================
# Types
# ==============================================================================

type
  ColumnInfo* = tuple[name: string, typ: string, isPk: bool, isNullable: bool, defaultVal: string]

  TableInfo* = object
    name*: string
    columns*: seq[ColumnInfo]

  MigrationProgress* = object
    tableName*: string
    totalRows*: int
    transferredRows*: int
    status*: string  # "pending", "in_progress", "done", "failed"
    error*: string

  MigrationReport* = object
    sourceDb*: string
    targetDb*: string
    tablesTotal*: int
    tablesDone*: int
    rowsTotal*: int
    rowsTransferred*: int
    startedAt*: float
    completedAt*: float
    errors*: seq[string]

# ==============================================================================
# Type Mapping: source DB → BaraDB
# ==============================================================================

const BARADB_TYPE_MAP = {
  # PostgreSQL
  "smallint": "SMALLINT",
  "integer": "INTEGER",
  "bigint": "BIGINT",
  "serial": "SERIAL",
  "bigserial": "BIGSERIAL",
  "real": "REAL",
  "double precision": "DOUBLE PRECISION",
  "numeric": "DECIMAL",
  "decimal": "DECIMAL",
  "character": "VARCHAR(255)",
  "character varying": "VARCHAR",
  "varchar": "VARCHAR",
  "text": "TEXT",
  "boolean": "BOOLEAN",
  "bool": "BOOLEAN",
  "date": "DATE",
  "timestamp": "TIMESTAMP",
  "timestamp without time zone": "TIMESTAMP",
  "timestamp with time zone": "TIMESTAMPTZ",
  "time": "TIME",
  "time without time zone": "TIME",
  "bytea": "BYTEA",
  "uuid": "UUID",
  "json": "JSON",
  "jsonb": "JSON",
  # MySQL/MariaDB
  "tinyint": "SMALLINT",
  "mediumint": "INTEGER",
  "int": "INTEGER",
  "float": "REAL",
  "double": "DOUBLE PRECISION",
  "char": "VARCHAR(255)",
  "longtext": "TEXT",
  "mediumtext": "TEXT",
  "tinytext": "TEXT",
  "blob": "BYTEA",
  "longblob": "BYTEA",
  "mediumblob": "BYTEA",
  "tinyblob": "BYTEA",
  "datetime": "TIMESTAMP",
  "enum": "VARCHAR(255)",
  "set": "VARCHAR(255)",
  "year": "SMALLINT",
  # SQLite
  "int": "INTEGER",
  "integer": "INTEGER",
  "real": "REAL",
  "blob": "BYTEA",
  # SurrealDB
  "string": "VARCHAR(255)",
  "number": "DOUBLE PRECISION",
  "object": "JSON",
  "array": "JSON",
}.toTable()

proc mapType*(sourceType: string): string =
  ## Map a source database column type to the closest BaraDB type.
  let lower = sourceType.toLower().split("(")[0].strip()
  if lower in BARADB_TYPE_MAP:
    result = BARADB_TYPE_MAP[lower]
  else:
    result = "VARCHAR(255)"

# ==============================================================================
# Schema Extraction
# ==============================================================================

# --- PostgreSQL ---
when isExistsPostgres:
  proc extractSchema*(rdb: PostgresConnections): Future[seq[TableInfo]] {.async.} =
    result = @[]
    let tables = await rdb.raw(
      "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public'"
    ).get()
    for table in tables:
      let tableName = table["table_name"].getStr()
      if tableName == "_allographer_migrations": continue
      var cols: seq[ColumnInfo] = @[]
      let columns = await rdb.raw(
        """SELECT c.column_name, c.data_type, c.is_nullable, c.column_default,
           CASE WHEN pk.column_name IS NOT NULL THEN true ELSE false END as is_pk
           FROM information_schema.columns c
           LEFT JOIN (
             SELECT ku.column_name FROM information_schema.table_constraints tc
             JOIN information_schema.key_column_usage ku
               ON tc.constraint_name = ku.constraint_name
             WHERE tc.constraint_type = 'PRIMARY KEY' AND tc.table_name = ?
           ) pk ON c.column_name = pk.column_name
           WHERE c.table_name = ?
           ORDER BY c.ordinal_position""",
        %*[tableName, tableName]
      ).get()
      for col in columns:
        cols.add((
          name: col["column_name"].getStr(),
          typ: col["data_type"].getStr(),
          isPk: col["is_pk"].getStr() == "true",
          isNullable: col["is_nullable"].getStr() == "YES",
          defaultVal: if col.hasKey("column_default") and not col["column_default"].isNull:
                        col["column_default"].getStr() else: ""
        ))
      result.add(TableInfo(name: tableName, columns: cols))

# --- MySQL ---
when isExistsMysql:
  proc extractSchema*(rdb: MysqlConnections): Future[seq[TableInfo]] {.async.} =
    result = @[]
    let tables = await rdb.raw(
      "SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE()"
    ).get()
    for table in tables:
      let tableName = table["table_name"].getStr()
      if tableName == "_allographer_migrations": continue
      var cols: seq[ColumnInfo] = @[]
      let columns = await rdb.raw(
        """SELECT column_name, data_type, is_nullable, column_default,
           column_key FROM information_schema.columns
           WHERE table_name = ? AND table_schema = DATABASE()
           ORDER BY ordinal_position""",
        %*[tableName]
      ).get()
      for col in columns:
        cols.add((
          name: col["column_name"].getStr(),
          typ: col["data_type"].getStr(),
          isPk: col["column_key"].getStr() == "PRI",
          isNullable: col["is_nullable"].getStr() == "YES",
          defaultVal: if col.hasKey("column_default") and not col["column_default"].isNull:
                        col["column_default"].getStr() else: ""
        ))
      result.add(TableInfo(name: tableName, columns: cols))

# --- MariaDB ---
when isExistsMariadb:
  proc extractSchema*(rdb: MariadbConnections): Future[seq[TableInfo]] {.async.} =
    result = @[]
    let tables = await rdb.raw(
      "SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE()"
    ).get()
    for table in tables:
      let tableName = table["table_name"].getStr()
      if tableName == "_allographer_migrations": continue
      var cols: seq[ColumnInfo] = @[]
      let columns = await rdb.raw(
        """SELECT column_name, data_type, is_nullable, column_default,
           column_key FROM information_schema.columns
           WHERE table_name = ? AND table_schema = DATABASE()
           ORDER BY ordinal_position""",
        %*[tableName]
      ).get()
      for col in columns:
        cols.add((
          name: col["column_name"].getStr(),
          typ: col["data_type"].getStr(),
          isPk: col["column_key"].getStr() == "PRI",
          isNullable: col["is_nullable"].getStr() == "YES",
          defaultVal: if col.hasKey("column_default") and not col["column_default"].isNull:
                        col["column_default"].getStr() else: ""
        ))
      result.add(TableInfo(name: tableName, columns: cols))

# --- SQLite ---
when isExistsSqlite:
  proc extractSchema*(rdb: SqliteConnections): Future[seq[TableInfo]] {.async.} =
    result = @[]
    let tables = await rdb.raw(
      "SELECT name as table_name FROM sqlite_master WHERE type = 'table'"
    ).get()
    for table in tables:
      let tableName = table["table_name"].getStr()
      if tableName == "_allographer_migrations": continue
      if tableName == "sqlite_sequence": continue
      var cols: seq[ColumnInfo] = @[]
      let columns = await rdb.raw("PRAGMA table_info(?)", %*[tableName]).get()
      for col in columns:
        cols.add((
          name: col["name"].getStr(),
          typ: col["type"].getStr(),
          isPk: col["pk"].getStr() == "1",
          isNullable: col["notnull"].getStr() == "0",
          defaultVal: if col.hasKey("dflt_value") and not col["dflt_value"].isNull:
                        col["dflt_value"].getStr() else: ""
        ))
      result.add(TableInfo(name: tableName, columns: cols))

# --- SurrealDB ---
when isExistsSurrealdb:
  proc extractSchema*(rdb: SurrealConnections): Future[seq[TableInfo]] {.async.} =
    result = @[]
    let dbResponse = await rdb.raw("INFO FOR DB").get()
    if dbResponse.len == 0: return
    let tables = dbResponse[0]["result"]["tables"]
    for tableName, _ in tables.getFields().pairs:
      if tableName == "_allographer_migrations": continue
      if tableName == "_autoincrement_sequences": continue
      var cols: seq[ColumnInfo] = @[]
      let tableInfo = await rdb.raw(&"INFO FOR TABLE {tableName}").get()
      if tableInfo.len > 0:
        let fields = tableInfo[0]["result"]["fields"]
        for fieldName, _ in fields.getFields().pairs:
          cols.add((
            name: fieldName,
            typ: "string",  # SurrealDB is schemaless
            isPk: fieldName == "id",
            isNullable: fieldName != "id",
            defaultVal: ""
          ))
      result.add(TableInfo(name: tableName, columns: cols))

# ==============================================================================
# DDL Generation
# ==============================================================================

proc generateBaraDBDDL*(table: TableInfo): tuple[upSql: string, downSql: string] =
  ## Generate CREATE TABLE (UP) and DROP TABLE (DOWN) DDL for BaraDB.
  var colDefs: seq[string] = @[]
  for col in table.columns:
    var def = &"`{col.name}` {mapType(col.typ)}"
    if col.isPk:
      def &= " PRIMARY KEY"
    if not col.isNullable:
      def &= " NOT NULL"
    if col.defaultVal.len > 0:
      def &= " DEFAULT " & col.defaultVal
    colDefs.add(def)
  let upSql = &"CREATE TABLE `{table.name}` ({colDefs.join(\", \")})"
  let downSql = &"DROP TABLE IF EXISTS `{table.name}`"
  return (upSql, downSql)

proc generateMigrationName*(tableName: string): string =
  let timestamp = getTime().toUnix()
  return &"migrate_{tableName}_{timestamp}"

# ==============================================================================
# Data Transfer
# ==============================================================================

proc transferTable*(sourceConn: BaradbConnections, targetConn: BaradbConnections,
                    tableName: string, batchSize: int = 1000): Future[MigrationProgress] {.async.} =
  ## Generic table transfer for BaraDB→BaraDB (used internally).
  ## For cross-DB, use the typed overloads below.
  result = MigrationProgress(tableName: tableName, totalRows: 0,
                              transferredRows: 0, status: "in_progress")
  try:
    # Count rows
    let countVal = await sourceConn.table(tableName).count()
    result.totalRows = countVal

    # Transfer in batches
    var offset = 0
    while offset < result.totalRows:
      let rows = await sourceConn.table(tableName)
        .limit(batchSize)
        .offset(offset)
        .get()
      if rows.len == 0: break
      await targetConn.table(tableName).insert(rows)
      result.transferredRows += rows.len
      offset += batchSize

    result.status = "done"
  except CatchableError as e:
    result.status = "failed"
    result.error = e.msg

# Typed overloads for each source DB type
when isExistsPostgres:
  proc transferTable*(sourceConn: PostgresConnections, targetConn: BaradbConnections,
                      tableName: string, batchSize: int = 1000): Future[MigrationProgress] {.async.} =
    result = MigrationProgress(tableName: tableName, totalRows: 0,
                                transferredRows: 0, status: "in_progress")
    try:
      let countVal = await sourceConn.table(tableName).count()
      result.totalRows = countVal
      var offset = 0
      while offset < result.totalRows:
        let rows = await sourceConn.table(tableName)
          .limit(batchSize)
          .offset(offset)
          .get()
        if rows.len == 0: break
        await targetConn.table(tableName).insert(rows)
        result.transferredRows += rows.len
        offset += batchSize
      result.status = "done"
    except CatchableError as e:
      result.status = "failed"
      result.error = e.msg

when isExistsMysql:
  proc transferTable*(sourceConn: MysqlConnections, targetConn: BaradbConnections,
                      tableName: string, batchSize: int = 1000): Future[MigrationProgress] {.async.} =
    result = MigrationProgress(tableName: tableName, totalRows: 0,
                                transferredRows: 0, status: "in_progress")
    try:
      let countVal = await sourceConn.table(tableName).count()
      result.totalRows = countVal
      var offset = 0
      while offset < result.totalRows:
        let rows = await sourceConn.table(tableName)
          .limit(batchSize)
          .offset(offset)
          .get()
        if rows.len == 0: break
        await targetConn.table(tableName).insert(rows)
        result.transferredRows += rows.len
        offset += batchSize
      result.status = "done"
    except CatchableError as e:
      result.status = "failed"
      result.error = e.msg

when isExistsMariadb:
  proc transferTable*(sourceConn: MariadbConnections, targetConn: BaradbConnections,
                      tableName: string, batchSize: int = 1000): Future[MigrationProgress] {.async.} =
    result = MigrationProgress(tableName: tableName, totalRows: 0,
                                transferredRows: 0, status: "in_progress")
    try:
      let countVal = await sourceConn.table(tableName).count()
      result.totalRows = countVal
      var offset = 0
      while offset < result.totalRows:
        let rows = await sourceConn.table(tableName)
          .limit(batchSize)
          .offset(offset)
          .get()
        if rows.len == 0: break
        await targetConn.table(tableName).insert(rows)
        result.transferredRows += rows.len
        offset += batchSize
      result.status = "done"
    except CatchableError as e:
      result.status = "failed"
      result.error = e.msg

when isExistsSqlite:
  proc transferTable*(sourceConn: SqliteConnections, targetConn: BaradbConnections,
                      tableName: string, batchSize: int = 1000): Future[MigrationProgress] {.async.} =
    result = MigrationProgress(tableName: tableName, totalRows: 0,
                                transferredRows: 0, status: "in_progress")
    try:
      let countVal = await sourceConn.table(tableName).count()
      result.totalRows = countVal
      var offset = 0
      while offset < result.totalRows:
        let rows = await sourceConn.table(tableName)
          .limit(batchSize)
          .offset(offset)
          .get()
        if rows.len == 0: break
        await targetConn.table(tableName).insert(rows)
        result.transferredRows += rows.len
        offset += batchSize
      result.status = "done"
    except CatchableError as e:
      result.status = "failed"
      result.error = e.msg

when isExistsSurrealdb:
  proc transferTable*(sourceConn: SurrealConnections, targetConn: BaradbConnections,
                      tableName: string, batchSize: int = 1000): Future[MigrationProgress] {.async.} =
    result = MigrationProgress(tableName: tableName, totalRows: 0,
                                transferredRows: 0, status: "in_progress")
    try:
      let countVal = await sourceConn.table(tableName).count()
      result.totalRows = countVal
      var offset = 0
      while offset < result.totalRows:
        let rows = await sourceConn.table(tableName)
          .limit(batchSize)
          .offset(offset)
          .get()
        if rows.len == 0: break
        await targetConn.table(tableName).insert(rows)
        result.transferredRows += rows.len
        offset += batchSize
      result.status = "done"
    except CatchableError as e:
      result.status = "failed"
      result.error = e.msg

# ==============================================================================
# Full Migration Orchestrator
# ==============================================================================

when isExistsPostgres:
  proc migrate*(sourceConn: PostgresConnections, targetConn: BaradbConnections,
                tables: seq[string] = @[], batchSize: int = 1000): Future[MigrationReport] {.async.} =
    result = MigrationReport(sourceDb: "PostgreSQL", targetDb: "BaraDB",
                              startedAt: epochTime())
    try:
      let schema = await extractSchema(sourceConn)
      var tablesToMigrate: seq[TableInfo]
      if tables.len > 0:
        for t in schema:
          if t.name in tables: tablesToMigrate.add(t)
      else:
        tablesToMigrate = schema

      result.tablesTotal = tablesToMigrate.len
      for table in tablesToMigrate:
        let (upSql, downSql) = generateBaraDBDDL(table)
        let migName = generateMigrationName(table.name)
        discard await targetConn.createMigration(migName, upSql, downSql)
        discard await targetConn.applyMigration(migName)
        let progress = await transferTable(sourceConn, targetConn, table.name, batchSize)
        if progress.status == "done":
          result.tablesDone += 1
          result.rowsTransferred += progress.transferredRows
        else:
          result.errors.add(&"{table.name}: {progress.error}")
    except CatchableError as e:
      result.errors.add(e.msg)
    result.completedAt = epochTime()

when isExistsMysql:
  proc migrate*(sourceConn: MysqlConnections, targetConn: BaradbConnections,
                tables: seq[string] = @[], batchSize: int = 1000): Future[MigrationReport] {.async.} =
    result = MigrationReport(sourceDb: "MySQL", targetDb: "BaraDB",
                              startedAt: epochTime())
    try:
      let schema = await extractSchema(sourceConn)
      var tablesToMigrate: seq[TableInfo]
      if tables.len > 0:
        for t in schema:
          if t.name in tables: tablesToMigrate.add(t)
      else:
        tablesToMigrate = schema
      result.tablesTotal = tablesToMigrate.len
      for table in tablesToMigrate:
        let (upSql, downSql) = generateBaraDBDDL(table)
        let migName = generateMigrationName(table.name)
        discard await targetConn.createMigration(migName, upSql, downSql)
        discard await targetConn.applyMigration(migName)
        let progress = await transferTable(sourceConn, targetConn, table.name, batchSize)
        if progress.status == "done":
          result.tablesDone += 1
          result.rowsTransferred += progress.transferredRows
        else:
          result.errors.add(&"{table.name}: {progress.error}")
    except CatchableError as e:
      result.errors.add(e.msg)
    result.completedAt = epochTime()

when isExistsMariadb:
  proc migrate*(sourceConn: MariadbConnections, targetConn: BaradbConnections,
                tables: seq[string] = @[], batchSize: int = 1000): Future[MigrationReport] {.async.} =
    result = MigrationReport(sourceDb: "MariaDB", targetDb: "BaraDB",
                              startedAt: epochTime())
    try:
      let schema = await extractSchema(sourceConn)
      var tablesToMigrate: seq[TableInfo]
      if tables.len > 0:
        for t in schema:
          if t.name in tables: tablesToMigrate.add(t)
      else:
        tablesToMigrate = schema
      result.tablesTotal = tablesToMigrate.len
      for table in tablesToMigrate:
        let (upSql, downSql) = generateBaraDBDDL(table)
        let migName = generateMigrationName(table.name)
        discard await targetConn.createMigration(migName, upSql, downSql)
        discard await targetConn.applyMigration(migName)
        let progress = await transferTable(sourceConn, targetConn, table.name, batchSize)
        if progress.status == "done":
          result.tablesDone += 1
          result.rowsTransferred += progress.transferredRows
        else:
          result.errors.add(&"{table.name}: {progress.error}")
    except CatchableError as e:
      result.errors.add(e.msg)
    result.completedAt = epochTime()

when isExistsSqlite:
  proc migrate*(sourceConn: SqliteConnections, targetConn: BaradbConnections,
                tables: seq[string] = @[], batchSize: int = 1000): Future[MigrationReport] {.async.} =
    result = MigrationReport(sourceDb: "SQLite", targetDb: "BaraDB",
                              startedAt: epochTime())
    try:
      let schema = await extractSchema(sourceConn)
      var tablesToMigrate: seq[TableInfo]
      if tables.len > 0:
        for t in schema:
          if t.name in tables: tablesToMigrate.add(t)
      else:
        tablesToMigrate = schema
      result.tablesTotal = tablesToMigrate.len
      for table in tablesToMigrate:
        let (upSql, downSql) = generateBaraDBDDL(table)
        let migName = generateMigrationName(table.name)
        discard await targetConn.createMigration(migName, upSql, downSql)
        discard await targetConn.applyMigration(migName)
        let progress = await transferTable(sourceConn, targetConn, table.name, batchSize)
        if progress.status == "done":
          result.tablesDone += 1
          result.rowsTransferred += progress.transferredRows
        else:
          result.errors.add(&"{table.name}: {progress.error}")
    except CatchableError as e:
      result.errors.add(e.msg)
    result.completedAt = epochTime()

when isExistsSurrealdb:
  proc migrate*(sourceConn: SurrealConnections, targetConn: BaradbConnections,
                tables: seq[string] = @[], batchSize: int = 1000): Future[MigrationReport] {.async.} =
    result = MigrationReport(sourceDb: "SurrealDB", targetDb: "BaraDB",
                              startedAt: epochTime())
    try:
      let schema = await extractSchema(sourceConn)
      var tablesToMigrate: seq[TableInfo]
      if tables.len > 0:
        for t in schema:
          if t.name in tables: tablesToMigrate.add(t)
      else:
        tablesToMigrate = schema
      result.tablesTotal = tablesToMigrate.len
      for table in tablesToMigrate:
        let (upSql, downSql) = generateBaraDBDDL(table)
        let migName = generateMigrationName(table.name)
        discard await targetConn.createMigration(migName, upSql, downSql)
        discard await targetConn.applyMigration(migName)
        let progress = await transferTable(sourceConn, targetConn, table.name, batchSize)
        if progress.status == "done":
          result.tablesDone += 1
          result.rowsTransferred += progress.transferredRows
        else:
          result.errors.add(&"{table.name}: {progress.error}")
    except CatchableError as e:
      result.errors.add(e.msg)
    result.completedAt = epochTime()

# ==============================================================================
# URL-based migration
# ==============================================================================

proc `$`*(report: MigrationReport): string =
  let duration = report.completedAt - report.startedAt
  result = &"Migration: {report.sourceDb} → {report.targetDb}\n"
  result &= &"  Tables: {report.tablesDone}/{report.tablesTotal}\n"
  result &= &"  Rows:   {report.rowsTransferred}\n"
  result &= &"  Time:   {duration:.1f}s\n"
  if report.errors.len > 0:
    result &= "  Errors:\n"
    for err in report.errors:
      result &= &"    - {err}\n"