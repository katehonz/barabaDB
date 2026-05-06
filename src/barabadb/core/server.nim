## BaraDB Server — async TCP server with wire protocol
import std/asyncdispatch
import std/asyncnet
import std/strutils
import std/os
import std/endians
import config
import ../protocol/wire
import ../query/lexer
import ../query/parser
import ../query/ast
import ../query/executor
import ../storage/lsm
import ../core/mvcc

type
  Server* = ref object
    config: BaraConfig
    running: bool
    db: LSMTree
    ctx: ExecutionContext
    txnManager: TxnManager

  ClientConnection = ref object
    socket: AsyncSocket
    id: int
    currentTxn: Transaction

proc newServer*(config: BaraConfig): Server =
  let dataDir = config.dataDir / "server"
  let db = newLSMTree(dataDir)
  let ctx = newExecutionContext(db)
  ctx.txnManager = newTxnManager()
  Server(config: config, running: false, db: db, ctx: ctx,
         txnManager: ctx.txnManager)

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

proc executeQuery(db: LSMTree, ctx: ExecutionContext, query: string): (bool, QueryResult, string) =
  try:
    let tokens = tokenize(query)
    let astNode = parse(tokens)

    if astNode.stmts.len == 0:
      return (true, QueryResult(), "")

    let stmt = astNode.stmts[0]
    case stmt.kind
    of nkSelect, nkInsert, nkUpdate, nkDelete, nkCreateTable, nkDropTable,
       nkCreateType, nkBeginTxn, nkCommitTxn, nkRollbackTxn, nkExplainStmt:
      let (success, errMsg, affectedRows) = executor.executeQuery(ctx, astNode)
      if success:
        var qr = QueryResult(affectedRows: affectedRows, rowCount: affectedRows)
        if stmt.kind == nkSelect:
          qr.columns = @["key", "value"]
          qr.rows = @[]
        return (true, qr, "")
      else:
        return (false, QueryResult(), errMsg)
    else:
      return (false, QueryResult(), "Unsupported statement type: " & $stmt.kind)
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

proc handleClient(server: Server, client: AsyncSocket, clientId: int) {.async.} =
  echo "Client ", clientId, " connected"
  var connCtx = cloneForConnection(server.ctx)
  try:
    while true:
      # Read 12-byte header
      let headerData = await client.recvExact(12)
      if headerData.len < 12:
        break

      let (ok, header) = parseHeader(headerData)
      if not ok:
        break

      # Read payload
      var payload = ""
      if header.length > 0:
        payload = await client.recvExact(int(header.length))
        if payload.len < int(header.length):
          break

      case header.kind
      of mkQuery:
        # Parse query from payload
        var pos = 0
        let queryStr = readString(cast[seq[byte]](payload), pos)
        echo "[", clientId, "] Query: ", queryStr

        let (success, result, errorMsg) = executeQuery(server.db, connCtx, queryStr)
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
    echo "Client ", clientId, " error: ", e.msg
  finally:
    echo "Client ", clientId, " disconnected"
    client.close()

proc run*(server: Server) {.async.} =
  server.running = true
  var clientId = 0
  let sock = newAsyncSocket()
  sock.setSockOpt(OptReuseAddr, true)
  sock.bindAddr(Port(server.config.port), server.config.address)
  sock.listen()
  echo "BaraDB listening on ", server.config.address, ":", server.config.port
  while server.running:
    let client = await sock.accept()
    inc clientId
    asyncCheck server.handleClient(client, clientId)

proc stop*(server: Server) =
  server.running = false
  server.db.close()
