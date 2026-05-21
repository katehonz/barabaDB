import std/strformat
import ../../models/table
import ../../models/column

proc createColumnString*(table: Table, column: Column): string =
  result = &"`{column.name}` {column.typ}"
  if not column.isNullable:
    result.add(" NOT NULL")
  if column.isUnique:
    result.add(" UNIQUE")
  if column.isDefault:
    result.add(&" DEFAULT {column.default}")

proc createForeignString*(table: Table, column: Column): string =
  result = &"FOREIGN KEY (`{column.name}`) REFERENCES `{column.info}`"

proc createIndexString*(table: Table, column: Column): string =
  result = &"CREATE INDEX `{table.name}_{column.name}_idx` ON `{table.name}` (`{column.name}`)"

proc createUpdatedAtString*(table: Table, column: Column): string =
  result = ""

proc createCommentColumn*(table: Table, column: Column): string =
  result = ""
