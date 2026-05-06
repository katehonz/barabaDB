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

proc adminHandler(server: HttpServer): RequestHandler =
  return proc(request: Request) {.gcsafe.} =
    let html = """
<!DOCTYPE html><html><head>
<meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'>
<title>BaraDB Admin</title>
<style>
body{font:14px monospace;background:#1a1a2e;color:#e0e0e0;margin:0;padding:20px}
h1{color:#e94560;margin:0 0 10px}
.card{background:#16213e;border-radius:8px;padding:16px;margin:10px 0}
input,textarea,select{background:#0f3460;color:#e0e0e0;border:1px solid #533483;padding:8px;border-radius:4px;font:14px monospace;width:100%;box-sizing:border-box}
textarea{height:100px;resize:vertical}
button{background:#e94560;color:white;border:none;padding:8px 20px;border-radius:4px;cursor:pointer;font:14px monospace;margin:4px}
button:hover{background:#c23152}
table{width:100%;border-collapse:collapse;margin:10px 0}
th{background:#533483;padding:8px;text-align:left}
td{padding:6px 8px;border-bottom:1px solid #333}
tr:hover td{background:#1a2744}
#result{max-height:400px;overflow:auto;font:12px monospace;background:#0a0a1a;padding:8px;border-radius:4px;white-space:pre-wrap}
.tab{display:inline-block;padding:8px 16px;cursor:pointer;border-bottom:2px solid transparent}
.tab.active{border-color:#e94560;color:#e94560}
#tabs{margin-bottom:16px}
.status{color:#4ecca3;font-size:12px}
.error{color:#e94560}
a{color:#4ecca3}
</style></head><body>
<h1>BaraDB Admin</h1>
<div id='tabs'>
  <span class='tab active' onclick='showTab("query")'>SQL Playground</span>
  <span class='tab' onclick='showTab("schema")'>Schema</span>
  <span class='tab' onclick='showTab("metrics")'>Metrics</span>
</div>
<div id='tab-query'>
  <div class='card'>
    <textarea id='sql' placeholder='SELECT version()&#10;CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)&#10;INSERT INTO users VALUES (1, "test")&#10;SELECT * FROM users'></textarea>
    <button onclick='runQuery()'>Run</button>
    <button onclick='explainQuery()'>EXPLAIN</button>
  </div>
  <div id='result'></div>
</div>
<div id='tab-schema' style='display:none'>
  <div class='card' id='schema-data'>Loading schema...</div>
</div>
<div id='tab-metrics' style='display:none'>
  <div class='card' id='metrics-data'>Loading metrics...</div>
</div>
<script>
async function api(path, body) {
  const r = await fetch(path, {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body||{})})
  return r.json()
}
async function runQuery(){
  const sql = document.getElementById('sql').value
  const res = await api('/query', {query: sql})
  document.getElementById('result').innerHTML = JSON.stringify(res, null, 2)
}
async function explainQuery(){
  const sql = 'EXPLAIN ' + document.getElementById('sql').value
  const res = await api('/query', {query: sql})
  document.getElementById('result').innerHTML = JSON.stringify(res, null, 2)
}
async function loadSchema(){
  try{const r = await fetch('/query',{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({query:'SELECT name, type FROM __tables'})})
  const d = await r.json()
  document.getElementById('schema-data').innerHTML = '<table><tr><th>Table</th><th>Type</th></tr>' +
    (d.rows||[]).map(r=>'<tr><td>'+r.name+'</td><td>'+r.type+'</td></tr>').join('') + '</table>'
  }catch(e){}
}
async function loadMetrics(){
  try{const r = await fetch('/metrics')
  document.getElementById('metrics-data').innerHTML = '<pre>'+ (await r.text()) +'</pre>'
  }catch(e){}
}
function showTab(name){
  document.querySelectorAll('#tabs .tab').forEach(t=>t.classList.remove('active'))
  document.querySelectorAll('[id^=tab-]').forEach(t=>t.style.display='none')
  document.querySelector('.tab:nth-child('+({'query':1,'schema':2,'metrics':3}[name])+')').classList.add('active')
  document.getElementById('tab-'+name).style.display=''
  if(name==='schema') loadSchema()
  if(name==='metrics') loadMetrics()
}
</script>
<div class='status'>BaraDB v0.1.0 — Production-ready multimodal database</div>
</body></html>"""
    request.respond(200, @[("Content-Type", "text/html")], html)

proc run*(server: HttpServer, port: int = 8080) =
  var router = newRouter()
  router.get("/admin", server.adminHandler())
  router.get("/", server.adminHandler())
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
