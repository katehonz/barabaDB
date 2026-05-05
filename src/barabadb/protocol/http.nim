## HTTP/REST API — JSON endpoint
import std/asynchttpserver
import std/asyncdispatch
import std/json
import std/strutils
import std/tables

type
  HttpMethod* = enum
    hmGet = "GET"
    hmPost = "POST"
    hmPut = "PUT"
    hmDelete = "DELETE"
    hmPatch = "PATCH"
    hmOptions = "OPTIONS"

  RouteHandler* = proc(req: Request): Future[JsonNode] {.gcsafe.}

  HttpRouter* = ref object
    routes: Table[string, Table[string, RouteHandler]]  # method -> path -> handler
    middlewares: seq[RouteHandler]
    port*: int
    address*: string

  Request* = ref object
    httpMethod*: HttpMethod
    path*: string
    query*: Table[string, string]
    headers*: Table[string, string]
    body*: string
    contentType*: string

  Response* = object
    status*: int
    body*: JsonNode
    headers*: Table[string, string]

proc newHttpRouter*(port: int = 8080, address: string = "0.0.0.0"): HttpRouter =
  HttpRouter(
    routes: initTable[string, Table[string, RouteHandler]](),
    middlewares: @[],
    port: port,
    address: address,
  )

proc addRoute*(router: HttpRouter, meth: HttpMethod, path: string, handler: RouteHandler) =
  let m = $meth
  if m notin router.routes:
    router.routes[m] = initTable[string, RouteHandler]()
  router.routes[m][path] = handler

proc get*(router: HttpRouter, path: string, handler: RouteHandler) =
  router.addRoute(hmGet, path, handler)

proc post*(router: HttpRouter, path: string, handler: RouteHandler) =
  router.addRoute(hmPost, path, handler)

proc put*(router: HttpRouter, path: string, handler: RouteHandler) =
  router.addRoute(hmPut, path, handler)

proc delete*(router: HttpRouter, path: string, handler: RouteHandler) =
  router.addRoute(hmDelete, path, handler)

proc jsonResponse*(status: int, data: JsonNode, headers: Table[string, string] = initTable[string, string]()): Response =
  Response(status: status, body: data, headers: headers)

proc errorResponse*(status: int, message: string): Response =
  jsonResponse(status, %*{"error": message})

proc successResponse*(data: JsonNode): Response =
  jsonResponse(200, data)

proc parseQuery*(queryString: string): Table[string, string] =
  result = initTable[string, string]()
  if queryString.len == 0:
    return
  for pair in queryString.split("&"):
    let parts = pair.split("=", 1)
    if parts.len == 2:
      result[parts[0]] = parts[1]
    elif parts.len == 1:
      result[parts[0]] = ""

proc matchPath*(pattern, path: string): Table[string, string] =
  result = initTable[string, string]()
  let patternParts = pattern.split("/")
  let pathParts = path.split("/")
  if patternParts.len != pathParts.len:
    return
  for i in 0..<patternParts.len:
    if patternParts[i].startsWith(":"):
      result[patternParts[i][1..^1]] = pathParts[i]
    elif patternParts[i] != pathParts[i]:
      result.clear()
      return

proc corsHeaders*(): Table[string, string] =
  result = initTable[string, string]()
  result["Access-Control-Allow-Origin"] = "*"
  result["Access-Control-Allow-Methods"] = "GET, POST, PUT, DELETE, PATCH, OPTIONS"
  result["Access-Control-Allow-Headers"] = "Content-Type, Authorization"

proc jsonHeaders*(): Table[string, string] =
  result = initTable[string, string]()
  result["Content-Type"] = "application/json"

proc handleCors*(req: Request): Response =
  if req.httpMethod == hmOptions:
    return jsonResponse(204, newJNull(), corsHeaders())
  return nil

proc parseRequest*(httpMethod: string, path: string, headers: Table[string, string], body: string): Request =
  let methodMap = {
    "GET": hmGet, "POST": hmPost, "PUT": hmPut,
    "DELETE": hmDelete, "PATCH": hmPatch, "OPTIONS": hmOptions,
  }.toTable

  var query = initTable[string, string]()
  var cleanPath = path
  let qPos = path.find('?')
  if qPos >= 0:
    cleanPath = path[0..<qPos]
    query = parseQuery(path[qPos+1..^1])

  Request(
    httpMethod: methodMap.getOrDefault(httpMethod, hmGet),
    path: cleanPath,
    query: query,
    headers: headers,
    body: body,
    contentType: headers.getOrDefault("Content-Type", ""),
  )

proc handleRequest*(router: HttpRouter, req: Request): Future[Response] {.async.} =
  # CORS
  let corsResp = handleCors(req)
  if corsResp != nil:
    return corsResp

  let methodStr = $req.httpMethod
  if methodStr in router.routes:
    for pattern, handler in router.routes[methodStr]:
      let params = matchPath(pattern, req.path)
      if params.len > 0 or pattern == req.path:
        try:
          return jsonResponse(200, await handler(req), jsonHeaders())
        except CatchableError as e:
          return errorResponse(500, e.msg)

  return errorResponse(404, "Not found: " & req.path)
