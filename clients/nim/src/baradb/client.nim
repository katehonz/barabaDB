## BaraDB Client — canonical Nim client library.
## Self-contained; depends only on Nim stdlib.
import std/asyncdispatch
import std/asyncnet
import std/net as netmod
import std/locks
import std/strutils

import ./wire
export wire
import ./errors
export errors

# === AsyncLock (stdlib-only serialization primitive) ===

type
  AsyncLockObj = object
    locked: bool
    waiters: seq[Future[void]]

  AsyncLock* = ref AsyncLockObj

proc initAsyncLock*(): AsyncLock =
  new(result)
  result.locked = false
  result.waiters = @[]

proc acquire*(lock: AsyncLock): Future[void] =
  var fut = newFuture[void]("AsyncLock.acquire")
  if not lock.locked:
    lock.locked = true
    fut.complete()
  else:
    lock.waiters.add(fut)
  return fut

proc release*(lock: AsyncLock) =
  if lock.waiters.len > 0:
    let next = lock.waiters[0]
    lock.waiters.delete(0)
    next.complete()
  else:
    lock.locked = false

# === Configuration & result types ===

type
  ClientConfig* = object
    host*: string
    port*: int
    database*: string
    username*: string
    password*: string
    timeoutMs*: int
    maxRetries*: int
    ssl*: bool
    when defined(ssl):
      sslContext*: netmod.SslContext

  QueryResult* = object
    columns*: seq[string]
    columnTypes*: seq[FieldKind]
    rows*: seq[seq[string]]          # legacy string view
    typedRows*: seq[seq[WireValue]]  # typed view
    rowCount*: int
    affectedRows*: int
    executionTimeMs*: float64
    lastInsertId*: int64

  BaraClient* = ref object
    config*: ClientConfig
    socket*: AsyncSocket
    connected*: bool
    requestId*: uint32
    sendLock*: AsyncLock

proc defaultConfig*(): ClientConfig =
  result = ClientConfig(
    host: "127.0.0.1", port: 9472, database: "default",
    username: "admin", password: "", timeoutMs: 30000, maxRetries: 3,
    ssl: false,
  )
  when defined(ssl):
    result.sslContext = nil

proc newClient*(config: ClientConfig = defaultConfig()): BaraClient =
  result = BaraClient(
    config: config,
    socket: newAsyncSocket(),
    connected: false,
    requestId: 0,
    sendLock: initAsyncLock(),
  )

# Aliases for older call sites / server test suite
proc defaultClientConfig*(): ClientConfig {.inline.} = defaultConfig()
proc newBaraClient*(config: ClientConfig = defaultConfig()): BaraClient {.inline.} =
  newClient(config)

proc parseConnectionString*(connStr: string): ClientConfig =
  ## Parse space-separated key=value pairs (libpq-style subset).
  result = defaultConfig()
  for part in connStr.split(" "):
    let kv = part.split("=", 1)
    if kv.len == 2:
      case kv[0].toLowerAscii()
      of "host": result.host = kv[1]
      of "port": result.port = parseInt(kv[1])
      of "database", "dbname": result.database = kv[1]
      of "user", "username": result.username = kv[1]
      of "password", "pass": result.password = kv[1]
      of "connect_timeout", "timeout": result.timeoutMs = parseInt(kv[1])
      else: discard

proc nextId*(client: BaraClient): uint32 =
  inc client.requestId
  client.requestId

proc awaitWithTimeout(fut: Future[void], ms: int): Future[void] {.async.} =
  if ms <= 0:
    await fut
  else:
    let ok = await withTimeout(fut, ms)
    if not ok:
      raise newException(BaraIoError, "Operation timed out")
    await fut

proc awaitWithTimeout(fut: Future[string], ms: int): Future[string] {.async.} =
  if ms <= 0:
    result = await fut
  else:
    let ok = await withTimeout(fut, ms)
    if not ok:
      raise newException(BaraIoError, "Operation timed out")
    result = await fut

proc recvExact(sock: AsyncSocket, size: int, timeoutMs: int): Future[string] {.async.} =
  var data = ""
  while data.len < size:
    let chunk = await awaitWithTimeout(sock.recv(size - data.len), timeoutMs)
    if chunk.len == 0:
      raise newException(BaraIoError, "Connection closed while reading")
    data.add(chunk)
  return data

proc connect*(client: BaraClient) {.async.} =
  await client.socket.connect(client.config.host, Port(client.config.port)).awaitWithTimeout(client.config.timeoutMs)
  if client.config.ssl:
    when defined(ssl):
      # Async binary TLS over asyncnet is not supported by the Nim stdlib alone.
      # Supply an sslContext only if you have wired up a platform-specific async TLS socket.
      if client.config.sslContext.isNil:
        raise newException(BaraIoError, "Async binary TLS requires a user-supplied sslContext")
      # The caller is responsible for wrapping an async-compatible socket before passing it in.
    else:
      raise newException(BaraIoError, "SSL requested but Nim built without -d:ssl")
  client.connected = true

proc close*(client: BaraClient) =
  if client.connected:
    try:
      let msg = buildMessage(mkClose, client.nextId(), @[])
      waitFor client.socket.send(toString(msg))
    except: discard
    client.socket.close()
    client.connected = false

proc isConnected*(client: BaraClient): bool = client.connected

proc wireValueToString*(wv: WireValue): string =
  case wv.kind
  of fkNull: return ""
  of fkBool: return if wv.boolVal: "true" else: "false"
  of fkInt8: return $wv.int8Val
  of fkInt16: return $wv.int16Val
  of fkInt32: return $wv.int32Val
  of fkInt64: return $wv.int64Val
  of fkFloat32: return $wv.float32Val
  of fkFloat64: return $wv.float64Val
  of fkString: return wv.strVal
  of fkBytes: return "<bytes:" & $wv.bytesVal.len & ">"
  of fkArray: return "<array:" & $wv.arrayVal.len & ">"
  of fkObject: return "<object:" & $wv.objVal.len & ">"
  of fkVector: return "<vector:" & $wv.vecVal.len & ">"
  of fkJson: return wv.jsonVal

proc readResponsePayload(client: BaraClient): Future[(MsgKind, seq[byte])] {.async.} =
  let headerStr = await recvExact(client.socket, 12, client.config.timeoutMs)
  var pos = 0
  let hdrData = toBytes(headerStr)
  let kind = MsgKind(readUint32(hdrData, pos))
  let payloadLen = int(readUint32(hdrData, pos))
  discard readUint32(hdrData, pos)
  let payloadStr = await recvExact(client.socket, payloadLen, client.config.timeoutMs)
  return (kind, toBytes(payloadStr))

proc parseQueryResponse(client: BaraClient, kind: MsgKind, payload: seq[byte]): Future[QueryResult] {.async.} =
  result = QueryResult(columns: @[], rows: @[], typedRows: @[], rowCount: 0, affectedRows: 0)
  if kind == mkReady:
    return
  if kind == mkError and payload.len >= 8:
    var epos = 0
    let code = readUint32(payload, epos)
    let emsg = readString(payload, epos)
    var err = newException(BaraServerError, "Error " & $code & ": " & emsg)
    err.code = code
    raise err
  if kind == mkData:
    var dpos = 0
    let colCount = int(readUint32(payload, dpos))
    for i in 0..<colCount:
      result.columns.add(readString(payload, dpos))
    for i in 0..<colCount:
      result.columnTypes.add(FieldKind(payload[dpos]))
      inc dpos
    let rowCount = int(readUint32(payload, dpos))
    result.rowCount = rowCount
    for r in 0..<rowCount:
      var typedRow: seq[WireValue] = @[]
      var stringRow: seq[string] = @[]
      for c in 0..<colCount:
        let wv = deserializeValue(payload, dpos)
        typedRow.add(wv)
        stringRow.add(wireValueToString(wv))
      result.typedRows.add(typedRow)
      result.rows.add(stringRow)
    # Read following mkComplete message
    let (compKind, compPayload) = await client.readResponsePayload()
    if compKind == mkComplete and compPayload.len >= 4:
      var cpPos = 0
      result.affectedRows = int(readUint32(compPayload, cpPos))
    return
  if kind == mkComplete:
    var rpos = 0
    result.affectedRows = int(readUint32(payload, rpos))
    return
  raise newException(BaraProtocolError, "Unexpected response kind: 0x" & toHex(uint32(kind), 2))

proc doQuery(client: BaraClient, msg: seq[byte]): Future[QueryResult] {.async.} =
  if not client.connected:
    raise newException(BaraIoError, "Not connected")
  await client.sendLock.acquire()
  try:
    await client.socket.send(toString(msg))
    let (kind, payload) = await client.readResponsePayload()
    return await client.parseQueryResponse(kind, payload)
  finally:
    client.sendLock.release()

proc query*(client: BaraClient, sql: string): Future[QueryResult] {.async.} =
  let msg = makeQueryMessage(client.nextId(), sql)
  return await client.doQuery(msg)

proc query*(client: BaraClient, sql: string, params: seq[WireValue]): Future[QueryResult] {.async.} =
  let msg = makeQueryParamsMessage(client.nextId(), sql, params)
  return await client.doQuery(msg)

proc exec*(client: BaraClient, sql: string): Future[int] {.async.} =
  let qr = await client.query(sql)
  return qr.affectedRows

proc auth*(client: BaraClient, token: string) {.async.} =
  let msg = makeAuthMessage(client.nextId(), token)
  await client.sendLock.acquire()
  try:
    await client.socket.send(toString(msg))
    let (kind, payload) = await client.readResponsePayload()
    case kind
    of mkAuthOk:
      return
    of mkError:
      var epos = 0
      discard readUint32(payload, epos)
      let emsg = readString(payload, epos)
      raise newException(BaraAuthError, "Auth failed: " & emsg)
    else:
      raise newException(BaraProtocolError, "Unexpected auth response: 0x" & toHex(uint32(kind), 2))
  finally:
    client.sendLock.release()

proc ping*(client: BaraClient): Future[bool] {.async.} =
  if not client.connected:
    return false
  let msg = buildMessage(mkPing, client.nextId(), @[])
  await client.sendLock.acquire()
  try:
    await client.socket.send(toString(msg))
    let (kind, _) = await client.readResponsePayload()
    return kind == mkPong
  except:
    return false
  finally:
    client.sendLock.release()

proc readQueryResponse*(client: BaraClient): Future[QueryResult] {.async.} =
  ## Read and parse the next server response. Does NOT acquire sendLock;
  ## callers that already sent a message manually can use this.
  let (kind, payload) = await client.readResponsePayload()
  return await client.parseQueryResponse(kind, payload)

# === Fluent Query Builder ===

type
  QueryBuilder* = ref object
    client: BaraClient
    selectCols: seq[string]
    fromTable: string
    whereClauses: seq[string]
    joinClauses: seq[string]
    groupByCols: seq[string]
    havingClause: string
    orderCols: seq[string]
    orderDirs: seq[string]
    limitVal: int
    offsetVal: int

proc newQueryBuilder*(client: BaraClient): QueryBuilder =
  QueryBuilder(client: client, limitVal: 0, offsetVal: 0)

proc select*(qb: QueryBuilder, cols: varargs[string]): QueryBuilder =
  for c in cols: qb.selectCols.add(c)
  return qb

proc `from`*(qb: QueryBuilder, table: string): QueryBuilder =
  qb.fromTable = table
  return qb

proc where*(qb: QueryBuilder, clause: string): QueryBuilder =
  qb.whereClauses.add(clause)
  return qb

proc join*(qb: QueryBuilder, table: string, on: string): QueryBuilder =
  qb.joinClauses.add("JOIN " & table & " ON " & on)
  return qb

proc leftJoin*(qb: QueryBuilder, table: string, on: string): QueryBuilder =
  qb.joinClauses.add("LEFT JOIN " & table & " ON " & on)
  return qb

proc groupBy*(qb: QueryBuilder, cols: varargs[string]): QueryBuilder =
  for c in cols: qb.groupByCols.add(c)
  return qb

proc having*(qb: QueryBuilder, clause: string): QueryBuilder =
  qb.havingClause = clause
  return qb

proc orderBy*(qb: QueryBuilder, col: string, dir: string = "ASC"): QueryBuilder =
  qb.orderCols.add(col)
  qb.orderDirs.add(dir)
  return qb

proc limit*(qb: QueryBuilder, n: int): QueryBuilder =
  qb.limitVal = n
  return qb

proc offset*(qb: QueryBuilder, n: int): QueryBuilder =
  qb.offsetVal = n
  return qb

proc build*(qb: QueryBuilder): string =
  result = "SELECT " & (if qb.selectCols.len > 0: qb.selectCols.join(", ") else: "*")
  result &= " FROM " & qb.fromTable
  for j in qb.joinClauses: result &= " " & j
  if qb.whereClauses.len > 0: result &= " WHERE " & qb.whereClauses.join(" AND ")
  if qb.groupByCols.len > 0: result &= " GROUP BY " & qb.groupByCols.join(", ")
  if qb.havingClause.len > 0: result &= " HAVING " & qb.havingClause
  if qb.orderCols.len > 0:
    result &= " ORDER BY "
    for i, col in qb.orderCols:
      if i > 0: result &= ", "
      result &= col & " " & qb.orderDirs[i]
  if qb.limitVal > 0: result &= " LIMIT " & $qb.limitVal
  if qb.offsetVal > 0: result &= " OFFSET " & $qb.offsetVal

proc exec*(qb: QueryBuilder): Future[QueryResult] {.async.} =
  return await qb.client.query(qb.build())

# === Blocking Sync Client ===

type
  SyncClient* = ref object
    config: ClientConfig
    socket: netmod.Socket
    connected: bool
    requestId: uint32
    lock: Lock

proc newSyncClient*(config: ClientConfig = defaultConfig()): SyncClient =
  result = SyncClient(config: config, connected: false, requestId: 0)
  result.socket = netmod.newSocket()
  initLock(result.lock)

proc recvExactBlocking(sock: netmod.Socket, size: int): string =
  result = ""
  while result.len < size:
    let chunk = sock.recv(size - result.len)
    if chunk.len == 0:
      raise newException(BaraIoError, "Connection closed")
    result.add(chunk)

proc readResponsePayloadBlocking(client: SyncClient): (MsgKind, seq[byte]) =
  let headerData = client.socket.recvExactBlocking(12)
  var pos = 0
  let hdrData = toBytes(headerData)
  let kind = MsgKind(readUint32(hdrData, pos))
  let payloadLen = int(readUint32(hdrData, pos))
  discard readUint32(hdrData, pos)
  let payloadStr = client.socket.recvExactBlocking(payloadLen)
  return (kind, toBytes(payloadStr))

proc parseQueryResponseBlocking(client: SyncClient, kind: MsgKind, payload: seq[byte]): QueryResult =
  result = QueryResult(columns: @[], rows: @[], typedRows: @[], rowCount: 0, affectedRows: 0)
  if kind == mkReady:
    return
  if kind == mkError and payload.len >= 8:
    var epos = 0
    let code = readUint32(payload, epos)
    let emsg = readString(payload, epos)
    var err = newException(BaraServerError, "Error " & $code & ": " & emsg)
    err.code = code
    raise err
  if kind == mkData:
    var dpos = 0
    let colCount = int(readUint32(payload, dpos))
    for i in 0..<colCount:
      result.columns.add(readString(payload, dpos))
    for i in 0..<colCount:
      result.columnTypes.add(FieldKind(payload[dpos]))
      inc dpos
    let rowCount = int(readUint32(payload, dpos))
    result.rowCount = rowCount
    for r in 0..<rowCount:
      var typedRow: seq[WireValue] = @[]
      var stringRow: seq[string] = @[]
      for c in 0..<colCount:
        let wv = deserializeValue(payload, dpos)
        typedRow.add(wv)
        stringRow.add(wireValueToString(wv))
      result.typedRows.add(typedRow)
      result.rows.add(stringRow)
    let (compKind, compPayload) = client.readResponsePayloadBlocking()
    if compKind == mkComplete and compPayload.len >= 4:
      var cpPos = 0
      result.affectedRows = int(readUint32(compPayload, cpPos))
    return
  if kind == mkComplete:
    var rpos = 0
    result.affectedRows = int(readUint32(payload, rpos))
    return
  raise newException(BaraProtocolError, "Unexpected response kind: 0x" & toHex(uint32(kind), 2))

proc connect*(client: SyncClient) =
  netmod.connect(client.socket, client.config.host, Port(client.config.port))
  client.connected = true

proc close*(client: SyncClient) =
  if client.connected:
    try:
      let msg = buildMessage(mkClose, 0, @[])
      netmod.send(client.socket, toString(msg))
    except: discard
    netmod.close(client.socket)
    client.connected = false
  deinitLock(client.lock)

proc query*(client: SyncClient, sql: string): QueryResult =
  acquire(client.lock)
  try:
    if not client.connected:
      raise newException(BaraIoError, "Not connected")
    let msg = makeQueryMessage(0, sql)
    netmod.send(client.socket, toString(msg))
    let (kind, payload) = client.readResponsePayloadBlocking()
    return client.parseQueryResponseBlocking(kind, payload)
  finally:
    release(client.lock)

proc query*(client: SyncClient, sql: string, params: seq[WireValue]): QueryResult =
  acquire(client.lock)
  try:
    if not client.connected:
      raise newException(BaraIoError, "Not connected")
    let msg = makeQueryParamsMessage(0, sql, params)
    netmod.send(client.socket, toString(msg))
    let (kind, payload) = client.readResponsePayloadBlocking()
    return client.parseQueryResponseBlocking(kind, payload)
  finally:
    release(client.lock)

proc exec*(client: SyncClient, sql: string): int =
  let qr = client.query(sql)
  return qr.affectedRows

proc auth*(client: SyncClient, token: string) =
  acquire(client.lock)
  try:
    if not client.connected:
      raise newException(BaraIoError, "Not connected")
    let msg = makeAuthMessage(0, token)
    netmod.send(client.socket, toString(msg))
    let (kind, payload) = client.readResponsePayloadBlocking()
    case kind
    of mkAuthOk:
      return
    of mkError:
      var epos = 0
      discard readUint32(payload, epos)
      let emsg = readString(payload, epos)
      raise newException(BaraAuthError, "Auth failed: " & emsg)
    else:
      raise newException(BaraProtocolError, "Unexpected auth response")
  finally:
    release(client.lock)

proc ping*(client: SyncClient): bool =
  acquire(client.lock)
  try:
    if not client.connected:
      return false
    let msg = buildMessage(mkPing, 0, @[])
    netmod.send(client.socket, toString(msg))
    let (kind, _) = client.readResponsePayloadBlocking()
    return kind == mkPong
  except:
    return false
  finally:
    release(client.lock)

proc `$`*(qr: QueryResult): string =
  if qr.columns.len == 0: return "(no results)"
  result = ""
  for i, col in qr.columns:
    result &= col
    if i < qr.columns.len - 1: result &= ", "
  result &= "\n"
  for row in qr.rows:
    result &= row.join(", ") & "\n"
  result &= "(" & $qr.rowCount & " rows)"
