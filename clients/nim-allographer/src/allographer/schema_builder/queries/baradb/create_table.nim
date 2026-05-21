import std/strformat
import std/sequtils
import ../../models/table
import ../../models/column
import ./baradb_query_type
import ./sub/create_column_query

proc createTable*(self: BaradbSchema, isReset: bool) =
  var query = ""
  for i, column in self.table.columns:
    if query.len > 0: query.add(", ")
    let colDef = createColumnString(self.table, column)
    query.add(colDef)
    if column.typ == rdbTimestamps or column.typ == rdbSoftDelete:
      query.add(", ")
  # Remove trailing comma if present
  if query.endsWith(", "):
    query = query[0..^3]
  if self.table.primary.len > 0:
    let primary = self.table.primary.map(proc(row: string): string = &"`{row}`").join(", ")
    query.add(&", PRIMARY KEY({primary})")
  let sql = &"CREATE TABLE IF NOT EXISTS `{self.table.name}` ({query})"
  discard waitFor self.rdb.raw(sql).exec()
