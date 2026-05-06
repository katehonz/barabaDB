## BaraDB HTTP Server — REST API using Hunos
import hunos
import hunos/router
import hunos/middleware
import hunos/context
import json
import tables
import strutils
import os
import times
import config
import ../query/lexer
import ../query/parser
import ../query/executor
import ../storage/lsm
import ../core/mvcc
import ../protocol/ratelimit
import jwt as jwtlib

type
  HttpServer* = ref object
    config: BaraConfig
    running: bool
    db: LSMTree
    ctx: ExecutionContext
    metrics*: Metrics
    secretKey*: string

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
             secretKey: "baradb-default-secret-change-in-production!",
             metrics: Metrics())

# ----------------------------------------------------------------------
# JWT helpers
# ----------------------------------------------------------------------

proc createToken*(server: HttpServer, userId, role: string): string =
  let header = %*{"alg": "HS256", "typ": "JWT"}
  var claims = newTable[string, Claim]()
  claims["sub"] = newStringClaim(userId)
  claims["role"] = newStringClaim(role)
  claims["iat"] = newTimeClaim(getTime())
  claims["exp"] = newTimeClaim(getTime() + 24.hours)
  var token = initJWT(header, claims)
  token.sign(server.secretKey)
  return $token

proc verifyToken*(server: HttpServer, tokenStr: string): (bool, string, string) =
  try:
    let token = tokenStr.toJWT()
    if not token.verify(server.secretKey, HS256):
      return (false, "", "")
    let userId = token.claims["sub"].node.str
    let role = if "role" in token.claims: token.claims["role"].node.str else: "user"
    return (true, userId, role)
  except:
    return (false, "", "")

# ----------------------------------------------------------------------
# Handlers
# ----------------------------------------------------------------------

proc queryHandler(server: HttpServer): RequestHandler =
  return proc(request: Request) {.gcsafe.} =
    {.cast(gcsafe).}:
      let ctx = newContext(request)
      server.metrics.queriesTotal += 1

      # Auth check
      let authHeader = request.headers["Authorization"]
      if authHeader.len > 0 and authHeader.startsWith("Bearer "):
        let tokenStr = authHeader[7..^1]
        let (valid, userId, role) = server.verifyToken(tokenStr)
        if not valid:
          ctx.json(%*{"error": "Unauthorized"}, 401)
          return

      let body = parseJson(request.body)
      if body == nil or "query" notin body:
        ctx.json(%*{"error": "Missing 'query' in request body"}, 400)
        return

      let queryStr = body["query"].getStr()
      if queryStr.len == 0:
        ctx.json(%*{"error": "Empty query"}, 400)
        return

      var reqCtx = cloneForConnection(server.ctx)
      let tokens = tokenize(queryStr)
      let astNode = parse(tokens)

      if astNode.stmts.len == 0:
        ctx.json(%*{"rows": [], "affectedRows": 0, "columns": []})
        return

      let result = executor.executeQuery(reqCtx, astNode)

      if result.success:
        var jsonRows = newJArray()
        for row in result.rows:
          var jsonRow = newJObject()
          for col in result.columns:
            let key = col
            var val = ""
            if key in row: val = row[key]
            jsonRow[key] = %val
          jsonRows.add(jsonRow)
        var jsonCols = newJArray()
        for c in result.columns:
          jsonCols.add(%c)
        ctx.json(%*{
          "rows": jsonRows,
          "affectedRows": result.affectedRows,
          "columns": jsonCols,
          "message": if result.message.len > 0: %result.message else: newJNull()
        })
      else:
        server.metrics.queryErrors += 1
        ctx.json(%*{"error": result.message}, 400)

proc healthHandler(): RequestHandler =
  return proc(request: Request) {.gcsafe.} =
    let ctx = newContext(request)
    ctx.json(%*{"status": "ok", "version": "0.1.0"})

proc metricsHandler(server: HttpServer): RequestHandler =
  return proc(request: Request) {.gcsafe.} =
    let prometheus = "baradb_queries_total " & $server.metrics.queriesTotal & "\n" &
                     "baradb_query_errors_total " & $server.metrics.queryErrors & "\n" &
                     "baradb_inserts_total " & $server.metrics.insertCount & "\n" &
                     "baradb_selects_total " & $server.metrics.selectCount & "\n" &
                     "baradb_connections_active " & $server.metrics.activeConnections & "\n"
    request.respond(200, @[("Content-Type", "text/plain")], prometheus)

proc authHandler(server: HttpServer): RequestHandler =
  return proc(request: Request) {.gcsafe.} =
    {.cast(gcsafe).}:
      let ctx = newContext(request)
      let body = parseJson(request.body)
      if body == nil or "username" notin body or "password" notin body:
        ctx.json(%*{"error": "Missing username or password"}, 400)
        return

      let username = body["username"].getStr()
      let token = server.createToken(username, "user")
      ctx.json(%*{
        "token": token,
        "user": username,
        "role": "user"
      })

proc openApiHandler(): RequestHandler =
  return proc(request: Request) {.gcsafe.} =
    let ctx = newContext(request)
    ctx.json(%*{
      "openapi": "3.0.0",
      "info": {"title": "BaraDB API", "version": "0.1.0"},
      "paths": {
        "/query": {
          "post": {
            "summary": "Execute SQL query",
            "requestBody": {
              "content": {
                "application/json": {
                  "schema": {
                    "type": "object",
                    "properties": {"query": {"type": "string"}},
                    "required": ["query"]
                  }
                }
              }
            }
          }
        },
        "/health": {"get": {"summary": "Health check"}},
        "/metrics": {"get": {"summary": "Prometheus metrics"}},
        "/auth": {"post": {"summary": "Authenticate and get JWT token"}}
      }
    })

# ----------------------------------------------------------------------
# Server lifecycle
# ----------------------------------------------------------------------

proc run*(server: HttpServer, port: int = 8080) =
  var router = newRouter()
  router.post("/query", server.queryHandler())
  router.get("/health", healthHandler())
  router.get("/metrics", server.metricsHandler())
  router.post("/auth", server.authHandler())
  router.get("/api", openApiHandler())

  var stack = newMiddlewareStack(router)
  stack.use(corsMiddleware())

  let hunosServer = newServer(stack)
  echo "BaraDB HTTP listening on port ", port
  server.running = true
  hunosServer.serve(Port(port))

proc stop*(server: HttpServer) =
  server.running = false
  server.db.close()
