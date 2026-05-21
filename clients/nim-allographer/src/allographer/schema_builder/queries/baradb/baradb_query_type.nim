import ../../../query_builder/models/baradb/baradb_types
import ../../models/table
import ../../models/column

type BaradbSchema* = ref object
  rdb*: BaradbConnections
  table*: Table
  column*: Column

proc new*(_: type BaradbSchema, rdb: BaradbConnections, table: Table): BaradbSchema =
  return BaradbSchema(rdb: rdb, table: table)

proc new*(_: type BaradbSchema, rdb: BaradbConnections, table: Table, column: Column): BaradbSchema =
  return BaradbSchema(rdb: rdb, table: table, column: column)
