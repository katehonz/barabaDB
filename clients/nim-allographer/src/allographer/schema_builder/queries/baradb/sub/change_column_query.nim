import std/strformat
import ../../models/table
import ../../models/column

proc changeColumnString*(table: Table, column: Column): string =
  result = &"`{column.name}` {column.typ}"
