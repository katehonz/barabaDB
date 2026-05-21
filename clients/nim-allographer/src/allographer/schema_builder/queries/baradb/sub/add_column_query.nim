import std/strformat
import ../../models/table
import ../../models/column
import ./create_column_query

proc addColumnString*(table: Table, column: Column): string =
  result = createColumnString(table, column)
