import std/strformat
import ../../models/table
import ../../models/column
import ./baradb_query_type

proc addColumn*(self: BaradbSchema, isReset: bool) =
  let sql = &"ALTER TABLE `{self.table.name}` ADD COLUMN `{self.column.name}` {self.column.typ}"
  discard waitFor self.rdb.raw(sql).exec()
