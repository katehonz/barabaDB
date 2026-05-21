import std/strformat
import ../../models/table
import ../../models/column
import ./baradb_query_type
import ./sub/add_column_query

proc addColumn*(self: BaradbSchema, isReset: bool) =
  let colDef = addColumnString(self.table, self.column)
  let sql = &"ALTER TABLE `{self.table.name}` ADD COLUMN {colDef}"
  discard waitFor self.rdb.raw(sql).exec()
