import std/strformat
import ../../models/table
import ../../models/column

proc addColumnString*(table: Table, column: Column): string =
  result = &"`{column.name}` {column.typ}"
  if not column.isNullable:
    result.add(" NOT NULL")
