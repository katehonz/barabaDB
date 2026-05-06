## BaraDB HTTP Server — REST API with JSON responses
import std/asynchttpserver
import std/asyncdispatch
import std/strutils
import std/json
import std/os
import config
import ../query/lexer
import ../query/parser
import ../query/executor
import ../storage/lsm
import ../core/mvcc
import ../protocol/auth

type
  HttpServer* = ref object
    config: BaraConfig
    running: bool
    db: LSMTree
    ctx: ExecutionContext
    authManager: AuthManager
    metrics*: Metrics

  Metrics* = ref object
    queriesTotal*: int
    queryErrors*: int
    insertCount*: int
    selectCount*: int
    activeConnections*: int

proc newHttpServer*(config: BaraConfig): HttpServer =
  let dataDir = config.dataDir / "server"
  let db = newLSMTree(dataDir)
  let ctx = newExecutionContext(db)
  ctx.txnManager = newTxnManager()
  HttpServer(config: config, running: false, db: db, ctx: ctx,
             authManager: newAuthManager(),
             metrics: Metrics(queriesTotal: 0, queryErrors: 0,
                              insertCount: 0, selectCount: 0, activeConnections: 0))

proc newMetrics*(): Metrics =
  Metrics()

# ----------------------------------------------------------------------
# Authentication middleware
# ----------------------------------------------------------------------

proc extractToken(headers: HttpHeaders): string =
  let authHeader = headers.getOrDefault("Authorization")
  if authHeader.startsWith("Bearer "):
    return authHeader[7..^1]
  return ""

proc authorize(server: HttpServer, headers: HttpHeaders): (bool, JWTClaims) =
  let token = extractToken(headers)
  if token.len == 0:
    return (true, JWTClaims(role: "anonymous"))
  let (ok, claims) = server.authManager.verifyToken(token)
  return (ok, claims)

# ----------------------------------------------------------------------
# JSON helpers
# ----------------------------------------------------------------------

proc jsonError(code: int, message: string): JsonNode =
  %* {"error": {"code": code, "message": message}}

# ----------------------------------------------------------------------
# Request handler
# ----------------------------------------------------------------------

proc handleRequest(server: HttpServer, req: Request) {.async, gcsafe.} =
  {.cast(gcsafe).}:
    inc server.metrics.queriesTotal
    inc server.metrics.activeConnections

    case req.url.path
    of "/query":
      if req.reqMethod != HttpPost:
        await req.respond(Http405, $jsonError(405, "Method not allowed. Use POST."),
                          newHttpHeaders([("Content-Type", "application/json")]))
        return

      let (authed, claims) = server.authorize(req.headers)
      if not authed:
        await req.respond(Http401, $jsonError(401, "Unauthorized"),
                          newHttpHeaders([("Content-Type", "application/json")]))
        return

      let queryStr = req.body
      if queryStr.len == 0:
        await req.respond(Http400, $jsonError(400, "Missing query in request body"),
                          newHttpHeaders([("Content-Type", "application/json")]))
        return

      var reqCtx = cloneForConnection(server.ctx)

      let tokens = tokenize(queryStr)
      let astNode = parse(tokens)

      if astNode.stmts.len == 0:
        await req.respond(Http200, $ %* {"rows": [], "affectedRows": 0, "columns": []},
                          newHttpHeaders([("Content-Type", "application/json")]))
        return

      let result = executor.executeQuery(reqCtx, astNode)

      if result.success:
        inc server.metrics.selectCount
        var jsonRows = newJArray()
        for row in result.rows:
          var jsonRow = newJObject()
          for col, val in row:
            jsonRow[col] = %val
          jsonRows.add(jsonRow)
        var jsonCols = newJArray()
        for c in result.columns:
          jsonCols.add(%c)
        var msg: JsonNode = nil
        if result.message.len > 0:
          msg = %result.message
        await req.respond(Http200, $ %* {
          "rows": jsonRows,
          "affectedRows": result.affectedRows,
          "columns": jsonCols,
          "message": if result.message.len > 0: %result.message else: newJNull()
        }, newHttpHeaders([("Content-Type", "application/json")]))
      else:
        inc server.metrics.queryErrors
        await req.respond(Http400, $jsonError(400, result.message),
                          newHttpHeaders([("Content-Type", "application/json")]))

    of "/health":
      await req.respond(Http200, $ %* {"status": "ok", "version": "0.1.0"},
                        newHttpHeaders([("Content-Type", "application/json")]))

    of "/metrics":
      let prometheus = "baradb_queries_total " & $server.metrics.queriesTotal & "\n" &
                       "baradb_query_errors_total " & $server.metrics.queryErrors & "\n" &
                       "baradb_inserts_total " & $server.metrics.insertCount & "\n" &
                       "baradb_selects_total " & $server.metrics.selectCount & "\n" &
                       "baradb_connections_active " & $server.metrics.activeConnections & "\n"
      await req.respond(Http200, prometheus, newHttpHeaders([("Content-Type", "text/plain")]))

    else:
      await req.respond(Http404, $jsonError(404, "Not found: " & req.url.path),
                        newHttpHeaders([("Content-Type", "application/json")]))

  dec server.metrics.activeConnections

proc run*(server: HttpServer, port: int = 8080) {.async.} =
  server.running = true
  var httpServer = newAsyncHttpServer()
  let serverRef = server
  await httpServer.serve(Port(port), proc (req: Request): Future[void] {.gcsafe.} =
    serverRef.handleRequest(req))

proc stop*(server: HttpServer) =
  server.running = false
  server.db.close()
