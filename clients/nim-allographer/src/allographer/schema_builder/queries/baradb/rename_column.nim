import std/strformat
import ../../models/table
import ../../models/column
import ./baradb_query_type

proc renameColumn*(self: BaradbSchema, isReset: bool) =
  let sql = &"ALTER TABLE `{self.table.name}` RENAME COLUMN `{self.column.name}` TO `{self.column.previousName}`"
  discard waitFor self.rdb.raw(sql).exec()
