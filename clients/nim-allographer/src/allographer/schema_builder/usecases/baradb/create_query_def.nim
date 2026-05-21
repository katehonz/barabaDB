import ../../../query_builder/models/baradb/baradb_types
import ../../queries/baradb/baradb_query_type
import ../../models/table
import ../../models/column

proc createSchema*(rdb: BaradbConnections, table: Table): BaradbSchema =
  return BaradbSchema.new(rdb, table)

proc createSchema*(rdb: BaradbConnections, table: Table, column: Column): BaradbSchema =
  return BaradbSchema.new(rdb, table, column)
