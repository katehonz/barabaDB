import std/json
import std/strformat
import ../../../enums
import ../../../models/table
import ../../../models/column


# =============================================================================
# int
# =============================================================================
proc createSerialColumn(column: Column, table: Table): string =
  result = &"`{column.name}` SERIAL PRIMARY KEY"


proc createIntColumn(column: Column, table: Table): string =
  if column.isAutoIncrement:
    result = &"`{column.name}` SERIAL"
  else:
    result = &"`{column.name}` INTEGER"

  if column.isUnique:
    result.add(" UNIQUE")

  if not column.isNullable:
    result.add(" NOT NULL")

  if column.isDefault:
    result.add(&" DEFAULT {column.defaultInt}")

  if column.isUnsigned:
    result.add(&" CHECK (`{column.name}` >= 0)")


proc createSmallIntColumn(column: Column, table: Table): string =
  result = &"`{column.name}` SMALLINT"

  if column.isUnique:
    result.add(" UNIQUE")

  if not column.isNullable:
    result.add(" NOT NULL")

  if column.isDefault:
    result.add(&" DEFAULT {column.defaultInt}")

  if column.isUnsigned:
    result.add(&" CHECK (`{column.name}` >= 0)")


proc createMediumIntColumn(column: Column, table: Table): string =
  if column.isAutoIncrement:
    result = &"`{column.name}` SERIAL"
  else:
    result = &"`{column.name}` INTEGER"

  if column.isUnique:
    result.add(" UNIQUE")

  if not column.isNullable:
    result.add(" NOT NULL")

  if column.isDefault:
    result.add(&" DEFAULT {column.defaultInt}")

  if column.isUnsigned:
    result.add(&" CHECK (`{column.name}` >= 0)")


proc createBigIntColumn(column: Column, table: Table): string =
  if column.isAutoIncrement:
    result = &"`{column.name}` BIGSERIAL"
  else:
    result = &"`{column.name}` BIGINT"

  if column.isUnique:
    result.add(" UNIQUE")

  if not column.isNullable:
    result.add(" NOT NULL")

  if column.isDefault:
    result.add(&" DEFAULT {column.defaultInt}")

  if column.isUnsigned:
    result.add(&" CHECK (`{column.name}` >= 0)")


# =============================================================================
# float
# =============================================================================
proc createDecimalColumn(column: Column, table: Table): string =
  let maximum = column.info["maximum"].getInt
  let digit = column.info["digit"].getInt
  result = &"`{column.name}` DECIMAL({maximum}, {digit})"

  if column.isUnique:
    result.add(" UNIQUE")

  if not column.isNullable:
    result.add(" NOT NULL")

  if column.isDefault:
    result.add(&" DEFAULT {column.defaultFloat}")


proc createDoubleColumn(column: Column, table: Table): string =
  result = &"`{column.name}` DOUBLE PRECISION"

  if column.isUnique:
    result.add(" UNIQUE")

  if not column.isNullable:
    result.add(" NOT NULL")

  if column.isDefault:
    result.add(&" DEFAULT {column.defaultFloat}")


proc createFloatColumn(column: Column, table: Table): string =
  result = &"`{column.name}` REAL"

  if column.isUnique:
    result.add(" UNIQUE")

  if not column.isNullable:
    result.add(" NOT NULL")

  if column.isDefault:
    result.add(&" DEFAULT {column.defaultFloat}")


# =============================================================================
# char
# =============================================================================
proc createCharColumn(column: Column, table: Table): string =
  let maxLength =
    if column.info.kind == JNull:
      1
    else:
      column.info["maxLength"].getInt
  result = &"`{column.name}` CHAR({maxLength})"

  if column.isUnique:
    result.add(" UNIQUE")

  if not column.isNullable:
    result.add(" NOT NULL")

  if column.isDefault:
    result.add(&" DEFAULT '{column.defaultString}'")


proc createStringColumn(column: Column, table: Table): string =
  let maxLength =
    if column.info.kind == JNull:
      255
    else:
      column.info["maxLength"].getInt
  result = &"`{column.name}` VARCHAR({maxLength})"

  if column.isUnique:
    result.add(" UNIQUE")

  if not column.isNullable:
    result.add(" NOT NULL")

  if column.isDefault:
    result.add(&" DEFAULT '{column.defaultString}'")


proc createUuidColumn(column: Column, table: Table): string =
  result = &"`{column.name}` UUID"

  if column.isUnique:
    result.add(" UNIQUE")

  if not column.isNullable:
    result.add(" NOT NULL")

  if column.isDefault:
    result.add(&" DEFAULT '{column.defaultString}'")


# =============================================================================
# text
# =============================================================================
proc createTextColumn(column: Column, table: Table): string =
  result = &"`{column.name}` TEXT"

  if not column.isNullable:
    result.add(" NOT NULL")

  if column.isDefault:
    result.add(&" DEFAULT '{column.defaultString}'")


proc createMediumTextColumn(column: Column, table: Table): string =
  result = &"`{column.name}` TEXT"

  if not column.isNullable:
    result.add(" NOT NULL")

  if column.isDefault:
    result.add(&" DEFAULT '{column.defaultString}'")


proc createLongTextColumn(column: Column, table: Table): string =
  result = &"`{column.name}` TEXT"

  if not column.isNullable:
    result.add(" NOT NULL")

  if column.isDefault:
    result.add(&" DEFAULT '{column.defaultString}'")


# =============================================================================
# date
# =============================================================================
proc createDateColumn(column: Column, table: Table): string =
  result = &"`{column.name}` DATE"

  if not column.isNullable:
    result.add(" NOT NULL")

  if column.isDefault:
    result.add(&" DEFAULT '{column.defaultString}'")


proc createDatetimeColumn(column: Column, table: Table): string =
  result = &"`{column.name}` TIMESTAMP"

  if not column.isNullable:
    result.add(" NOT NULL")

  if column.isDefault:
    case column.defaultDatetime
    of Current:
      result.add(" DEFAULT CURRENT_TIMESTAMP")
    of CurrentOnUpdate:
      result.add(" DEFAULT CURRENT_TIMESTAMP")
    else:
      discard


proc createTimeColumn(column: Column, table: Table): string =
  result = &"`{column.name}` TIME"

  if not column.isNullable:
    result.add(" NOT NULL")

  if column.isDefault:
    result.add(&" DEFAULT '{column.defaultString}'")


proc createTimestampColumn(column: Column, table: Table): string =
  result = &"`{column.name}` TIMESTAMP"

  if not column.isNullable:
    result.add(" NOT NULL")

  if column.isDefault:
    case column.defaultDatetime
    of Current:
      result.add(" DEFAULT CURRENT_TIMESTAMP")
    of CurrentOnUpdate:
      result.add(" DEFAULT CURRENT_TIMESTAMP")
    else:
      discard


proc createTimestampsColumn(column: Column, table: Table): string =
  result = "`created_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP, "
  result.add("`updated_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP")


proc createSoftDeleteColumn(column: Column, table: Table): string =
  result = "`deleted_at` TIMESTAMP"


# =============================================================================
# others
# =============================================================================
proc createBlobColumn(column: Column, table: Table): string =
  result = &"`{column.name}` BYTEA"

  if column.isUnique:
    result.add(" UNIQUE")

  if not column.isNullable:
    result.add(" NOT NULL")


proc createBoolColumn(column: Column, table: Table): string =
  result = &"`{column.name}` BOOLEAN"

  if column.isUnique:
    result.add(" UNIQUE")

  if not column.isNullable:
    result.add(" NOT NULL")

  if column.isDefault:
    result.add(&" DEFAULT {column.defaultBool}")


proc createEnumColumn(column: Column, table: Table): string =
  result = &"`{column.name}` VARCHAR(255)"

  if not column.isNullable:
    result.add(" NOT NULL")


proc createJsonColumn(column: Column, table: Table): string =
  result = &"`{column.name}` JSON"

  if not column.isNullable:
    result.add(" NOT NULL")


# =============================================================================
# foreign
# =============================================================================
proc createForeignColumn(column: Column, table: Table): string =
  result = &"`{column.name}` INTEGER"

  if column.isUnique:
    result.add(" UNIQUE")

  if not column.isNullable:
    result.add(" NOT NULL")


proc createStrForeignColumn(column: Column, table: Table): string =
  result = &"`{column.name}` VARCHAR(255)"

  if column.isUnique:
    result.add(" UNIQUE")

  if not column.isNullable:
    result.add(" NOT NULL")


proc createForeignKey*(column: Column, table: Table): string =
  result = &"FOREIGN KEY (`{column.name}`) REFERENCES `{column.info["table"].getStr}`(`{column.info["column"].getStr}`)"

  case column.foreignOnDelete
  of RESTRICT:
    result.add(" ON DELETE RESTRICT")
  of CASCADE:
    result.add(" ON DELETE CASCADE")
  of SET_NULL:
    result.add(" ON DELETE SET NULL")
  of NO_ACTION:
    result.add(" ON DELETE NO ACTION")


# =============================================================================
# main
# =============================================================================
proc createColumnString*(table: Table, column: Column): string =
  case column.typ
  of rdbIncrements:
    return column.createSerialColumn(table)
  of rdbInteger:
    return column.createIntColumn(table)
  of rdbSmallInteger:
    return column.createSmallIntColumn(table)
  of rdbMediumInteger:
    return column.createMediumIntColumn(table)
  of rdbBigInteger:
    return column.createBigIntColumn(table)
  of rdbDecimal:
    return column.createDecimalColumn(table)
  of rdbDouble:
    return column.createDoubleColumn(table)
  of rdbFloat:
    return column.createFloatColumn(table)
  of rdbUuid:
    return column.createUuidColumn(table)
  of rdbChar:
    return column.createCharColumn(table)
  of rdbString:
    return column.createStringColumn(table)
  of rdbText:
    return column.createTextColumn(table)
  of rdbMediumText:
    return column.createMediumTextColumn(table)
  of rdbLongText:
    return column.createLongTextColumn(table)
  of rdbDate:
    return column.createDateColumn(table)
  of rdbDatetime:
    return column.createDatetimeColumn(table)
  of rdbTime:
    return column.createTimeColumn(table)
  of rdbTimestamp:
    return column.createTimestampColumn(table)
  of rdbTimestamps:
    return column.createTimestampsColumn(table)
  of rdbSoftDelete:
    return column.createSoftDeleteColumn(table)
  of rdbBinary:
    return column.createBlobColumn(table)
  of rdbBoolean:
    return column.createBoolColumn(table)
  of rdbEnumField:
    return column.createEnumColumn(table)
  of rdbJson:
    return column.createJsonColumn(table)
  of rdbForeign:
    return column.createForeignColumn(table)
  of rdbStrForeign:
    return column.createStrForeignColumn(table)


proc createForeignString*(table: Table, column: Column): string =
  return column.createForeignKey(table)


proc createIndexString*(table: Table, column: Column): string =
  result = &"CREATE INDEX `{table.name}_{column.name}_idx` ON `{table.name}` (`{column.name}`)"


proc createUpdatedAtString*(table: Table, column: Column): string =
  result = ""


proc createCommentColumn*(table: Table, column: Column): string =
  result = ""
