import std/os
import ../../../query_builder/models/baradb/baradb_types
import ../../models/table
import ../../enums
import ../sub/migration_table_def
import ./create_query_def
import ../../queries/baradb/create_migration_table
import ../../queries/baradb/drop_table

proc drop*(rdb: BaradbConnections, tables: varargs[Table]) =
  let cmd = commandLineParams()
  let isReset = defined(reset) or cmd.contains("--reset")
  var query = createSchema(rdb, migrationTable)
  query.createMigrationTable()
  for table in tables:
    table.usecaseType = Drop
    query = createSchema(rdb, table)
    query.dropTable(isReset)
