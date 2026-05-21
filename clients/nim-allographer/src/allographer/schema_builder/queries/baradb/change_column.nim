import std/strformat
import ../../models/table
import ../../models/column
import ./baradb_query_type
import ./sub/change_column_query

proc changeColumn*(self: BaradbSchema, isReset: bool) =
  let colDef = changeColumnString(self.table, self.column)
  let sql = &"ALTER TABLE `{self.table.name}` ALTER COLUMN `{self.column.name}` TYPE {colDef}"
  discard waitFor self.rdb.raw(sql).exec()
