import std/strformat
import ../../models/table
import ../../models/column
import ./baradb_query_type

proc dropColumn*(self: BaradbSchema, isReset: bool) =
  let sql = &"ALTER TABLE `{self.table.name}` DROP COLUMN `{self.column.name}`"
  discard waitFor self.rdb.raw(sql).exec()
