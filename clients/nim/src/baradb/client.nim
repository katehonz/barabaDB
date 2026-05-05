## BaraDB Client — Self-contained Nim client library
## No dependency on BaraDB server code.
## Communicates via the BaraDB Wire Protocol (binary, big-endian).

import std/asyncdispatch
import std/asyncnet
import std/strutils
import std/endians

# === Wire Protocol (self-contained, no server dependency) ===

const
  ProtocolMagic* = 0x42415241'u32

type
  FieldKind* = enum
    fkNull = 0x00
    fkBool = 0x01
    fkInt8 = 0x02
    fkInt16 = 0x03
    fkInt32 = 0x04
    fkInt64 = 0x05
    fkFloat32 = 0x06
    fkFloat64 = 0x07
    fkString = 0x08
    fkBytes = 0x09
    fkArray = 0x0A
    fkObject = 0x0B
    fkVector = 0x0C

  MsgKind* = enum
    mkClientHandshake = 0x01
    mkQuery = 0x02
    mkBatch = 0x05
    mkPing = 0x08
    mkAuth = 0x09
    # Server
    mkReady = 0x81
    mkData = 0x82
    mkComplete = 0x83
    mkError = 0x84
    mkPong = 0x88

  ResultFormat* = enum
    rfBinary = 0x00
    rfJson = 0x01
    rfText = 0x02

  WireValue* = object
    case kind*: FieldKind
    of fkNull: discard
    of fkBool: boolVal*: bool
    of fkInt8: int8Val*: int8
    of fkInt16: int16Val*: int16
    of fkInt32: int32Val*: int32
    of fkInt64: int64Val*: int64
    of fkFloat32: float32Val*: float32
    of fkFloat64: float64Val*: float64
    of fkString: strVal*: string
    of fkBytes: bytesVal*: seq[byte]
    of fkArray: arrayVal*: seq[WireValue]
    of fkObject: objVal*: seq[(string, WireValue)]
    of fkVector: vecVal*: seq[float32]

proc writeUint32(buf: var seq[byte], val: uint32) =
  var bytes: array[4, byte]
  bigEndian32(addr bytes, unsafeAddr val)
  buf.add(bytes)

proc writeString(buf: var seq[byte], s: string) =
  buf.writeUint32(uint32(s.len))
  for ch in s:
    buf.add(byte(ch))

proc readUint32(buf: openArray[byte], pos: var int): uint32 =
  var bytes: array[4, byte]
  for i in 0..3: bytes[i] = buf[pos + i]
  bigEndian32(addr result, unsafeAddr bytes)
  pos += 4

proc readString(buf: openArray[byte], pos: var int): string =
  let len = int(readUint32(buf, pos))
  result = newString(len)
  for i in 0..<len:
    result[i] = char(buf[pos + i])
  pos += len

proc serializeValue*(buf: var seq[byte], val: WireValue) =
  buf.add(byte(val.kind))
  case val.kind
  of fkNull: discard
  of fkBool: buf.add(if val.boolVal: 1'u8 else: 0'u8)
  of fkInt32: buf.writeUint32(uint32(val.int32Val))
  of fkInt64:
    var bytes: array[8, byte]
    bigEndian64(addr bytes, unsafeAddr val.int64Val)
    buf.add(bytes)
  of fkFloat64:
    var bytes: array[8, byte]
    copyMem(addr bytes, unsafeAddr val.float64Val, 8)
    buf.add(bytes)
  of fkString: buf.writeString(val.strVal)
  of fkBytes:
    buf.writeUint32(uint32(val.bytesVal.len))
    buf.add(val.bytesVal)
  of fkArray:
    buf.writeUint32(uint32(val.arrayVal.len))
    for item in val.arrayVal:
      buf.serializeValue(item)
  of fkObject:
    buf.writeUint32(uint32(val.objVal.len))
    for (name, item) in val.objVal:
      buf.writeString(name)
      buf.serializeValue(item)
  else: discard

proc deserializeValue*(buf: openArray[byte], pos: var int): WireValue =
  let kind = FieldKind(buf[pos])
  inc pos
  case kind
  of fkNull: result = WireValue(kind: fkNull)
  of fkBool:
    result = WireValue(kind: fkBool, boolVal: buf[pos] != 0)
    inc pos
  of fkInt32:
    result = WireValue(kind: fkInt32, int32Val: int32(readUint32(buf, pos)))
  of fkInt64:
    var bytes: array[8, byte]
    for i in 0..7: bytes[i] = buf[pos + i]
    var v: int64
    bigEndian64(addr v, unsafeAddr bytes)
    result = WireValue(kind: fkInt64, int64Val: v)
    pos += 8
  of fkFloat64:
    var v: float64
    copyMem(addr v, addr buf[pos], 8)
    result = WireValue(kind: fkFloat64, float64Val: v)
    pos += 8
  of fkString:
    result = WireValue(kind: fkString, strVal: readString(buf, pos))
  of fkArray:
    let count = int(readUint32(buf, pos))
    var arr: seq[WireValue] = @[]
    for i in 0..<count:
      arr.add(deserializeValue(buf, pos))
    result = WireValue(kind: fkArray, arrayVal: arr)
  of fkObject:
    let count = int(readUint32(buf, pos))
    var obj: seq[(string, WireValue)] = @[]
    for i in 0..<count:
      let name = readString(buf, pos)
      let val = deserializeValue(buf, pos)
      obj.add((name, val))
    result = WireValue(kind: fkObject, objVal: obj)
  else:
    result = WireValue(kind: fkNull)

proc buildMessage*(kind: MsgKind, requestId: uint32, payload: seq[byte]): seq[byte] =
  result = @[]
  result.writeUint32(uint32(kind))
  result.writeUint32(uint32(payload.len))
  result.writeUint32(requestId)
  result.add(payload)

proc makeQueryMessage*(requestId: uint32, query: string): seq[byte] =
  var payload: seq[byte] = @[]
  payload.writeString(query)
  payload.add(byte(rfBinary))
  buildMessage(mkQuery, requestId, payload)

# === Client Library ===

type
  ClientConfig* = object
    host*: string
    port*: int
    database*: string
    username*: string
    password*: string
    timeoutMs*: int
    maxRetries*: int

  QueryResult* = object
    columns*: seq[string]
    rows*: seq[seq[string]]
    rowCount*: int
    affectedRows*: int
    executionTimeMs*: float64

  BaraClient* = ref object
    config: ClientConfig
    socket: AsyncSocket
    connected: bool
    requestId: uint32

proc defaultConfig*(): ClientConfig =
  ClientConfig(
    host: "127.0.0.1", port: 5432, database: "default",
    username: "admin", password: "", timeoutMs: 30000, maxRetries: 3,
  )

proc newClient*(config: ClientConfig = defaultConfig()): BaraClient =
  BaraClient(config: config, socket: newAsyncSocket(), connected: false, requestId: 0)

proc connect*(client: BaraClient) {.async.} =
  await client.socket.connect(client.config.host, Port(client.config.port))
  client.connected = true

proc close*(client: BaraClient) =
  if client.connected:
    client.socket.close()
    client.connected = false

proc isConnected*(client: BaraClient): bool = client.connected

proc nextId(client: BaraClient): uint32 =
  inc client.requestId; client.requestId

proc query*(client: BaraClient, sql: string): Future[QueryResult] {.async.} =
  if not client.connected:
    raise newException(IOError, "Not connected")

  let msg = makeQueryMessage(client.nextId(), sql)
  await client.socket.send(cast[string](msg))

  # Read header: kind(4) + length(4) + requestId(4) = 12 bytes
  let headerData = await client.socket.recv(12)
  if headerData.len < 12:
    raise newException(IOError, "Connection closed")

  var pos = 0
  let hdrData = cast[seq[byte]](headerData)
  let kind = MsgKind(readUint32(hdrData, pos))
  let payloadLen = int(readUint32(hdrData, pos))
  let reqId = readUint32(hdrData, pos)

  # Read payload
  let payloadStr = await client.socket.recv(payloadLen)
  var payload = cast[seq[byte]](payloadStr)

  result = QueryResult(columns: @[], rows: @[], rowCount: 0, affectedRows: 0)

  if kind == mkReady:
    return
  if kind == mkError and payload.len >= 8:
    var epos = 0
    let code = readUint32(payload, epos)
    let emsg = readString(payload, epos)
    raise newException(IOError, "Error " & $code & ": " & emsg)
  if kind == mkComplete:
    var rpos = 0
    result.affectedRows = int(readUint32(payload, rpos))
    return

proc exec*(client: BaraClient, sql: string): Future[int] {.async.} =
  let qr = await client.query(sql)
  return qr.affectedRows

proc ping*(client: BaraClient) {.async.} =
  if not client.connected: return
  let msg = buildMessage(mkPing, client.nextId(), @[])
  await client.socket.send(cast[string](msg))

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

# === Sync Wrapper ===

type
  SyncClient* = ref object
    asyncClient: BaraClient

proc newSyncClient*(config: ClientConfig = defaultConfig()): SyncClient =
  SyncClient(asyncClient: newClient(config))

proc connect*(client: SyncClient) =
  waitFor client.asyncClient.connect()

proc close*(client: SyncClient) =
  client.asyncClient.close()

proc query*(client: SyncClient, sql: string): QueryResult =
  waitFor client.asyncClient.query(sql)

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
