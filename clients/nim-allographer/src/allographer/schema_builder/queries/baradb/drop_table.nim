import std/strformat
import ../../models/table
import ./baradb_query_type

proc dropTable*(self: BaradbSchema, isReset: bool) =
  let sql = &"DROP TABLE `{self.table.name}`"
  discard waitFor self.rdb.raw(sql).exec()
