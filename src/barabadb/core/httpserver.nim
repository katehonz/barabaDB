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
import std/asyncdispatch
import config
import ../query/lexer
import ../query/parser
import ../query/executor
import ../storage/lsm
import ../core/mvcc
import ../protocol/wire
import ../core/websocket
import jwt as jwtlib
import ../protocol/auth

type
  HttpServer* = ref object
    config: BaraConfig
    running: bool
    db*: LSMTree
    ctx: ExecutionContext
    metrics*: Metrics
    secretKey*: string
    authManager*: AuthManager
    ws*: WsServer

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
  let secret = config.getEffectiveJwtSecret()
  let ws = newWsServer(config, secret)
  ctx.onChange = proc(ev: ChangeEvent) =
    let msg = $ev.kind & " " & ev.table
    asyncCheck ws.broadcastToTable(ev.table, msg)
  let am = newAuthManager(secret)
  HttpServer(config: config, running: false, db: db, ctx: ctx,
             secretKey: secret,
             authManager: am,
             metrics: Metrics(), ws: ws)

# ----------------------------------------------------------------------
# JWT helpers
# ----------------------------------------------------------------------

proc createToken*(server: HttpServer, userId, role: string): string =
  let header = %*{"alg": "HS256", "typ": "JWT"}
  var claims = newTable[string, Claim]()
  claims["sub"] = newSUB(%userId)
  claims["role"] = newClaim(GENERAL, %role)
  claims["iat"] = newIAT(getTime().toUnix())
  claims["exp"] = newEXP((getTime() + 24.hours).toUnix())
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
# Auth helper
# ----------------------------------------------------------------------

proc checkAuth(server: HttpServer, request: Request, ctx: Context): bool =
  if not server.config.authEnabled:
    return true
  let authHeader = request.headers["Authorization"]
  if authHeader.len == 0 or not authHeader.startsWith("Bearer "):
    ctx.json(%*{"error": "Unauthorized"}, 401)
    return false
  let tokenStr = authHeader[7..^1]
  let (valid, userId, role) = server.verifyToken(tokenStr)
  if not valid:
    ctx.json(%*{"error": "Unauthorized"}, 401)
    return false
  return true

# ----------------------------------------------------------------------
# Handlers
# ----------------------------------------------------------------------

proc queryHandler(server: HttpServer): RequestHandler =
  return proc(request: Request) {.gcsafe.} =
    {.cast(gcsafe).}:
      let ctx = newContext(request)
      server.metrics.queriesTotal += 1

      # Auth check
      if server.config.authEnabled:
        let authHeader = request.headers["Authorization"]
        if authHeader.len == 0 or not authHeader.startsWith("Bearer "):
          ctx.json(%*{"error": "Unauthorized"}, 401)
          return
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

      # Extract optional params from JSON body
      var params: seq[WireValue] = @[]
      if "params" in body and body["params"].kind == JArray:
        for p in body["params"]:
          case p.kind
          of JNull: params.add(WireValue(kind: fkNull))
          of JBool: params.add(WireValue(kind: fkBool, boolVal: p.getBool()))
          of JInt: params.add(WireValue(kind: fkInt64, int64Val: p.getInt()))
          of JFloat: params.add(WireValue(kind: fkFloat64, float64Val: p.getFloat()))
          of JString: params.add(WireValue(kind: fkString, strVal: p.getStr()))
          else: params.add(WireValue(kind: fkString, strVal: $p))

      let res = executor.executeQuery(reqCtx, astNode, params)

      if res.success:
        var jsonRows = newJArray()
        for row in res.rows:
          var jsonRow = newJObject()
          for col in res.columns:
            let key = col
            var val = ""
            if key in row: val = row[key]
            jsonRow[key] = %val
          jsonRows.add(jsonRow)
        var jsonCols = newJArray()
        for c in res.columns:
          jsonCols.add(%c)
        ctx.json(%*{
          "rows": jsonRows,
          "affectedRows": res.affectedRows,
          "columns": jsonCols,
          "message": if res.message.len > 0: %res.message else: newJNull()
        })
      else:
        server.metrics.queryErrors += 1
        ctx.json(%*{"error": res.message}, 400)

proc healthHandler(): RequestHandler =
  return proc(request: Request) {.gcsafe.} =
    let ctx = newContext(request)
    ctx.json(%*{"status": "ok", "version": "1.1.0"})

proc metricsHandler(server: HttpServer): RequestHandler =
  return proc(request: Request) {.gcsafe.} =
    let ctx = newContext(request)
    if not server.checkAuth(request, ctx):
      return
    let prometheus = "baradb_queries_total " & $server.metrics.queriesTotal & "\n" &
                     "baradb_query_errors_total " & $server.metrics.queryErrors & "\n" &
                     "baradb_inserts_total " & $server.metrics.insertCount & "\n" &
                     "baradb_selects_total " & $server.metrics.selectCount & "\n" &
                     "baradb_connections_active " & $server.metrics.activeConnections & "\n"
    request.respond(200, @[("Content-Type", "text/plain; charset=utf-8")], prometheus)

proc authHandler(server: HttpServer): RequestHandler =
  return proc(request: Request) {.gcsafe.} =
    {.cast(gcsafe).}:
      let ctx = newContext(request)
      let body = parseJson(request.body)
      if body == nil or "username" notin body or "password" notin body:
        ctx.json(%*{"error": "Missing username or password"}, 400)
        return

      let username = body["username"].getStr()
      let password = body["password"].getStr()
      # Simple password check: must match jwtSecret when auth is enabled
      if server.config.authEnabled and password != server.config.jwtSecret:
        ctx.json(%*{"error": "Invalid credentials"}, 401)
        return

      let token = server.createToken(username, "user")
      ctx.json(%*{
        "token": token,
        "user": username,
        "role": "user"
      })

proc scramStartHandler(server: HttpServer): RequestHandler =
  return proc(request: Request) {.gcsafe.} =
    {.cast(gcsafe).}:
      let ctx = newContext(request)
      let body = parseJson(request.body)
      if body == nil or "username" notin body or "clientFirstMessage" notin body:
        ctx.json(%*{"error": "Missing username or clientFirstMessage"}, 400)
        return
      let username = body["username"].getStr()
      let clientFirst = body["clientFirstMessage"].getStr()
      try:
        let serverFirst = server.authManager.startScram(clientFirst)
        ctx.json(%*{
          "serverFirstMessage": serverFirst,
          "status": "continue"
        })
      except CatchableError as e:
        ctx.json(%*{"error": e.msg}, 401)

proc scramFinishHandler(server: HttpServer): RequestHandler =
  return proc(request: Request) {.gcsafe.} =
    {.cast(gcsafe).}:
      let ctx = newContext(request)
      let body = parseJson(request.body)
      if body == nil or "clientFinalMessage" notin body:
        ctx.json(%*{"error": "Missing clientFinalMessage"}, 400)
        return
      let clientFinal = body["clientFinalMessage"].getStr()
      try:
        let (ok, serverFinal) = server.authManager.finishScram(clientFinal)
        if ok:
          ctx.json(%*{
            "serverFinalMessage": serverFinal,
            "status": "authenticated"
          })
        else:
          ctx.json(%*{"error": serverFinal}, 401)
      except CatchableError as e:
        ctx.json(%*{"error": e.msg}, 401)

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

proc tablesHandler(server: HttpServer): RequestHandler =
  return proc(request: Request) {.gcsafe.} =
    {.cast(gcsafe).}:
      let ctx = newContext(request)
      if not server.checkAuth(request, ctx):
        return
      var tables = newJArray()
      for name, tbl in server.ctx.tables:
        var cols = newJArray()
        for col in tbl.columns:
          cols.add(%*{"name": col.name, "type": col.colType,
            "pk": col.isPk, "notNull": col.isNotNull, "unique": col.isUnique})
        tables.add(%*{"name": name, "columns": cols,
          "pkColumns": tbl.pkColumns, "fkCount": tbl.foreignKeys.len})
      ctx.json(%*{"tables": tables})

proc adminHandler(server: HttpServer): RequestHandler =
  return proc(request: Request) {.gcsafe.} =
    let html = """
<!DOCTYPE html><html><head>
<meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'>
<title>BaraDB Admin</title>
<style>
body{font:14px system-ui,-apple-system,sans-serif;background:#0f0f23;color:#e0e0e0;margin:0;padding:0}
header{background:#1a1a3e;padding:12px 20px;display:flex;align-items:center;justify-content:space-between;border-bottom:1px solid #533483}
header h1{color:#e94560;margin:0;font-size:20px}
#tabs{display:flex;background:#16213e;border-bottom:1px solid #333}
.tab{flex:1;text-align:center;padding:12px;cursor:pointer;border-bottom:3px solid transparent;font-size:13px;transition:.2s}
.tab.active{border-color:#e94560;color:#e94560;background:#1a2744}
.tab:hover{background:#1a2744}
.panel{display:none;padding:20px;max-width:1400px;margin:0 auto}
.panel.active{display:block}
.card{background:#16213e;border-radius:8px;padding:16px;margin:12px 0;border:1px solid #2a2a4a}
input,textarea,select{background:#0f3460;color:#e0e0e0;border:1px solid #533483;padding:8px;border-radius:4px;font:13px monospace;width:100%;box-sizing:border-box}
textarea{height:120px;resize:vertical}
button{background:#e94560;color:white;border:none;padding:8px 16px;border-radius:4px;cursor:pointer;font:13px monospace;margin:4px 2px}
button:hover{background:#c23152}
button.secondary{background:#533483}
button.secondary:hover{background:#3f2770}
table{width:100%;border-collapse:collapse;margin:10px 0;font-size:13px}
th{background:#533483;padding:8px;text-align:left;font-weight:600}
td{padding:6px 8px;border-bottom:1px solid #2a2a4a}
tr:hover td{background:#1a2744}
#result{max-height:400px;overflow:auto;font:12px monospace;background:#0a0a1a;padding:10px;border-radius:4px;white-space:pre-wrap;border:1px solid #2a2a4a}
.status{color:#4ecca3;font-size:12px}
.error{color:#e94560}
.warn{color:#f4d03f}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:16px}
.stat-box{background:#16213e;border-radius:8px;padding:16px;text-align:center;border:1px solid #2a2a4a}
.stat-box h3{margin:0 0 8px;color:#e94560;font-size:24px}
.stat-box p{margin:0;color:#aaa;font-size:12px}
#login-overlay{position:fixed;inset:0;background:rgba(0,0,0,.85);display:flex;align-items:center;justify-content:center;z-index:100}
#login-box{background:#16213e;padding:32px;border-radius:12px;width:320px;border:1px solid #533483}
#login-box h2{margin-top:0;color:#e94560}
#ws-log{height:300px;overflow:auto;background:#0a0a1a;padding:10px;border-radius:4px;font:12px monospace;border:1px solid #2a2a4a}
.log-line{padding:2px 0;border-bottom:1px solid #1a1a3e}
.table-list{display:flex;flex-wrap:wrap;gap:8px}
.table-tag{background:#0f3460;padding:6px 12px;border-radius:4px;cursor:pointer;font-size:13px;border:1px solid #533483}
.table-tag:hover{background:#533483}
.table-tag.active{background:#e94560;border-color:#e94560}
</style></head><body>
<div id='login-overlay'><div id='login-box'>
<h2>BaraDB Login</h2>
<input id='username' placeholder='Username' style='margin-bottom:8px'><br>
<input id='password' type='password' placeholder='Password' style='margin-bottom:12px'><br>
<button onclick='doLogin()' style='width:100%'>Login</button>
<p class='status' id='login-status'></p>
</div></div>
<header><h1>BaraDB Admin</h1><span id='user-info'></span></header>
<div id='tabs'>
  <span class='tab active' onclick='showTab(0)'>SQL Playground</span>
  <span class='tab' onclick='showTab(1)'>Tables</span>
  <span class='tab' onclick='showTab(2)'>Schema</span>
  <span class='tab' onclick='showTab(3)'>Live</span>
  <span class='tab' onclick='showTab(4)'>Metrics</span>
  <span class='tab' onclick='showTab(5)'>Cluster</span>
</div>
<div class='panel active'>
  <div class='card'><textarea id='sql' placeholder='SELECT * FROM users'></textarea>
    <button onclick='runQuery()'>Run</button>
    <button class='secondary' onclick='explainQuery()'>EXPLAIN</button>
    <button class='secondary' onclick='clearResult()'>Clear</button>
  </div>
  <div id='result'></div>
</div>
<div class='panel'>
  <div class='card'><h3>Tables</h3><div class='table-list' id='table-list'>Loading...</div></div>
  <div class='card'><h3>Browse <span id='browse-table'></span></h3>
    <div id='browse-data'>Select a table to browse</div>
  </div>
</div>
<div class='panel'>
  <div class='card' id='schema-data'>Loading schema...</div>
</div>
<div class='panel'>
  <div class='card'><h3>Real-time Events</h3><div id='ws-log'></div>
    <button onclick='clearWsLog()'>Clear</button>
  </div>
</div>
<div class='panel'>
  <div class='grid' id='metrics-grid'>
    <div class='stat-box'><h3 id='m-queries'>0</h3><p>Total Queries</p></div>
    <div class='stat-box'><h3 id='m-errors'>0</h3><p>Query Errors</p></div>
    <div class='stat-box'><h3 id='m-inserts'>0</h3><p>Inserts</p></div>
    <div class='stat-box'><h3 id='m-selects'>0</h3><p>Selects</p></div>
    <div class='stat-box'><h3 id='m-connections'>0</h3><p>Active Connections</p></div>
    <div class='stat-box'><h3 id='m-tables'>0</h3><p>Tables</p></div>
  </div>
  <div class='card'><h3>Raw Metrics</h3><pre id='metrics-raw'></pre></div>
</div>
<div class='panel'>
  <div class='card'><h3>Cluster Status</h3><div id='cluster-data'>Cluster status not available</div></div>
</div>
<script>
let token = localStorage.getItem('baradb_token') || ''
let ws = null
function authHeader(){ return token ? {'Authorization':'Bearer '+token,'Content-Type':'application/json'} : {'Content-Type':'application/json'} }
async function api(path, body, method='POST') {
  const r = await fetch(path, {method, headers:authHeader(), body: body?JSON.stringify(body):undefined})
  return r.json().catch(() => r.text())
}
async function doLogin(){
  const u = document.getElementById('username').value
  const p = document.getElementById('password').value
  const r = await api('/auth', {username:u, password:p})
  if(r.token){ token = r.token; localStorage.setItem('baradb_token', token); hideLogin(); showUser(r.user); connectWS() }
  else { document.getElementById('login-status').textContent = r.error || 'Login failed' }
}
function hideLogin(){ document.getElementById('login-overlay').style.display='none' }
function showUser(u){ document.getElementById('user-info').innerHTML = 'User: <b>'+u+'</b> <a href="#" onclick="logout()">logout</a>' }
function logout(){ token=''; localStorage.removeItem('baradb_token'); location.reload() }
if(token){ hideLogin(); showUser('...'); api('/health',null,'GET').then(()=>showUser('authed')).catch(()=>logout()); connectWS() }
async function runQuery(){
  const sql = document.getElementById('sql').value
  const res = await api('/query', {query: sql})
  renderResult(res)
}
async function explainQuery(){
  const res = await api('/query', {query: 'EXPLAIN ' + document.getElementById('sql').value})
  renderResult(res)
}
function renderResult(res){
  const el = document.getElementById('result')
  if(res.error){ el.innerHTML = '<span class="error">Error: '+res.error+'</span>'; return }
  let html = ''
  if(res.columns && res.columns.length){
    html += '<table><tr>'+res.columns.map(c=>'<th>'+c+'</th>').join('')+'</tr>'
    html += (res.rows||[]).map(row => '<tr>'+res.columns.map(c=>'<td>'+(row[c]??'')+'</td>').join('')+'</tr>').join('')
    html += '</table>'
  }
  if(res.affectedRows != null) html += '<p class="status">Affected rows: '+res.affectedRows+'</p>'
  if(res.message) html += '<p class="status">'+res.message+'</p>'
  el.innerHTML = html || JSON.stringify(res, null, 2)
}
function clearResult(){ document.getElementById('result').innerHTML = '' }
let currentTable = ''
async function loadTables(){
  const r = await api('/tables', null, 'GET')
  const list = document.getElementById('table-list')
  if(!r.tables){ list.innerHTML = 'No tables'; return }
  list.innerHTML = r.tables.map(t => '<span class="table-tag'+(t.name===currentTable?' active':'')+'" onclick="browseTable(\''+t.name+'\')">'+t.name+' ('+t.columns.length+' cols)</span>').join('')
  document.getElementById('m-tables').textContent = r.tables.length
}
async function browseTable(name){
  currentTable = name
  document.getElementById('browse-table').textContent = name
  const res = await api('/query', {query: 'SELECT * FROM '+name+' LIMIT 100'})
  const el = document.getElementById('browse-data')
  if(res.error){ el.innerHTML = '<span class="error">'+res.error+'</span>'; return }
  if(!res.columns || !res.columns.length){ el.innerHTML = 'Empty table'; return }
  let html = '<table><tr>'+res.columns.map(c=>'<th>'+c+'</th>').join('')+'</tr>'
  html += (res.rows||[]).map(row => '<tr>'+res.columns.map(c=>'<td>'+(row[c]??'')+'</td>').join('')+'</tr>').join('')
  html += '</table>'
  el.innerHTML = html
  loadTables()
}
async function loadSchema(){
  const r = await api('/tables', null, 'GET')
  const el = document.getElementById('schema-data')
  if(!r.tables){ el.innerHTML = 'No tables'; return }
  let html = ''
  r.tables.forEach(t => {
    html += '<h4>'+t.name+'</h4><table><tr><th>Column</th><th>Type</th><th>PK</th><th>Not Null</th><th>Unique</th></tr>'
    t.columns.forEach(c => html += '<tr><td>'+c.name+'</td><td>'+c.type+'</td><td>'+(c.pk?'✓':'')+'</td><td>'+(c.notNull?'✓':'')+'</td><td>'+(c.unique?'✓':'')+'</td></tr>')
    html += '</table>'
  })
  el.innerHTML = html
}
function connectWS(){
  const wsProto = location.protocol === 'https:' ? 'wss:' : 'ws:';
  const wsUrl = wsProto+'//'+location.host.split(':')[0]+':'+((parseInt(location.port)||80)+1)+'/live'
  try{
    ws = new WebSocket(wsUrl)
    ws.onmessage = ev => {
      const log = document.getElementById('ws-log')
      const line = document.createElement('div')
      line.className = 'log-line'
      line.textContent = new Date().toLocaleTimeString() + ' ' + ev.data
      log.appendChild(line)
      log.scrollTop = log.scrollHeight
    }
    ws.onopen = () => { const log = document.getElementById('ws-log'); log.innerHTML += '<div class="log-line status">Connected</div>' }
    ws.onclose = () => { setTimeout(connectWS, 3000) }
  }catch(e){}
}
function clearWsLog(){ document.getElementById('ws-log').innerHTML = '' }
async function loadMetrics(){
  try{
    const r = await fetch('/metrics', {headers: token?{'Authorization':'Bearer '+token}:{}})
    const text = await r.text()
    document.getElementById('metrics-raw').textContent = text
    const lines = text.split('\n')
    lines.forEach(l => {
      if(l.startsWith('baradb_queries_total ')) document.getElementById('m-queries').textContent = l.split(' ')[1]
      if(l.startsWith('baradb_query_errors ')) document.getElementById('m-errors').textContent = l.split(' ')[1]
      if(l.startsWith('baradb_insert_count ')) document.getElementById('m-inserts').textContent = l.split(' ')[1]
      if(l.startsWith('baradb_select_count ')) document.getElementById('m-selects').textContent = l.split(' ')[1]
      if(l.startsWith('baradb_active_connections ')) document.getElementById('m-connections').textContent = l.split(' ')[1]
    })
  }catch(e){}
}
function showTab(idx){
  document.querySelectorAll('.tab').forEach((t,i)=>t.classList.toggle('active', i===idx))
  document.querySelectorAll('.panel').forEach((p,i)=>p.classList.toggle('active', i===idx))
  if(idx===1) loadTables()
  if(idx===2) loadSchema()
  if(idx===4) loadMetrics()
}
setInterval(() => { if(document.querySelectorAll('.panel')[4].classList.contains('active')) loadMetrics() }, 5000)
</script>
<div class='status' style='text-align:center;padding:10px'>BaraDB v1.1.0 — Multimodal Database Engine</div>
</body></html>"""
    request.respond(200, @[("Content-Type", "text/html; charset=utf-8")], html)

proc run*(server: HttpServer, port: int = 9470) =
  var router = newRouter()
  router.get("/admin", server.adminHandler())
  router.get("/", server.adminHandler())
  router.post("/query", server.queryHandler())
  router.get("/health", healthHandler())
  router.get("/metrics", server.metricsHandler())
  router.post("/auth", server.authHandler())
  router.post("/auth/scram/start", server.scramStartHandler())
  router.post("/auth/scram/finish", server.scramFinishHandler())
  router.get("/tables", server.tablesHandler())
  router.get("/api", openApiHandler())

  var stack = newMiddlewareStack(router)
  stack.use(corsMiddleware())

  let hunosServer = newServer(stack)
  echo "BaraDB HTTP listening on port ", port
  server.running = true
  asyncCheck server.ws.run(port + 1)
  hunosServer.serve(Port(port))

proc stop*(server: HttpServer) =
  server.running = false
  server.ws.stop()
  server.db.close()
