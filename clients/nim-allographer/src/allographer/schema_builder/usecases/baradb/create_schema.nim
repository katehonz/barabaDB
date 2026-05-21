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
  ## Introspect BaraDB tables using native SHOW TABLES / SHOW COLUMNS commands.
  var tablesInfo = initTable[string, seq[tuple[name: string, typ: string]]]()

  # SHOW TABLES — get all table names from the server
  let tables = await rdb.raw("SHOW TABLES").get()
  for table in tables:
    let tableName = table["name"].getStr()
    # Skip internal schema tables
    if tableName.startsWith("_") and tableName != "_allographer_migrations":
      continue

    # SHOW COLUMNS FROM — get column definitions for this table
    let descQuery = "SHOW COLUMNS FROM `" & tableName & "`"
    let columns = await rdb.raw(descQuery).get()
    var columnInfo: seq[tuple[name: string, typ: string]]
    for col in columns:
      let colName = col["column_name"].getStr()
      let colType = col["data_type"].getStr()
      columnInfo.add((name: colName, typ: colType))
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
        of "smallint", "integer", "bigint", "serial", "int", "int8", "int16", "int32", "int64":
          "int"
        of "character", "character varying", "text", "date",
           "timestamp without time zone", "time without time zone", "bytea",
           "varchar", "string", "fkstring":
          "string"
        of "boolean", "bool":
          "bool"
        of "numeric", "double precision", "real", "float", "float32", "float64",
           "double":
          "float"
        of "json", "jsonb", "jsonnode":
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
