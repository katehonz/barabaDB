## Optional HTTP/REST fallback client for BaraDB.
import std/asyncdispatch
import std/httpclient
import std/json
import std/strformat
import ./errors

type
  BaraHttpClient* = ref object
    baseUrl*: string
    token*: string
    http: AsyncHttpClient

proc newBaraHttpClient*(host = "127.0.0.1", port = 9912, token = ""): BaraHttpClient =
  BaraHttpClient(
    baseUrl: fmt"http://{host}:{port}/api",
    token: token,
    http: newAsyncHttpClient(),
  )

proc close*(client: BaraHttpClient) =
  client.http.close()

proc query*(client: BaraHttpClient, sql: string): Future[JsonNode] {.async.} =
  var headers = newHttpHeaders({"Content-Type": "application/json"})
  if client.token.len > 0:
    headers["Authorization"] = "Bearer " & client.token
  let body = %*{ "query": sql }
  let response = await client.http.request(
    client.baseUrl & "/query",
    httpMethod = HttpPost,
    body = $body,
    headers = headers,
  )
  let text = await response.body
  if response.code.int != 200:
    raise newException(BaraServerError, "HTTP error " & $response.code.int & ": " & text)
  return parseJson(text)
