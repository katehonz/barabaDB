## BaraDB Server — async TCP server with wire protocol
import std/asyncdispatch
import std/asyncnet
import std/strutils
import std/tables
import std/os
import std/endians
import std/monotimes
import config
import logging
import ../protocol/wire
import ../protocol/ssl
import ../query/lexer
import ../query/parser
import ../query/ast
import ../query/executor
import ../storage/lsm
import ../core/mvcc

type
  Server* = ref object
    config*: BaraConfig
    running*: bool
    db*: LSMTree
    ctx*: ExecutionContext
    txnManager*: TxnManager
    tls*: TLSContext
    activeConnections*: int

  ClientConnection = ref object
    socket: AsyncSocket
    id: int
    currentTxn: Transaction

proc newServer*(config: BaraConfig): Server =
  let dataDir = config.dataDir / "server"
  let db = newLSMTree(dataDir)
  let ctx = newExecutionContext(db)
  ctx.txnManager = newTxnManager()
  var tls: TLSContext = nil
  if config.tlsEnabled and config.certFile.len > 0 and config.keyFile.len > 0:
    let tlsConfig = newTLSConfig(config.certFile, config.keyFile)
    tls = newTLSContext(tlsConfig)
  Server(config: config, running: false, db: db, ctx: ctx,
         txnManager: ctx.txnManager, tls: tls)

# ----------------------------------------------------------------------
# Wire Protocol Helpers
# ----------------------------------------------------------------------

proc readUint32BE(data: string, pos: int): uint32 =
  var bytes: array[4, byte]
  for i in 0..3:
    bytes[i] = byte(data[pos + i])
  bigEndian32(addr result, unsafeAddr bytes)

proc writeUint32BE(val: uint32): array[4, byte] =
  bigEndian32(addr result, unsafeAddr val)

proc writeUint64BE(val: uint64): array[8, byte] =
  bigEndian64(addr result, unsafeAddr val)

proc parseHeader(data: string): (bool, MessageHeader) =
  if data.len < 12:
    return (false, MessageHeader())
  let kind = MsgKind(readUint32BE(data, 0))
  let length = readUint32BE(data, 4)
  let requestId = readUint32BE(data, 8)
  return (true, MessageHeader(kind: kind, length: length, requestId: requestId))

# ----------------------------------------------------------------------
# Query Execution (pipeline-based)
# ----------------------------------------------------------------------

proc valueToWire(val: string, colType: string): WireValue =
  if val.len == 0 or val.toLower() == "null":
    return WireValue(kind: fkNull)
  let t = colType.toUpper()
  if t.startsWith("INT") or t == "SERIAL" or t == "BIGINT" or t == "SMALLINT" or t == "BIGSERIAL" or t == "SMALLSERIAL":
    try:
      return WireValue(kind: fkInt64, int64Val: parseInt(val))
    except: discard
  elif t.startsWith("FLOAT") or t == "REAL" or t == "DOUBLE" or t == "NUMERIC" or t.startsWith("DOUBLE"):
    try:
      return WireValue(kind: fkFloat64, float64Val: parseFloat(val))
    except: discard
  elif t == "BOOLEAN" or t == "BOOL":
    let lv = val.toLower()
    if lv in ["true", "t", "yes", "1"]:
      return WireValue(kind: fkBool, boolVal: true)
    elif lv in ["false", "f", "no", "0"]:
      return WireValue(kind: fkBool, boolVal: false)
  return WireValue(kind: fkString, strVal: val)

proc executeQuery(db: LSMTree, ctx: ExecutionContext, query: string, params: seq[WireValue] = @[]): (bool, QueryResult, string) =
  try:
    let tokens = tokenize(query)
    let astNode = parse(tokens)

    if astNode.stmts.len == 0:
      return (true, QueryResult(), "")

    let result = executor.executeQuery(ctx, astNode, params)
    if result.success:
      var qr = QueryResult(affectedRows: result.affectedRows, rowCount: result.rows.len)
      qr.columns = result.columns

      var colTypes: seq[string] = @[]
      var tableName = ""
      if astNode.stmts[0].kind == nkSelect and astNode.stmts[0].selFrom != nil:
        tableName = astNode.stmts[0].selFrom.fromTable
      elif astNode.stmts[0].kind == nkInsert:
        tableName = astNode.stmts[0].insTarget
      elif astNode.stmts[0].kind == nkUpdate:
        tableName = astNode.stmts[0].updTarget

      if tableName.len > 0 and tableName in ctx.tables:
        let tbl = ctx.tables[tableName]
        for col in result.columns:
          var found = ""
          for c in tbl.columns:
            if c.name.toLower() == col.toLower():
              found = c.colType
              break
          colTypes.add(found)
      else:
        colTypes = newSeq[string](result.columns.len)

      qr.columnTypes = newSeq[FieldKind](result.columns.len)
      qr.rows = @[]
      for row in result.rows:
        var wireRow: seq[WireValue] = @[]
        for i, col in result.columns:
          let val = if col in row: row[col] else: ""
          let cType = if i < colTypes.len: colTypes[i] else: ""
          wireRow.add(valueToWire(val, cType))
        qr.rows.add(wireRow)
      return (true, qr, result.message)
    else:
      return (false, QueryResult(), result.message)
  except Exception as e:
    return (false, QueryResult(), e.msg)

# ----------------------------------------------------------------------
# Response Serialization
# ----------------------------------------------------------------------

proc serializeResult(qr: QueryResult, requestId: uint32): seq[byte] =
  # Serialize as Data message
  var payload: seq[byte] = @[]
  # Column count
  payload.writeUint32(uint32(qr.columns.len))
  # Column names
  for col in qr.columns:
    payload.writeString(col)
  # Row count
  payload.writeUint32(uint32(qr.rows.len))
  # Rows
  for row in qr.rows:
    for val in row:
      payload.serializeValue(val)

  var msg = WireMessage(
    header: MessageHeader(kind: mkData, length: uint32(payload.len), requestId: requestId),
    payload: payload,
  )
  return serializeMessage(msg)

proc serializeComplete(affectedRows: int, requestId: uint32): seq[byte] =
  var payload: seq[byte] = @[]
  payload.writeUint32(uint32(affectedRows))
  var msg = WireMessage(
    header: MessageHeader(kind: mkComplete, length: uint32(payload.len), requestId: requestId),
    payload: payload,
  )
  return serializeMessage(msg)

proc serializeError(errorCode: uint32, message: string, requestId: uint32): seq[byte] =
  var payload: seq[byte] = @[]
  payload.writeUint32(errorCode)
  payload.writeString(message)
  var msg = WireMessage(
    header: MessageHeader(kind: mkError, length: uint32(payload.len), requestId: requestId),
    payload: payload,
  )
  return serializeMessage(msg)

# ----------------------------------------------------------------------
# Client Handler
# ----------------------------------------------------------------------

proc recvExact(client: AsyncSocket, size: int): Future[string] {.async.} =
  var buf = ""
  while buf.len < size:
    let chunk = await client.recv(size - buf.len)
    if chunk.len == 0:
      break
    buf.add(chunk)
  return buf

proc recvExactWithTimeout(client: AsyncSocket, size: int, timeoutMs: int): Future[string] {.async.} =
  if timeoutMs <= 0:
    return await client.recvExact(size)
  let fut = client.recvExact(size)
  let ok = await withTimeout(fut, timeoutMs)
  if ok:
    return fut.read()

proc slowQueryLog(logPath: string, query: string, durationMs: int, clientId: int) =
  if logPath.len == 0:
    return
  try:
    let f = open(logPath, fmAppend)
    defer: f.close()
    let line = $getMonoTime().ticks() & " | " & $clientId & " | " & $durationMs & "ms | " & query & "\n"
    f.write(line)
  except: discard

proc handleClient(server: Server, client: AsyncSocket, clientId: int) {.async.} =
  info("Client " & $clientId & " connected")
  var connCtx = cloneForConnection(server.ctx)
  let idleTimeout = server.config.idleTimeoutMs
  let queryTimeout = server.config.queryTimeoutMs
  let slowThreshold = server.config.slowQueryThresholdMs
  let slowLog = server.config.slowQueryLogPath

  try:
    while true:
      let headerData = await client.recvExactWithTimeout(12, idleTimeout)
      if headerData.len < 12:
        break

      let (ok, header) = parseHeader(headerData)
      if not ok:
        break

      var payload = ""
      if header.length > 0:
        payload = await client.recvExactWithTimeout(int(header.length), idleTimeout)
        if payload.len < int(header.length):
          break

      case header.kind
      of mkQuery:
        var pos = 0
        let queryStr = readString(cast[seq[byte]](payload), pos)
        info("[" & $clientId & "] Query: " & queryStr)

        let startTicks = getMonoTime().ticks()
        let (success, result, errorMsg) = executeQuery(server.db, connCtx, queryStr)
        let durationMs = int((getMonoTime().ticks() - startTicks) div 1_000_000)

        if durationMs >= slowThreshold:
          slowQueryLog(slowLog, queryStr, durationMs, clientId)

        if success:
          if result.rows.len > 0:
            let dataMsg = serializeResult(result, header.requestId)
            await client.send(cast[string](dataMsg))
          let completeMsg = serializeComplete(result.affectedRows, header.requestId)
          await client.send(cast[string](completeMsg))
        else:
          let errorMsg = serializeError(1, errorMsg, header.requestId)
          await client.send(cast[string](errorMsg))

      of mkQueryParams:
        let (queryStr, params) = readQueryParamsMessage(cast[seq[byte]](payload))
        info("[" & $clientId & "] QueryParams: " & queryStr & " (" & $params.len & " params)")

        let startTicks = getMonoTime().ticks()
        let (success, result, errorMsg) = executeQuery(server.db, connCtx, queryStr, params)
        let durationMs = int((getMonoTime().ticks() - startTicks) div 1_000_000)

        if durationMs >= slowThreshold:
          slowQueryLog(slowLog, queryStr, durationMs, clientId)

        if success:
          if result.rows.len > 0:
            let dataMsg = serializeResult(result, header.requestId)
            await client.send(cast[string](dataMsg))
          let completeMsg = serializeComplete(result.affectedRows, header.requestId)
          await client.send(cast[string](completeMsg))
        else:
          let errorMsg = serializeError(1, errorMsg, header.requestId)
          await client.send(cast[string](errorMsg))

      of mkPing:
        var pongPayload: seq[byte] = @[]
        var pongMsg = WireMessage(
          header: MessageHeader(kind: mkPong, length: 0, requestId: header.requestId),
          payload: @[],
        )
        await client.send(cast[string](serializeMessage(pongMsg)))

      of mkClose:
        break

      else:
        let errorMsg = serializeError(2, "Unsupported message kind: " & $header.kind, header.requestId)
        await client.send(cast[string](errorMsg))

  except Exception as e:
    errorMsg("Client " & $clientId & " error: " & e.msg)
  finally:
    dec server.activeConnections
    info("Client " & $clientId & " disconnected")
    client.close()

proc run*(server: Server) {.async.} =
  server.running = true
  var clientId = 0
  let sock = newAsyncSocket()
  sock.setSockOpt(OptReuseAddr, true)
  sock.bindAddr(Port(server.config.port), server.config.address)
  sock.listen()
  if server.config.tlsEnabled:
    info("BaraDB TLS listening on " & server.config.address & ":" & $server.config.port)
  else:
    info("BaraDB listening on " & server.config.address & ":" & $server.config.port)
  while server.running:
    let client = await sock.accept()
    if server.config.maxConnections > 0 and server.activeConnections >= server.config.maxConnections:
      client.close()
      continue
    if server.tls != nil:
      try:
        server.tls.wrapServer(client)
      except Exception as e:
        errorMsg("TLS handshake failed: " & e.msg)
        client.close()
        continue
    inc clientId
    inc server.activeConnections
    asyncCheck server.handleClient(client, clientId)

proc stop*(server: Server) =
  server.running = false
  server.db.close()
