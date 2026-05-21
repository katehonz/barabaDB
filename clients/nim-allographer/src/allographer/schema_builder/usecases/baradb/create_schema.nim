import std/asyncdispatch
import std/strutils
import std/strformat
import std/json
import std/tables
import std/os
import ../../../utils/snake_to_camel
import ../../../query_builder/models/baradb/baradb_types
import ../../../query_builder/models/baradb/baradb_query
import ../../../query_builder/models/baradb/baradb_exec

proc getTableInfo(rdb: BaradbConnections): Future[Table[string, seq[tuple[name: string, typ: string]]]] {.async.} =
  var tablesInfo = initTable[string, seq[tuple[name: string, typ: string]]]()
  let tables = await rdb.raw("SELECT table_name FROM information_schema.tables WHERE table_schema = 'public'").get()
  for table in tables:
    let tableName = table["table_name"].getStr()
    let query = "SELECT column_name, data_type FROM information_schema.columns WHERE table_name = ? ORDER BY ordinal_position"
    let columns = await rdb.raw(query, %*[tableName]).get()
    var columnInfo: seq[tuple[name: string, typ: string]]
    for col in columns:
      columnInfo.add((name: col["column_name"].getStr(), typ: col["data_type"].getStr()))
    tablesInfo[tableName] = columnInfo
  return tablesInfo

proc generateSchemaCode(tablesInfo: Table[string, seq[tuple[name: string, typ: string]]]): string =
  var code = "import std/json"
  for tableName, columns in tablesInfo.pairs:
    if tableName == "_allographer_migrations":
      continue
    let tableNameCamel = tableName.snakeToCamel()
    code.add(&"\n\ntype {tableNameCamel}Table* = object\n")
    code.add(&"  ## {tableName}\n")
    for col in columns:
      let nimType =
        case col.typ.toLower()
        of "smallint", "integer", "bigint", "serial":
          "int"
        of "character", "character varying", "text", "date", "timestamp without time zone", "time without time zone", "bytea", "varchar":
          "string"
        of "boolean":
          "bool"
        of "numeric", "double precision", "real":
          "float"
        of "json", "jsonb":
          "JsonNode"
        else:
          "string"
      code.add(&"  {col.name}*: {nimType}\n")
  return code

proc createSchema*(rdb: BaradbConnections, schemaPath = "") {.async.} =
  try:
    let tablesInfo = await rdb.getTableInfo()
    let schemaCode = generateSchemaCode(tablesInfo)
    let schemaFilePath = if schemaPath == "": getCurrentDir() / "schema.nim" else: schemaPath
    writeFile(schemaFilePath, schemaCode)
    echo "schema generated successfully in ", schemaFilePath
  except Exception as e:
    echo "Error generating schema: ", e.msg
    raise
