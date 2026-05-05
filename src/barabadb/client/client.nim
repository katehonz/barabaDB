## BaraDB Client — Nim client library
import std/asyncdispatch
import std/asyncnet
import std/strutils
import std/json
import ../protocol/wire

type
  ClientConfig* = object
    host*: string
    port*: int
    database*: string
    username*: string
    password*: string
    timeout*: int  # milliseconds
    maxRetries*: int

  QueryResult* = object
    columns*: seq[string]
    rows*: seq[seq[string]]
    rowCount*: int
    affectedRows*: int
    executionTime*: float64  # seconds

  BaraClient* = ref object
    config: ClientConfig
    socket: AsyncSocket
    connected: bool
    requestId: uint32

proc defaultClientConfig*(): ClientConfig =
  ClientConfig(
    host: "127.0.0.1",
    port: 5432,
    database: "default",
    username: "admin",
    password: "",
    timeout: 30000,
    maxRetries: 3,
  )

proc newBaraClient*(config: ClientConfig = defaultClientConfig()): BaraClient =
  BaraClient(
    config: config,
    socket: newAsyncSocket(),
    connected: false,
    requestId: 0,
  )

proc connect*(client: BaraClient) {.async.} =
  await client.socket.connect(client.config.host, Port(client.config.port))
  client.connected = true

proc disconnect*(client: BaraClient) {.async.} =
  if client.connected:
    client.socket.close()
    client.connected = false

proc nextRequestId(client: BaraClient): uint32 =
  inc client.requestId
  return client.requestId

proc query*(client: BaraClient, sql: string): Future[QueryResult] {.async.} =
  if not client.connected:
    raise newException(IOError, "Not connected")

  let reqId = client.nextRequestId()
  let msg = makeQueryMessage(reqId, sql)
  await client.socket.send(cast[string](msg))

  # Read response
  let response = await client.socket.recv(8192)
  if response.len == 0:
    raise newException(IOError, "Connection closed by server")

  result = QueryResult(columns: @[], rows: @[], rowCount: 0, affectedRows: 0)

  # Parse response (simplified)
  if response.len > 0:
    result.rowCount = 0

proc execute*(client: BaraClient, sql: string): Future[int] {.async.} =
  let qr = await client.query(sql)
  return qr.affectedRows

proc isConnected*(client: BaraClient): bool = client.connected

# Synchronous wrapper
type
  SyncClient* = ref object
    asyncClient: BaraClient

proc newSyncClient*(config: ClientConfig = defaultClientConfig()): SyncClient =
  SyncClient(asyncClient: newBaraClient(config))

proc connect*(client: SyncClient) =
  waitFor client.asyncClient.connect()

proc disconnect*(client: SyncClient) =
  waitFor client.asyncClient.disconnect()

proc query*(client: SyncClient, sql: string): QueryResult =
  waitFor client.asyncClient.query(sql)

proc execute*(client: SyncClient, sql: string): int =
  waitFor client.asyncClient.execute(sql)

proc isConnected*(client: SyncClient): bool =
  client.asyncClient.isConnected

# Connection string parser
proc parseConnectionString*(connStr: string): ClientConfig =
  result = defaultClientConfig()
  let parts = connStr.split(" ")
  for part in parts:
    let kv = part.split("=", 1)
    if kv.len == 2:
      case kv[0].toLower()
      of "host": result.host = kv[1]
      of "port": result.port = parseInt(kv[1])
      of "database", "dbname": result.database = kv[1]
      of "user", "username": result.username = kv[1]
      of "password", "pass": result.password = kv[1]
      of "connect_timeout", "timeout": result.timeout = parseInt(kv[1])
      else: discard

# Fluent query builder
type
  QueryBuilder* = ref object
    client: BaraClient
    selectCols: seq[string]
    fromTable: string
    whereClauses: seq[string]
    orderByCols: seq[string]
    orderDirs: seq[string]
    limitVal: int
    offsetVal: int
    groupByCols: seq[string]
    havingClause: string
    joinClauses: seq[string]

proc newQueryBuilder*(client: BaraClient): QueryBuilder =
  QueryBuilder(
    client: client,
    selectCols: @[],
    fromTable: "",
    whereClauses: @[],
    orderByCols: @[],
    orderDirs: @[],
    limitVal: 0,
    offsetVal: 0,
    groupByCols: @[],
    havingClause: "",
    joinClauses: @[],
  )

proc select*(qb: QueryBuilder, cols: varargs[string]): QueryBuilder =
  for col in cols:
    qb.selectCols.add(col)
  return qb

proc `from`*(qb: QueryBuilder, table: string): QueryBuilder =
  qb.fromTable = table
  return qb

proc where*(qb: QueryBuilder, clause: string): QueryBuilder =
  qb.whereClauses.add(clause)
  return qb

proc orderBy*(qb: QueryBuilder, col: string, dir: string = "ASC"): QueryBuilder =
  qb.orderByCols.add(col)
  qb.orderDirs.add(dir)
  return qb

proc limit*(qb: QueryBuilder, n: int): QueryBuilder =
  qb.limitVal = n
  return qb

proc offset*(qb: QueryBuilder, n: int): QueryBuilder =
  qb.offsetVal = n
  return qb

proc join*(qb: QueryBuilder, table: string, on: string): QueryBuilder =
  qb.joinClauses.add("JOIN " & table & " ON " & on)
  return qb

proc groupBy*(qb: QueryBuilder, cols: varargs[string]): QueryBuilder =
  for col in cols:
    qb.groupByCols.add(col)
  return qb

proc having*(qb: QueryBuilder, clause: string): QueryBuilder =
  qb.havingClause = clause
  return qb

proc build*(qb: QueryBuilder): string =
  result = "SELECT "
  if qb.selectCols.len == 0:
    result &= "*"
  else:
    result &= qb.selectCols.join(", ")
  result &= " FROM " & qb.fromTable
  for joinClause in qb.joinClauses:
    result &= " " & joinClause
  if qb.whereClauses.len > 0:
    result &= " WHERE " & qb.whereClauses.join(" AND ")
  if qb.groupByCols.len > 0:
    result &= " GROUP BY " & qb.groupByCols.join(", ")
  if qb.havingClause.len > 0:
    result &= " HAVING " & qb.havingClause
  if qb.orderByCols.len > 0:
    result &= " ORDER BY "
    for i, col in qb.orderByCols:
      if i > 0: result &= ", "
      result &= col & " " & qb.orderDirs[i]
  if qb.limitVal > 0:
    result &= " LIMIT " & $qb.limitVal
  if qb.offsetVal > 0:
    result &= " OFFSET " & $qb.offsetVal

proc exec*(qb: QueryBuilder): Future[QueryResult] {.async.} =
  return await qb.client.query(qb.build())
