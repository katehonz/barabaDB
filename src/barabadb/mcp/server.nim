## BaraDB MCP Server — Model Context Protocol
##
## Implements the MCP (Model Context Protocol) over STDIO transport
## with JSON-RPC 2.0. Provides AI agents with tools to query, vector
## search, and inspect the BaraDB schema.
##
## Tools:
##   query          — Execute SQL queries with parameterized inputs
##   vector_search  — Semantic vector similarity search with tenant isolation
##   schema_inspect — Explore tables, columns, indexes, RLS policies

import std/json
import std/strutils
import std/os
import std/tables
import std/sequtils

import ../storage/lsm
import ../query/lexer as qlexer
import ../query/parser as qparser
import ../query/ast
import ../query/executor
import ../protocol/wire
import ../core/mvcc
import ../fts/engine as fts
import ../vector/engine as vengine

# ---------------------------------------------------------------------------
# MCP JSON-RPC 2.0 types
# ---------------------------------------------------------------------------

type
  JsonRpcErrorCode* = enum
    jrParseError = -32700
    jrInvalidRequest = -32600
    jrMethodNotFound = -32601
    jrInvalidParams = -32602
    jrInternalError = -32603

  McpToolDef* = object
    name*: string
    description*: string
    inputSchema*: JsonNode

  McpServerInfo* = object
    name*: string
    version*: string

  McpServerCapabilities* = object
    tools*: JsonNode

# Tool definitions (lazy initialization)
var toolDefs: seq[McpToolDef]

proc buildToolDefs() =
  if toolDefs.len > 0:
    return

  toolDefs = @[
    McpToolDef(
      name: "query",
      description: "Execute a SQL query against BaraDB. Supports SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, and all BaraQL statements. Use parameterized queries with ? placeholders to prevent SQL injection. Returns rows as an array of objects keyed by column name.",
      inputSchema: %*{
        "type": "object",
        "properties": {
          "sql": {
            "type": "string",
            "description": "The SQL query to execute. Use ? for parameterized values."
          },
          "params": {
            "type": "array",
            "description": "Optional parameter values for ? placeholders in the SQL query.",
            "items": {}
          },
          "tenant_id": {
            "type": "string",
            "description": "Optional. Sets the app.tenant_id session variable for multi-tenant RLS filtering."
          },
          "user_id": {
            "type": "string",
            "description": "Optional. Sets the current user for RLS policy evaluation."
          }
        },
        "required": ["sql"]
      }
    ),
    McpToolDef(
      name: "vector_search",
      description: "Perform semantic vector similarity search against a BaraDB HNSW vector index. Finds the k-nearest neighbors to a query vector. Supports tenant isolation via session variables. Results include distance scores and metadata.",
      inputSchema: %*{
        "type": "object",
        "properties": {
          "table": {
            "type": "string",
            "description": "The table name containing the vector column."
          },
          "column": {
            "type": "string",
            "description": "The vector column name with an HNSW index."
          },
          "query_vector": {
            "type": "array",
            "description": "The query vector as an array of floats.",
            "items": {"type": "number"}
          },
          "k": {
            "type": "integer",
            "description": "Number of nearest neighbors to return (default: 10).",
            "default": 10
          },
          "metric": {
            "type": "string",
            "enum": ["cosine", "euclidean", "dot_product", "manhattan"],
            "description": "Distance metric (default: cosine).",
            "default": "cosine"
          },
          "filter_column": {
            "type": "string",
            "description": "Optional metadata column to filter results."
          },
          "filter_value": {
            "type": "string",
            "description": "Value for filter_column. Only results matching this value are returned."
          },
          "tenant_id": {
            "type": "string",
            "description": "Optional. Sets the app.tenant_id session variable for multi-tenant RLS filtering."
          }
        },
        "required": ["table", "column", "query_vector"]
      }
    ),
    McpToolDef(
      name: "schema_inspect",
      description: "Explore and inspect the BaraDB database schema. Returns tables, columns, data types, primary keys, foreign keys, indexes (BTree, HNSW vector, full-text), and RLS policies. Optionally filter to a specific table.",
      inputSchema: %*{
        "type": "object",
        "properties": {
          "table": {
            "type": "string",
            "description": "Optional. If provided, returns detailed schema for only this table."
          },
          "tenant_id": {
            "type": "string",
            "description": "Optional. Sets the app.tenant_id session variable for multi-tenant RLS context."
          }
        },
        "required": []
      }
    ),
  ]

# ---------------------------------------------------------------------------
# Server state
# ---------------------------------------------------------------------------

type
  McpServerCtx* = ref object
    db*: LSMTree
    execCtx*: ExecutionContext
    dataDir*: string

var serverCtx: McpServerCtx

# ---------------------------------------------------------------------------
# JSON-RPC helpers
# ---------------------------------------------------------------------------


proc parseVectorFromJson(node: JsonNode): seq[float32] =
  result = @[]
  if node.kind == JArray:
    for item in node:
      case item.kind
      of JInt: result.add(float32(item.getInt()))
      of JFloat: result.add(float32(item.getFloat()))
      else: discard

proc parseMetric(s: string): vengine.DistanceMetric =
  case s.toLowerAscii()
  of "cosine": vengine.dmCosine
  of "euclidean": vengine.dmEuclidean
  of "dot_product", "dotproduct": vengine.dmDotProduct
  of "manhattan": vengine.dmManhattan
  else: vengine.dmCosine

# ---------------------------------------------------------------------------
# Tool: query
# ---------------------------------------------------------------------------

proc handleQuery(params: JsonNode): JsonNode =
  if params.kind != JObject:
    return %*{"error": "params must be a JSON object"}

  if "sql" notin params or params["sql"].kind != JString:
    return %*{"error": "Missing required parameter: sql (string)"}

  let sql = params["sql"].getStr()
  if sql.strip().len == 0:
    return %*{"error": "SQL query cannot be empty"}

  var prevTenant = serverCtx.execCtx.sessionVars.getOrDefault("app.tenant_id", "")
  var prevUser = serverCtx.execCtx.currentUser

  if "tenant_id" in params and params["tenant_id"].kind == JString:
    let tid = params["tenant_id"].getStr()
    if tid.len > 0:
      serverCtx.execCtx.sessionVars["app.tenant_id"] = tid
  if "user_id" in params and params["user_id"].kind == JString:
    let uid = params["user_id"].getStr()
    if uid.len > 0:
      serverCtx.execCtx.currentUser = uid

  var wireParams: seq[WireValue] = @[]
  if "params" in params and params["params"].kind == JArray:
    for p in params["params"]:
      case p.kind
      of JNull: wireParams.add(WireValue(kind: fkNull))
      of JBool: wireParams.add(WireValue(kind: fkBool, boolVal: p.getBool()))
      of JInt: wireParams.add(WireValue(kind: fkInt64, int64Val: p.getInt()))
      of JFloat: wireParams.add(WireValue(kind: fkFloat64, float64Val: p.getFloat()))
      of JString: wireParams.add(WireValue(kind: fkString, strVal: p.getStr()))
      else: wireParams.add(WireValue(kind: fkString, strVal: $p))

  var tokens: seq[qlexer.Token]
  try:
    tokens = qlexer.tokenize(sql)
  except CatchableError:
    serverCtx.execCtx.sessionVars["app.tenant_id"] = prevTenant
    serverCtx.execCtx.currentUser = prevUser
    return %*{"error": "Failed to tokenize SQL: " & getCurrentExceptionMsg()}

  var astNode: Node
  try:
    astNode = qparser.parse(tokens)
  except CatchableError:
    serverCtx.execCtx.sessionVars["app.tenant_id"] = prevTenant
    serverCtx.execCtx.currentUser = prevUser
    return %*{"error": "Failed to parse SQL: " & getCurrentExceptionMsg()}

  if astNode.stmts.len == 0:
    serverCtx.execCtx.sessionVars["app.tenant_id"] = prevTenant
    serverCtx.execCtx.currentUser = prevUser
    return %*{"columns": [], "rows": [], "affectedRows": 0}

  var res: ExecResult
  try:
    res = executeQuery(serverCtx.execCtx, astNode, wireParams)
  except CatchableError:
    serverCtx.execCtx.sessionVars["app.tenant_id"] = prevTenant
    serverCtx.execCtx.currentUser = prevUser
    return %*{"error": "Query execution failed: " & getCurrentExceptionMsg()}

  if not res.success:
    serverCtx.execCtx.sessionVars["app.tenant_id"] = prevTenant
    serverCtx.execCtx.currentUser = prevUser
    return %*{"error": res.message}

  var jsonRows = newJArray()
  for row in res.rows:
    var jsonRow = newJObject()
    for col in res.columns:
      if col in row:
        jsonRow[col] = %row[col]
      else:
        jsonRow[col] = newJNull()
    jsonRows.add(jsonRow)

  var jsonCols = newJArray()
  for c in res.columns:
    jsonCols.add(%c)

  var r = %*{
    "columns": jsonCols,
    "rows": jsonRows,
    "affectedRows": res.affectedRows
  }
  if res.message.len > 0:
    r["message"] = %res.message

  var sessionInfo = newJObject()
  sessionInfo["tenant_id"] = %serverCtx.execCtx.sessionVars.getOrDefault("app.tenant_id", "")
  sessionInfo["user_id"] = %serverCtx.execCtx.currentUser
  r["_session"] = sessionInfo

  serverCtx.execCtx.sessionVars["app.tenant_id"] = prevTenant
  serverCtx.execCtx.currentUser = prevUser

  return r

# ---------------------------------------------------------------------------
# Tool: vector_search
# ---------------------------------------------------------------------------

proc handleVectorSearch(params: JsonNode): JsonNode =
  if params.kind != JObject:
    return %*{"error": "params must be a JSON object"}

  if "table" notin params or params["table"].kind != JString:
    return %*{"error": "Missing required parameter: table (string)"}
  if "column" notin params or params["column"].kind != JString:
    return %*{"error": "Missing required parameter: column (string)"}
  if "query_vector" notin params:
    return %*{"error": "Missing required parameter: query_vector (array of floats)"}

  let table = params["table"].getStr()
  let column = params["column"].getStr()
  let indexKey = table & "." & column

  if indexKey notin serverCtx.execCtx.vectorIndexes:
    var available: seq[string] = @[]
    for k in serverCtx.execCtx.vectorIndexes.keys:
      available.add(k)
    return %*{
      "error": "No vector index found for '" & indexKey & "'",
      "available_indexes": %available
    }

  let idx = serverCtx.execCtx.vectorIndexes[indexKey]
  if idx.isNil or idx.nodes.len == 0:
    return %*{"error": "Vector index for '" & indexKey & "' is empty"}

  let queryVec = parseVectorFromJson(params["query_vector"])
  if queryVec.len == 0:
    return %*{"error": "query_vector must be a non-empty array of numbers"}
  if queryVec.len != idx.dimensions:
    return %*{"error": "Vector dimension mismatch: got " & $queryVec.len &
      ", expected " & $idx.dimensions}

  let k = if "k" in params and params["k"].kind == JInt:
    params["k"].getInt()
  else: 10
  if k < 1 or k > 1000:
    return %*{"error": "k must be between 1 and 1000"}

  let metric = if "metric" in params and params["metric"].kind == JString:
    parseMetric(params["metric"].getStr())
  else: vengine.dmCosine

  var results: seq[(uint64, float64, Table[string, string])]

  let hasFilter = "filter_column" in params and params["filter_column"].kind == JString and
                   "filter_value" in params and params["filter_value"].kind == JString

  if hasFilter:
    let filterCol = params["filter_column"].getStr()
    let filterVal = params["filter_value"].getStr()
    let filterFn = proc(metadata: Table[string, string]): bool {.gcsafe.} =
      result = filterCol in metadata and metadata[filterCol] == filterVal
    let rawResults = idx.searchWithFilter(queryVec, k, filterFn, metric)
    for (id, dist) in rawResults:
      var meta = initTable[string, string]()
      if id in idx.nodes:
        meta = idx.nodes[id].metadata
      results.add((id, dist, meta))
  else:
    results = idx.searchEx(queryVec, k, metric)

  var jsonResults = newJArray()
  for (id, dist, meta) in results:
    var item = %*{
      "id": %id,
      "distance": dist
    }
    var metaObj = newJObject()
    for key, val in meta:
      metaObj[key] = %val
    item["metadata"] = metaObj
    jsonResults.add(item)

  var prevTenant = serverCtx.execCtx.sessionVars.getOrDefault("app.tenant_id", "")
  var sessionInfo = newJObject()
  if "tenant_id" in params and params["tenant_id"].kind == JString:
    let tid = params["tenant_id"].getStr()
    serverCtx.execCtx.sessionVars["app.tenant_id"] = tid
    sessionInfo["tenant_id"] = %tid
  sessionInfo["user_id"] = %serverCtx.execCtx.currentUser

  var r = %*{
    "table": %table,
    "column": %column,
    "index_size": idx.nodes.len,
    "k": k,
    "metric": $metric,
    "results": jsonResults,
    "_session": sessionInfo
  }
  serverCtx.execCtx.sessionVars["app.tenant_id"] = prevTenant
  return r

# ---------------------------------------------------------------------------
# Tool: schema_inspect
# ---------------------------------------------------------------------------

proc handleSchemaInspect(params: JsonNode): JsonNode =
  var targetTable = ""
  if params.kind == JObject and "table" in params and params["table"].kind == JString:
    targetTable = params["table"].getStr()

  var prevTenant = serverCtx.execCtx.sessionVars.getOrDefault("app.tenant_id", "")
  if "tenant_id" in params and params["tenant_id"].kind == JString:
    serverCtx.execCtx.sessionVars["app.tenant_id"] = params["tenant_id"].getStr()

  var jsonTables = newJArray()

  for tblName, tblDef in serverCtx.execCtx.tables:
    if targetTable.len > 0 and tblName != targetTable:
      continue

    var jsonCols = newJArray()
    for col in tblDef.columns:
      var colObj = %*{
        "name": col.name,
        "type": col.colType,
        "primary_key": col.isPk,
        "not_null": col.isNotNull,
        "unique": col.isUnique,
        "auto_increment": col.autoIncrement
      }
      if col.defaultVal.len > 0:
        colObj["default"] = %col.defaultVal

      var fkInfo: JsonNode = nil
      if col.fkTable.len > 0:
        fkInfo = %*{
          "table": col.fkTable,
          "column": col.fkColumn,
          "on_delete": col.fkOnDelete,
          "on_update": col.fkOnUpdate
        }
        colObj["foreign_key"] = fkInfo

      jsonCols.add(colObj)

    var jsonIdxs = newJArray()
    for key in serverCtx.execCtx.btrees.keys:
      if key.startsWith(tblName & ".") or key == tblName:
        jsonIdxs.add(%*{"type": "btree", "name": key})
    for key in serverCtx.execCtx.vectorIndexes.keys:
      if key.startsWith(tblName & "."):
        let vi = serverCtx.execCtx.vectorIndexes[key]
        jsonIdxs.add(%*{
          "type": "hnsw_vector",
          "name": key,
          "dimensions": vi.dimensions,
          "node_count": vi.nodes.len
        })
    for key in serverCtx.execCtx.ftsIndexes.keys:
      if key.startsWith(tblName & "."):
        let ftsIdx = serverCtx.execCtx.ftsIndexes[key]
        jsonIdxs.add(%*{"type": "fulltext", "name": key, "doc_count": ftsIdx.docCount})

    var jsonPolicies = newJArray()
    if tblName in serverCtx.execCtx.policies:
      for pol in serverCtx.execCtx.policies[tblName]:
        jsonPolicies.add(%*{
          "name": pol.name,
          "command": pol.command
        })

    var fks = newJArray()
    for fk in tblDef.foreignKeys:
      fks.add(%*{
        "table": fk.refTable,
        "column": fk.refColumn,
        "on_delete": fk.onDelete,
        "on_update": fk.onUpdate
      })

    var tblObj = %*{
      "name": tblName,
      "columns": jsonCols,
      "primary_keys": %tblDef.pkColumns,
      "indexes": jsonIdxs,
      "foreign_keys": fks,
      "policies": jsonPolicies
    }
    jsonTables.add(tblObj)

  if targetTable.len > 0 and jsonTables.len == 0:
    serverCtx.execCtx.sessionVars["app.tenant_id"] = prevTenant
    return %*{"error": "Table '" & targetTable & "' not found"}

  var sessionInfo = newJObject()
  sessionInfo["tenant_id"] = %serverCtx.execCtx.sessionVars.getOrDefault("app.tenant_id", "")
  sessionInfo["user_id"] = %serverCtx.execCtx.currentUser

  var r = %*{
    "tables": jsonTables,
    "table_count": jsonTables.len,
    "_session": sessionInfo
  }
  serverCtx.execCtx.sessionVars["app.tenant_id"] = prevTenant
  return r

# ---------------------------------------------------------------------------
# MCP Protocol handlers
# ---------------------------------------------------------------------------

proc handleInitialize(params: JsonNode): JsonNode =
  buildToolDefs()
  return %*{
    "protocolVersion": "2024-11-05",
    "serverInfo": {
      "name": "BaraDB MCP Server",
      "version": "1.1.4"
    },
    "capabilities": {
      "tools": {}
    }
  }

proc handleToolsList(params: JsonNode): JsonNode =
  buildToolDefs()
  var tools = newJArray()
  for td in toolDefs:
    tools.add(%*{
      "name": td.name,
      "description": td.description,
      "inputSchema": td.inputSchema
    })
  return %*{"tools": tools}

proc handleToolsCall(params: JsonNode): JsonNode =
  if params.kind != JObject:
    return %*{"error": "params must be a JSON object"}

  if "name" notin params or params["name"].kind != JString:
    return %*{"error": "Missing tool name"}

  let toolName = params["name"].getStr()
  let toolArgs = if "arguments" in params: params["arguments"] else: newJObject()

  var content: JsonNode
  case toolName
  of "query":
    content = handleQuery(toolArgs)
  of "vector_search":
    content = handleVectorSearch(toolArgs)
  of "schema_inspect":
    content = handleSchemaInspect(toolArgs)
  else:
    return %*{"error": "Unknown tool: " & toolName}

  var text: string
  if content.hasKey("error"):
    text = "Error: " & content["error"].getStr()
  else:
    text = $content

  return %*{
    "content": [
      {
        "type": "text",
        "text": text
      }
    ]
  }

# ---------------------------------------------------------------------------
# JSON-RPC dispatch
# ---------------------------------------------------------------------------

proc dispatch(meth: string, params: JsonNode): JsonNode =
  case meth
  of "initialize":
    return handleInitialize(params)
  of "tools/list":
    return handleToolsList(params)
  of "tools/call":
    return handleToolsCall(params)
  else:
    return %*{
      "error": {
        "code": jrMethodNotFound.int,
        "message": "Method not found: " & meth
      }
    }

# ---------------------------------------------------------------------------
# STDIO transport
# ---------------------------------------------------------------------------

proc writeToStdout(line: string) =
  try:
    stdout.writeLine(line)
    stdout.flushFile()
  except CatchableError:
    discard

proc logToStderr*(msg: string) =
  try:
    stderr.writeLine("[baradb-mcp] " & msg)
    stderr.flushFile()
  except CatchableError:
    discard

proc processMessage(raw: string): string =
  if raw.strip().len == 0:
    return ""

  var req: JsonNode
  try:
    req = parseJson(raw)
  except CatchableError:
    logToStderr("JSON parse error: " & getCurrentExceptionMsg())
    let resp = %*{
      "jsonrpc": "2.0",
      "id": newJNull(),
      "error": {
        "code": jrParseError.int,
        "message": "Parse error: " & getCurrentExceptionMsg()
      }
    }
    return $resp

  if req.kind != JObject:
    let resp = %*{
      "jsonrpc": "2.0",
      "id": newJNull(),
      "error": {
        "code": jrInvalidRequest.int,
        "message": "Invalid request: not a JSON object"
      }
    }
    return $resp

  if "method" notin req or req["method"].kind != JString:
    let resp = %*{
      "jsonrpc": "2.0",
      "id": newJNull(),
      "error": {
        "code": jrInvalidRequest.int,
        "message": "Invalid request: missing method"
      }
    }
    return $resp

  let meth = req["method"].getStr()
  let params = if "params" in req: req["params"] else: newJObject()

  let isNotification = "id" notin req

  if meth == "notifications/initialized":
    return ""

  var dispResult: JsonNode
  try:
    dispResult = dispatch(meth, params)
  except CatchableError:
    logToStderr("Dispatch error for " & meth & ": " & getCurrentExceptionMsg())
    let msg = getCurrentExceptionMsg()
    var errResp = %*{
      "jsonrpc": "2.0",
      "error": {
        "code": jrInternalError.int,
        "message": "Internal error: " & msg
      }
    }
    if not isNotification:
      errResp["id"] = req["id"]
    return $errResp

  if isNotification:
    return ""

  var resp: JsonNode
  if dispResult.hasKey("error"):
    var errNode = dispResult["error"]
    var errObj: JsonNode
    if errNode.kind == JObject:
      errObj = errNode
    else:
      errObj = %*{"code": jrInternalError.int, "message": errNode.getStr()}
    resp = %*{
      "jsonrpc": "2.0",
      "id": req["id"],
      "error": errObj
    }
  else:
    resp = %*{
      "jsonrpc": "2.0",
      "id": req["id"],
      "result": dispResult
    }
  return $resp

# ---------------------------------------------------------------------------
# Server lifecycle
# ---------------------------------------------------------------------------

proc init*(dataDir: string = "./data"): McpServerCtx =
  logToStderr("BaraDB MCP Server v1.1.4 initializing...")
  let db = newLSMTree(dataDir)
  let ctx = newExecutionContext(db)
  ctx.txnManager = newTxnManager()
  result = McpServerCtx(db: db, execCtx: ctx, dataDir: dataDir)
  serverCtx = result
  logToStderr("Initialized. Data directory: " & dataDir)

proc run*() =
  buildToolDefs()
  logToStderr("MCP Server ready. Waiting for JSON-RPC requests on STDIN...")
  logToStderr("Available tools: " & $toolDefs.mapIt(it.name))

  var startupDone = false
  while true:
    var line = ""
    try:
      line = stdin.readLine()
    except EOFError:
      if startupDone:
        logToStderr("STDIN closed, exiting.")
      break
    except CatchableError:
      logToStderr("STDIN read error: " & getCurrentExceptionMsg())
      break

    let resp = processMessage(line)
    if resp.len > 0:
      writeToStdout(resp)
    if not startupDone:
      startupDone = true

proc close*() =
  if serverCtx != nil and serverCtx.db != nil:
    logToStderr("Closing database...")
    serverCtx.db.close()

# ---------------------------------------------------------------------------
# Standalone entry helpers
# ---------------------------------------------------------------------------

proc parseDataDir*(): string =
  result = getEnv("BARADB_DATA_DIR", "./data")
  var i = 1
  while i < paramCount():
    let arg = paramStr(i)
    if arg == "--data-dir" and i + 1 <= paramCount():
      result = paramStr(i + 1)
      break
    inc i

when isMainModule:
  let dataDir = parseDataDir()
  logToStderr("Starting BaraDB MCP Server with data dir: " & dataDir)
  try:
    discard init(dataDir)
    run()
  except CatchableError:
    logToStderr("Fatal error: " & getCurrentExceptionMsg())
  finally:
    close()
