import std/strformat
import ../../models/table
import ../../models/column
import ./baradb_query_type

proc changeColumn*(self: BaradbSchema, isReset: bool) =
  let sql = &"ALTER TABLE `{self.table.name}` ALTER COLUMN `{self.column.name}` TYPE {self.column.typ}"
  discard waitFor self.rdb.raw(sql).exec()
