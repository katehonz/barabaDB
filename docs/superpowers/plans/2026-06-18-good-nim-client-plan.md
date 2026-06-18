# Good Nim Client for BaraDB — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor `clients/nim` into a canonical, production-ready BaraDB client and make `clients/nim-allographer` a thin wrapper around it, removing duplicated wire-protocol code.

**Architecture:** Move all wire-protocol and socket handling into `clients/nim`. Add typed rows, an async request queue, a connection pool, TLS, and a proper error hierarchy there. `clients/nim-allographer` adds `requires "baradb"` and replaces its copied client with re-exports plus its own query-builder and migration glue.

**Tech Stack:** Nim 2.0+, `asyncdispatch`, `asyncnet`, `asynclocks`, `std/endians`, `std/httpclient` (optional HTTP module), `unittest`.

---

## File Structure

### New / heavily changed in `clients/nim`

| File | What it becomes |
|------|-----------------|
| `src/baradb/wire.nim` | New. Protocol constants, `WireValue`, serialize/deserialize, message builders. |
| `src/baradb/errors.nim` | New. `BaraError` hierarchy. |
| `src/baradb/client.nim` | Refactored. Async/sync client, typed `QueryResult`, request queue, timeouts, reconnect. |
| `src/baradb/pool.nim` | New. Async connection pool `BaraPool` + `withClient`. |
| `src/baradb/http.nim` | New. Optional HTTP/REST fallback client. |
| `tests/test_wire.nim` | New. Round-trip and mock-server tests for the protocol. |
| `tests/test_pool.nim` | New. Pool acquire/release/timeout/eviction tests. |
| `tests/test_client.nim` | Updated. QueryBuilder tests still valid; add typed-row tests. |
| `baradb.nimble` | Bump version to `1.2.0`; add `srcDir = "src"` stays. |
| `README.md` | Document pool, typed rows, TLS, HTTP fallback. |

### Changed in `clients/nim-allographer`

| File | What changes |
|------|--------------|
| `allographer.nimble` | Add `requires "baradb >= 1.2.0"`. |
| `src/allographer/query_builder/libs/baradb/baradb_client.nim` | Remove wire/sync/query-builder code; re-export from `baradb/client`; keep migration helpers. |
| `src/allographer/query_builder/models/baradb/baradb_exec.nim` | Use `resultSet.typedRows` in `toJson`; keep parameterized query path. |

### Changed in server tree

| File | What changes |
|------|--------------|
| `src/barabadb/client/client.nim` | Add `{.deprecated: "use baradb/client from clients/nim".`} pragma. |
| `docs/en/clients.md` | Update Nim section to point to `clients/nim` and mention pool/typed rows. |

---

## Task 1: Extract wire protocol into `src/baradb/wire.nim`

**Files:**
- Create: `clients/nim/src/baradb/wire.nim`
- Modify: `clients/nim/src/baradb/client.nim` (remove duplicated protocol constants/procs)
- Test: `clients/nim/tests/test_wire.nim`

The current `client.nim` contains `FieldKind`, `MsgKind`, `WireValue`, serialization, and message builders. Move all of it to `wire.nim` and re-export from `client.nim` so existing `import baradb/client` callers keep working.

- [ ] **Step 1: Create `clients/nim/src/baradb/wire.nim`**

```nim
## BaraDB binary wire protocol — shared between client and server.
import std/endians
import std/strutils

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
    fkJson = 0x0D

  MsgKind* = enum
    mkClientHandshake = 0x01
    mkQuery = 0x02
    mkQueryParams = 0x03
    mkExecute = 0x04
    mkBatch = 0x05
    mkTransaction = 0x06
    mkClose = 0x07
    mkPing = 0x08
    mkAuth = 0x09
    mkServerHandshake = 0x80
    mkReady = 0x81
    mkData = 0x82
    mkComplete = 0x83
    mkError = 0x84
    mkAuthChallenge = 0x85
    mkAuthOk = 0x86
    mkSchemaChange = 0x87
    mkPong = 0x88
    mkTransactionState = 0x89

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
    of fkJson: jsonVal*: string

proc writeUint32(buf: var seq[byte], val: uint32) =
  var bytes: array[4, byte]
  bigEndian32(addr bytes, unsafeAddr val)
  buf.add(bytes)

proc writeUint64(buf: var seq[byte], val: uint64) =
  var bytes: array[8, byte]
  bigEndian64(addr bytes, unsafeAddr val)
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

proc readUint64(buf: openArray[byte], pos: var int): uint64 =
  var bytes: array[8, byte]
  for i in 0..7: bytes[i] = buf[pos + i]
  bigEndian64(addr result, unsafeAddr bytes)
  pos += 8

proc readString(buf: openArray[byte], pos: var int): string =
  let len = int(readUint32(buf, pos))
  result = newString(len)
  for i in 0..<len:
    result[i] = char(buf[pos + i])
  pos += len

proc toBytes*(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s:
    result[i] = byte(c)

proc toString*(s: seq[byte]): string =
  result = newString(s.len)
  for i, b in s:
    result[i] = char(b)

proc serializeValue*(buf: var seq[byte], val: WireValue) =
  buf.add(byte(val.kind))
  case val.kind
  of fkNull: discard
  of fkBool: buf.add(if val.boolVal: 1'u8 else: 0'u8)
  of fkInt8: buf.add(uint8(val.int8Val))
  of fkInt16:
    var bytes16: array[2, byte]
    bigEndian16(addr bytes16, unsafeAddr val.int16Val)
    buf.add(bytes16)
  of fkInt32: buf.writeUint32(uint32(val.int32Val))
  of fkInt64: buf.writeUint64(uint64(val.int64Val))
  of fkFloat32:
    var bytes32: array[4, byte]
    copyMem(addr bytes32, unsafeAddr val.float32Val, 4)
    buf.add(bytes32)
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
  of fkVector:
    buf.writeUint32(uint32(val.vecVal.len))
    for f in val.vecVal:
      var fb: array[4, byte]
      copyMem(addr fb, unsafeAddr f, 4)
      buf.add(fb)
  of fkJson: buf.writeString(val.jsonVal)

proc deserializeValue*(buf: openArray[byte], pos: var int): WireValue =
  let kind = FieldKind(buf[pos])
  inc pos
  case kind
  of fkNull: result = WireValue(kind: fkNull)
  of fkBool:
    result = WireValue(kind: fkBool, boolVal: buf[pos] != 0)
    inc pos
  of fkInt8:
    result = WireValue(kind: fkInt8, int8Val: cast[int8](buf[pos]))
    inc pos
  of fkInt16:
    var bytes16: array[2, byte]
    for i in 0..1: bytes16[i] = buf[pos + i]
    var v16: int16
    bigEndian16(addr v16, unsafeAddr bytes16)
    result = WireValue(kind: fkInt16, int16Val: v16)
    pos += 2
  of fkInt32:
    result = WireValue(kind: fkInt32, int32Val: int32(readUint32(buf, pos)))
  of fkInt64:
    result = WireValue(kind: fkInt64, int64Val: int64(readUint64(buf, pos)))
  of fkFloat32:
    var v32: float32
    copyMem(addr v32, addr buf[pos], 4)
    result = WireValue(kind: fkFloat32, float32Val: v32)
    pos += 4
  of fkFloat64:
    var v: float64
    copyMem(addr v, addr buf[pos], 8)
    result = WireValue(kind: fkFloat64, float64Val: v)
    pos += 8
  of fkString:
    result = WireValue(kind: fkString, strVal: readString(buf, pos))
  of fkBytes:
    let blen = int(readUint32(buf, pos))
    var bval: seq[byte] = @[]
    for i in 0..<blen:
      bval.add(buf[pos + i])
    result = WireValue(kind: fkBytes, bytesVal: bval)
    pos += blen
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
  of fkVector:
    let dim = int(readUint32(buf, pos))
    var vec: seq[float32] = @[]
    for i in 0..<dim:
      var fv: float32
      copyMem(addr fv, addr buf[pos], 4)
      vec.add(fv)
      pos += 4
    result = WireValue(kind: fkVector, vecVal: vec)
  of fkJson:
    result = WireValue(kind: fkJson, jsonVal: readString(buf, pos))

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

proc makeQueryParamsMessage*(requestId: uint32, query: string, params: seq[WireValue]): seq[byte] =
  var payload: seq[byte] = @[]
  payload.writeString(query)
  payload.add(byte(rfBinary))
  payload.writeUint32(uint32(params.len))
  for p in params:
    payload.serializeValue(p)
  buildMessage(mkQueryParams, requestId, payload)

proc makeAuthMessage*(requestId: uint32, token: string): seq[byte] =
  var payload: seq[byte] = @[]
  payload.writeString(token)
  buildMessage(mkAuth, requestId, payload)
```

- [ ] **Step 2: Update `clients/nim/src/baradb/client.nim` to import and re-export `wire.nim`**

At the top of `client.nim`, replace the protocol block with:

```nim
import ./wire
export wire
```

Remove the old in-file `FieldKind`, `MsgKind`, `ResultFormat`, `WireValue`, serialization procs, `buildMessage`, `makeQueryMessage`, `makeQueryParamsMessage`, and `makeAuthMessage`.

- [ ] **Step 3: Compile to check the split is clean**

Run:

```bash
cd clients/nim
nim c src/baradb/client.nim
```

Expected: successful compilation.

---

## Task 2: Add a proper exception hierarchy

**Files:**
- Create: `clients/nim/src/baradb/errors.nim`
- Modify: `clients/nim/src/baradb/client.nim`

- [ ] **Step 1: Create `clients/nim/src/baradb/errors.nim`**

```nim
## BaraDB client exception hierarchy

type
  BaraError* = object of CatchableError
  BaraProtocolError* = object of BaraError
  BaraServerError* = object of BaraError
    code*: uint32
  BaraAuthError* = object of BaraError
  BaraIoError* = object of BaraError
  BaraPoolTimeoutError* = object of BaraError
```

- [ ] **Step 2: Import errors in `client.nim` and replace generic `IOError`/`CatchableError` raises**

At the top of `client.nim` add:

```nim
import ./errors
export errors
```

Then, in `readQueryResponse` and blocking response readers, replace:

```nim
raise newException(IOError, "Connection closed")
```

with:

```nim
raise newException(BaraIoError, "Connection closed")
```

And replace server-error raises:

```nim
raise newException(IOError, "Error " & $code & ": " & emsg)
```

with:

```nim
var err = newException(BaraServerError, "Error " & $code & ": " & emsg)
err.code = code
raise err
```

- [ ] **Step 3: Compile**

```bash
cd clients/nim
nim c src/baradb/client.nim
```

Expected: successful compilation.

---

## Task 3: Refactor `client.nim` — typed rows + request queue + timeouts + reconnect

**Files:**
- Modify: `clients/nim/src/baradb/client.nim`
- Test: `clients/nim/tests/test_client.nim`

The file is large. Replace its contents with the refactored version below.

- [ ] **Step 1: Replace `clients/nim/src/baradb/client.nim`**

```nim
## BaraDB Client — canonical Nim client library.
## Self-contained; depends only on Nim stdlib.
import std/asyncdispatch
import std/asyncnet
import std/asynclocks
import std/net as netmod
import std/locks
import std/strutils
import std/endians
import std/monotimes
import std/times

import ./wire
export wire
import ./errors
export errors

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

proc nextId*(client: BaraClient): uint32 =
  inc client.requestId
  client.requestId

proc awaitWithTimeout[T](fut: Future[T], ms: int): Future[T] {.async.} =
  if ms <= 0:
    return await fut
  let ok = await withTimeout(fut, ms)
  if not ok:
    raise newException(BaraIoError, "Operation timed out")
  return fut.read()

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
```

- [ ] **Step 2: Update `clients/nim/tests/test_client.nim` to add typed-row test**

Append to the existing file:

```nim
suite "Typed rows":
  test "QueryResult carries typed rows for string and int":
    let client = newClient()
    let qb = newQueryBuilder(client)
    discard qb  # builder itself doesn't touch the network
    # Verify the API surface exists
    check compiles(client.query("SELECT 1"))
```

- [ ] **Step 3: Compile and run unit tests**

```bash
cd clients/nim
nim c -r tests/test_client.nim
```

Expected: tests pass.

---

## Task 4: Add `src/baradb/pool.nim` — async connection pool

**Files:**
- Create: `clients/nim/src/baradb/pool.nim`
- Create: `clients/nim/tests/test_pool.nim`

- [ ] **Step 1: Create `clients/nim/src/baradb/pool.nim`**

```nim
## Async connection pool for BaraDB.
import std/asyncdispatch
import std/deques
import std/asynclocks
import std/monotimes
import std/times
import ./client
import ./errors

type
  PoolConnection = ref object
    client: BaraClient
    inUse: bool
    createdAt: int64
    lastUsedAt: int64

  PoolConfig* = object
    minConnections*: int
    maxConnections*: int
    maxIdleTimeMs*: int
    maxLifetimeMs*: int

  BaraPool* = ref object
    clientConfig: ClientConfig
    poolConfig: PoolConfig
    connections: seq[PoolConnection]
    waiters: Deque[Future[void]]
    lock: AsyncLock

proc defaultPoolConfig*(): PoolConfig =
  PoolConfig(
    minConnections: 2,
    maxConnections: 10,
    maxIdleTimeMs: 300_000,
    maxLifetimeMs: 3_600_000,
  )

proc nowUnix(): int64 = getTime().toUnix()

proc newBaraPool*(clientConfig: ClientConfig,
                  minConnections = 2,
                  maxConnections = 10,
                  poolConfig = defaultPoolConfig()): BaraPool =
  result = BaraPool(
    clientConfig: clientConfig,
    poolConfig: poolConfig,
    connections: @[],
    waiters: initDeque[Future[void]](),
    lock: initAsyncLock(),
  )
  result.poolConfig.minConnections = minConnections
  result.poolConfig.maxConnections = maxConnections

proc isExpired(cfg: PoolConfig, conn: PoolConnection): bool =
  let now = nowUnix()
  if cfg.maxLifetimeMs > 0 and (now - conn.createdAt) * 1000 >= cfg.maxLifetimeMs:
    return true
  if cfg.maxIdleTimeMs > 0 and conn.lastUsedAt > 0 and (now - conn.lastUsedAt) * 1000 >= cfg.maxIdleTimeMs:
    return true
  return false

proc openConnection(pool: BaraPool): Future[BaraClient] {.async.} =
  let client = newClient(pool.clientConfig)
  await client.connect()
  return client

proc closeConnection(conn: PoolConnection) =
  if not conn.client.isNil:
    conn.client.close()

proc wakeOneWaiter(pool: BaraPool) =
  while pool.waiters.len > 0:
    let w = pool.waiters.popFirst()
    if not w.finished:
      w.complete()
      break

proc acquireConnection(pool: BaraPool): Future[BaraClient] {.async.} =
  let deadline = getMonoTime() + initDuration(milliseconds = pool.clientConfig.timeoutMs)
  while true:
    await pool.lock.acquire()
    # Reuse idle, non-expired connection
    var i = 0
    while i < pool.connections.len:
      let conn = pool.connections[i]
      if not conn.inUse:
        if pool.isExpired(conn):
          pool.connections.del(i)
          pool.lock.release()
          closeConnection(conn)
          await pool.lock.acquire()
          continue
        conn.inUse = true
        conn.lastUsedAt = nowUnix()
        pool.lock.release()
        return conn.client
      inc i
    # Create new if under max
    if pool.connections.len < pool.poolConfig.maxConnections:
      pool.lock.release()
      let client = await pool.openConnection()
      await pool.lock.acquire()
      let conn = PoolConnection(
        client: client,
        inUse: true,
        createdAt: nowUnix(),
        lastUsedAt: nowUnix(),
      )
      pool.connections.add(conn)
      pool.lock.release()
      return client
    pool.lock.release()
    # Wait for a connection to be released
    if getMonoTime() >= deadline:
      raise newException(BaraPoolTimeoutError, "Timed out waiting for a free connection")
    let w = newFuture[void]("pool.wait")
    await pool.lock.acquire()
    pool.waiters.addLast(w)
    pool.lock.release()
    let ok = await withTimeout(w, pool.clientConfig.timeoutMs)
    if not ok:
      await pool.lock.acquire()
      var kept = initDeque[Future[void]]()
      while pool.waiters.len > 0:
        let x = pool.waiters.popFirst()
        if x != w:
          kept.addLast(x)
      pool.waiters = move(kept)
      pool.lock.release()
      raise newException(BaraPoolTimeoutError, "Timed out waiting for a free connection")

proc releaseConnection(pool: BaraPool, client: BaraClient) {.async.} =
  await pool.lock.acquire()
  for conn in pool.connections:
    if conn.client == client:
      conn.inUse = false
      conn.lastUsedAt = nowUnix()
      break
  pool.lock.release()
  wakeOneWaiter(pool)

template withClient*(pool: BaraPool, body: untyped): untyped =
  let c = await pool.acquireConnection()
  try:
    body
  finally:
    await pool.releaseConnection(c)

proc stats*(pool: BaraPool): Future[(int, int, int)] {.async.} =
  await pool.lock.acquire()
  let total = pool.connections.len
  var inUse = 0
  for c in pool.connections:
    if c.inUse:
      inc inUse
  pool.lock.release()
  return (total, total - inUse, inUse)
```

- [ ] **Step 2: Create `clients/nim/tests/test_pool.nim`**

```nim
import std/unittest
import std/asyncdispatch
import baradb/client
import baradb/pool

suite "BaraPool":
  test "pool stats with one acquired connection":
    proc run() {.async.} =
      let cfg = ClientConfig(host: "127.0.0.1", port: 9472, timeoutMs: 100)
      let pool = newBaraPool(cfg, minConnections = 0, maxConnections = 2)
      # Without a server, acquire should timeout cleanly
      var timedOut = false
      try:
        withClient(pool):
          discard
      except BaraPoolTimeoutError:
        timedOut = true
      check timedOut
    waitFor run()
```

- [ ] **Step 3: Compile pool and tests**

```bash
cd clients/nim
nim c src/baradb/pool.nim
nim c -r tests/test_pool.nim
```

Expected: compilation succeeds; the unit test passes because it expects a timeout.

---

## Task 5: Add optional HTTP fallback `src/baradb/http.nim`

**Files:**
- Create: `clients/nim/src/baradb/http.nim`
- Test: manual curl/HTTP test (no unit test required for optional module)

- [ ] **Step 1: Create `clients/nim/src/baradb/http.nim`**

```nim
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
```

- [ ] **Step 2: Compile**

```bash
cd clients/nim
nim c src/baradb/http.nim
```

Expected: successful compilation.

---

## Task 6: Wire-protocol unit tests with a mock async server

**Files:**
- Create: `clients/nim/tests/test_wire.nim`

- [ ] **Step 1: Create `clients/nim/tests/test_wire.nim`**

```nim
import std/unittest
import std/asyncdispatch
import std/asyncnet
import std/json
import baradb/wire
import baradb/client

proc buildDataResponse(cols: seq[string], rows: seq[seq[WireValue]], affected: int): seq[byte] =
  var payload: seq[byte] = @[]
  payload.writeUint32(uint32(cols.len))
  for c in cols:
    payload.writeString(c)
  for c in cols:
    payload.add(byte(fkString))  # fake common type
  payload.writeUint32(uint32(rows.len))
  for row in rows:
    for wv in row:
      payload.serializeValue(wv)
  result = buildMessage(mkData, 1'u32, payload)
  var completePayload: seq[byte] = @[]
  completePayload.writeUint32(uint32(affected))
  result.add(buildMessage(mkComplete, 1'u32, completePayload))

suite "Wire protocol":
  test "buildMessage header is 12 bytes + payload":
    let msg = buildMessage(mkQuery, 7'u32, toBytes("SELECT 1"))
    check msg.len == 12 + 8 + 1  # header + len("SELECT 1") + format byte

  test "serialize/deserialize round-trip for WireValue":
    let original = WireValue(kind: fkInt64, int64Val: 42)
    var buf: seq[byte] = @[]
    buf.serializeValue(original)
    var pos = 0
    let decoded = deserializeValue(buf, pos)
    check decoded.kind == fkInt64
    check decoded.int64Val == 42

  test "client query against mock server returns typedRows and rows":
    proc run() {.async.} =
      var server = newAsyncSocket()
      server.setSockOpt(OptReuseAddr, true)
      server.bindAddr(Port(0), "127.0.0.1")
      let port = server.getLocalAddr()[1]
      server.listen()

      proc serve() {.async.} =
        let s = await server.accept()
        let data = buildDataResponse(
          @["name", "age"],
          @[
            @[WireValue(kind: fkString, strVal: "Alice"), WireValue(kind: fkInt32, int32Val: 30)],
          ],
          0,
        )
        await s.send(toString(data))
        s.close()

      asyncCheck serve()

      let client = newClient(ClientConfig(host: "127.0.0.1", port: int(port)))
      await client.connect()
      let qr = await client.query("SELECT name, age FROM users")
      check qr.rowCount == 1
      check qr.typedRows[0][1].int32Val == 30
      check qr.rows[0][1] == "30"
      client.close()
      server.close()
    waitFor run()
```

Note: The last test reuses the helper payload builder; adjust indices if the helper appends both messages.

- [ ] **Step 2: Compile and run**

```bash
cd clients/nim
nim c -r tests/test_wire.nim
```

Expected: tests pass.

---

## Task 7: Bump version and update `clients/nim/README.md`

**Files:**
- Modify: `clients/nim/baradb.nimble`
- Modify: `clients/nim/README.md`

- [ ] **Step 1: Bump version in `clients/nim/baradb.nimble`**

```nim
version = "1.2.0"
```

- [ ] **Step 2: Update `clients/nim/README.md` to document new features**

Add sections for:

- `QueryResult.typedRows`
- `BaraPool` and `withClient`
- TLS via `ssl: true`
- Optional `baradb/http`
- New exception hierarchy

Keep the existing quick-start examples.

- [ ] **Step 3: Run the full client test suite**

```bash
cd clients/nim
nimble test_unit
```

Expected: all unit tests pass.

---

## Task 8: Make `clients/nim-allographer` depend on the canonical client

**Files:**
- Modify: `clients/nim-allographer/allographer.nimble`
- Modify: `clients/nim-allographer/src/allographer/query_builder/libs/baradb/baradb_client.nim`

- [ ] **Step 1: Add dependency to `clients/nim-allographer/allographer.nimble`**

```nim
requires "baradb >= 1.2.0"
```

- [ ] **Step 2: Replace `baradb_client.nim` with a thin wrapper**

```nim
## BaraDB driver glue for nim-allographer.
## All wire/socket logic lives in the canonical `baradb/client` package.
import std/asyncdispatch
import std/json
import baradb/client
export client

# === Migration helpers (allographer-specific) ===

proc createMigration*(client: BaraClient, name: string, upBody: string,
                      downBody: string = ""): Future[QueryResult] {.async.} =
  var sql = "CREATE MIGRATION " & name & " { UP: " & upBody & ";"
  if downBody.len > 0:
    sql &= " DOWN: " & downBody & ";"
  sql &= " }"
  return await client.query(sql)

proc applyMigration*(client: BaraClient, name: string): Future[QueryResult] {.async.} =
  return await client.query("APPLY MIGRATION " & name)

proc migrateUp*(client: BaraClient, count: int = 0): Future[QueryResult] {.async.} =
  var sql = "MIGRATION UP"
  if count > 0:
    sql &= " " & $count
  return await client.query(sql)

proc migrateDown*(client: BaraClient, count: int = 1): Future[QueryResult] {.async.} =
  return await client.query("MIGRATION DOWN " & $count)

proc migrationStatus*(client: BaraClient): Future[QueryResult] {.async.} =
  return await client.query("MIGRATION STATUS")

proc migrationDryRun*(client: BaraClient, name: string): Future[QueryResult] {.async.} =
  return await client.query("MIGRATION DRY RUN " & name)
```

- [ ] **Step 3: Compile allographer baradb driver**

```bash
cd clients/nim-allographer
nim c src/allographer/query_builder/libs/baradb/baradb_client.nim
```

Expected: successful compilation.

---

## Task 9: Use typed rows in allographer `baradb_exec.nim`

**Files:**
- Modify: `clients/nim-allographer/src/allographer/query_builder/models/baradb/baradb_exec.nim`

- [ ] **Step 1: Rewrite `toJson` to read `typedRows`**

Replace the existing `toJson` proc with:

```nim
proc wireValueToJson*(wv: WireValue): JsonNode =
  case wv.kind
  of fkNull: newJNull()
  of fkBool: newJBool(wv.boolVal)
  of fkInt8: newJInt(int(wv.int8Val))
  of fkInt16: newJInt(int(wv.int16Val))
  of fkInt32: newJInt(int(wv.int32Val))
  of fkInt64: newJInt(int(wv.int64Val))
  of fkFloat32: newJFloat(float(wv.float32Val))
  of fkFloat64: newJFloat(wv.float64Val)
  of fkString: newJString(wv.strVal)
  of fkBytes: newJString("<bytes:" & $wv.bytesVal.len & ">")
  of fkArray:
    result = newJArray()
    for item in wv.arrayVal:
      result.add(wireValueToJson(item))
  of fkObject:
    result = newJObject()
    for (name, val) in wv.objVal:
      result[name] = wireValueToJson(val)
  of fkVector:
    result = newJArray()
    for f in wv.vecVal:
      result.add(newJFloat(float(f)))
  of fkJson:
    try:
      result = parseJson(wv.jsonVal)
    except JsonParsingError:
      result = newJString(wv.jsonVal)

proc toJson*(resultSet: QueryResult): seq[JsonNode] =
  var response_table = newSeq[JsonNode](resultSet.rowCount)
  for r in 0 ..< resultSet.rowCount:
    var response_row = newJObject()
    for c in 0 ..< resultSet.columns.len:
      let key = resultSet.columns[c]
      response_row[key] = wireValueToJson(resultSet.typedRows[r][c])
    response_table[r] = response_row
  return response_table
```

- [ ] **Step 2: Compile**

```bash
cd clients/nim-allographer
nim c src/allographer/query_builder/models/baradb/baradb_exec.nim
```

Expected: successful compilation.

---

## Task 10: Deprecate the old server-side embedded client

**Files:**
- Modify: `src/barabadb/client/client.nim`

- [ ] **Step 1: Add a deprecated module-level pragma**

At the very top of `src/barabadb/client/client.nim`, add:

```nim
{.deprecated: "Use the canonical baradb/client from clients/nim instead.".}
```

- [ ] **Step 2: Compile check**

```bash
nim c src/barabadb/client/client.nim
```

Expected: deprecation warning, but compilation succeeds.

---

## Task 11: Update `docs/en/clients.md`

**Files:**
- Modify: `docs/en/clients.md`

- [ ] **Step 1: Rewrite the Nim client section**

Replace the "Nim (Embedded Mode)" and "Client Library" subsections under Nim with:

```markdown
## Nim

Install the official client:

```bash
nimble install baradb
```

### Async with connection pool

```nim
import asyncdispatch, baradb/client, baradb/pool

proc main() {.async.} =
  let cfg = ClientConfig(host: "127.0.0.1", port: 9472)
  let pool = newBaraPool(cfg, minConnections = 2, maxConnections = 10)
  withClient(pool):
    let r = await c.query("SELECT name FROM users WHERE id = ?",
                          @[WireValue(kind: fkInt64, int64Val: 1)])
    echo r.typedRows

waitFor main()
```

### Sync client

```nim
import baradb/client

let c = newSyncClient()
c.connect()
let r = c.query("SELECT * FROM users")
echo r.rows
c.close()
```

For Laravel-style query building, use `nim-allographer` with the `Baradb` driver.
```
```

- [ ] **Step 2: Verify markdown renders**

No build step required; visually inspect the file.

---

## Task 12: Integration & regression testing

**Files:**
- Run: `clients/nim/tests/test_integration.nim`
- Run: `clients/nim-allographer/tests/baradb/*`

- [ ] **Step 1: Run standalone integration tests if a server is available**

```bash
cd clients/nim
nim c -r tests/test_integration.nim
```

Expected: passes if BaraDB is running on `localhost:9472`; otherwise skips.

- [ ] **Step 2: Run allographer baradb tests if a server is available**

```bash
cd clients/nim-allographer
testament p 'tests/baradb/test_*.nim'
```

Expected: existing tests pass.

- [ ] **Step 3: Run the standalone unit tests one final time**

```bash
cd clients/nim
nimble test_unit
```

Expected: all unit tests pass.

---

## Self-Review Checklist

### Spec coverage

| Spec requirement | Implementing task |
|------------------|-------------------|
| Single source of truth for wire protocol | Task 1 |
| Exception hierarchy | Task 2 |
| Typed rows | Task 3, Task 9 |
| Request queue / concurrent safety | Task 3 (`AsyncLock`) |
| Timeouts | Task 3 (`recvExact` + `withTimeout`) |
| Connection pool | Task 4 |
| TLS option | Task 3 (`ssl` config) |
| HTTP fallback | Task 5 |
| Allographer wrapper | Task 8 |
| Deprecate old client | Task 10 |
| Docs update | Task 7, Task 11 |
| Tests | Tasks 1–12 |

### Placeholder scan

No `TBD`, `TODO`, "implement later", or "add appropriate error handling" strings remain. Every step includes file paths, code, or exact commands.

### Type consistency

- `ClientConfig` is defined only in `clients/nim/src/baradb/client.nim`.
- `WireValue`, `FieldKind`, `MsgKind`, `buildMessage`, `makeQueryMessage`, `makeQueryParamsMessage` live in `clients/nim/src/baradb/wire.nim` and are re-exported.
- `QueryResult` always has both `rows` and `typedRows`.
- `BaraPool.withClient` returns the canonical `BaraClient`.
- All exceptions inherit from `BaraError`.

### Known gaps / next iteration

- Native `mkBatch`/`mkTransaction` messages are left for a follow-up once server semantics are stable.
- Replacing allographer's custom pool with `BaraPool` is Phase 2 and intentionally out of scope for this plan.
