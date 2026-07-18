## Value / row serialization helpers used across the executor
import std/strutils
import std/tables
import std/json
import ../../core/types
import types

proc isNull*(value: string): bool =
  value == "\\N" or value.toLower() == "null"

proc valueToString*(v: Value): string =
  case v.kind
  of vkNull: return "\\N"
  of vkString: return v.strVal
  of vkInt64: return $v.int64Val
  of vkFloat64: return $v.float64Val
  of vkBool: return $v.boolVal
  else: return ""

proc `%`*(v: Value): JsonNode =
  case v.kind
  of vkNull: return newJNull()
  of vkString: return %v.strVal
  of vkInt64: return %v.int64Val
  of vkFloat64: return %v.float64Val
  of vkBool: return %v.boolVal
  else: return newJNull()

proc toString*(v: Value): string = valueToString(v)

proc `[]=`*(t: var Row, key: string, val: string) =
  t[key] = Value(kind: vkString, strVal: val)

proc escapeRowVal*(v: string): string =
  v.replace("\\", "\\\\").replace(",", "\\,").replace("=", "\\=")

proc unescapeRowVal*(v: string): string =
  result = ""
  var i = 0
  while i < v.len:
    if v[i] == '\\' and i + 1 < v.len:
      case v[i+1]
      of '\\', ',', '=':
        result &= v[i+1]
        i += 2
        continue
      else: discard
    result &= v[i]
    inc i

proc parseRowData*(valStr: string): Table[string, string] =
  ## Parse "col1=val1,col2=val2" into a table
  result = initTable[string, string]()
  var i = 0
  var part = ""
  while i < valStr.len:
    if valStr[i] == '\\' and i + 1 < valStr.len:
      part &= valStr[i]
      part &= valStr[i+1]
      i += 2
      continue
    if valStr[i] == ',':
      let eqPos = part.find('=')
      if eqPos >= 0:
        let k = part[0..<eqPos].strip()
        let v = unescapeRowVal(part[eqPos+1..^1].strip())
        result[k] = v
      part = ""
    else:
      part &= valStr[i]
    inc i
  if part.len > 0:
    let eqPos = part.find('=')
    if eqPos >= 0:
      let k = part[0..<eqPos].strip()
      let v = unescapeRowVal(part[eqPos+1..^1].strip())
      result[k] = v

proc parseRowDataToValueRow*(valStr: string): Row =
  result = initTable[string, Value]()
  for k, v in parseRowData(valStr):
    result[k] = v

proc sqlEscapeIdent*(ident: string): string =
  ## Escape SQL identifiers by doubling double-quotes.
  result = ident.replace("\"", "\"\"")

proc sqlEscapeString*(s: string): string =
  ## Escape SQL string literals by doubling single-quotes.
  result = s.replace("'", "''")

proc buildInsertSql*(table: string, columns: seq[string], rows: seq[seq[string]]): string =
  ## Build a multi-row INSERT statement for bulk import.
  result = "INSERT INTO \"" & sqlEscapeIdent(table) & "\" ("
  for i, col in columns:
    if i > 0: result &= ", "
    result &= "\"" & sqlEscapeIdent(col) & "\""
  result &= ") VALUES "
  for ri, row in rows:
    if ri > 0: result &= ", "
    result &= "("
    for ci, val in row:
      if ci > 0: result &= ", "
      if val.len == 0 or val == "\\N":
        result &= "NULL"
      else:
        result &= "'" & sqlEscapeString(val) & "'"
    result &= ")"

proc getValue*(values: seq[string], fields: seq[string], colName: string): string =
  for i, f in fields:
    if f.toLower() == colName.toLower():
      if i < values.len: return values[i]
      return "\\N"
  return "\\N"

proc getTableDef*(ctx: ExecutionContext, tableName: string): TableDef =
  if tableName in ctx.tables: return ctx.tables[tableName]
  return TableDef(name: tableName, columns: @[], pkColumns: @[], foreignKeys: @[], checks: @[])
