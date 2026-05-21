import std/strformat
import ../../models/table
import ./baradb_query_type

proc resetTable*(self: BaradbSchema) =
  let sql = &"DELETE FROM `{self.table.name}`"
  discard waitFor self.rdb.raw(sql).exec()
