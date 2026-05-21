import std/strformat
import ../../models/table
import ./baradb_query_type

proc renameTable*(self: BaradbSchema, isReset: bool) =
  let sql = &"ALTER TABLE `{self.table.name}` RENAME TO `{self.table.previousName}`"
  discard waitFor self.rdb.raw(sql).exec()
