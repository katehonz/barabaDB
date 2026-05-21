import std/strformat
import std/sequtils
import ../../models/table
import ../../models/column
import ./baradb_query_type

proc createTable*(self: BaradbSchema, isReset: bool) =
  var query = ""
  for i, column in self.table.columns:
    if query.len > 0: query.add(", ")
    query.add(&"`{column.name}` {column.typ}")
  if self.table.primary.len > 0:
    let primary = self.table.primary.map(proc(row: string): string = &"`{row}`").join(", ")
    query.add(&", PRIMARY KEY({primary})")
  let sql = &"CREATE TABLE IF NOT EXISTS `{self.table.name}` ({query})"
  discard waitFor self.rdb.raw(sql).exec()
