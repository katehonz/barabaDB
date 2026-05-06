## BaraDB Server — async TCP server with wire protocol
import std/asyncdispatch
import std/asyncnet
import std/strutils
import std/sequtils
import std/re
import std/os
import std/endians
import config
import ../protocol/wire
import ../query/lexer
import ../query/parser
import ../query/ast
import ../storage/lsm

type
  Server* = ref object
    config: BaraConfig
    running: bool
    db: LSMTree

  ClientConnection = ref object
    socket: AsyncSocket
    id: int

proc newServer*(config: BaraConfig): Server =
  let dataDir = config.dataDir / "server"
  Server(config: config, running: false, db: newLSMTree(dataDir))

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
# Query Execution
# ----------------------------------------------------------------------

proc extractStringLiteral(node: Node): string =
  if node == nil:
    return ""
  case node.kind
  of nkStringLit: return node.strVal
  of nkIdent: return node.identName
  of nkIntLit: return $node.intVal
  of nkBinOp:
    if node.binOp == bkEq and node.binLeft != nil and node.binRight != nil:
      # Accept any identifier on the left side (e.g., key = 'x', name = 'y')
      if node.binLeft.kind == nkIdent:
        return extractStringLiteral(node.binRight)
      if node.binRight.kind == nkIdent:
        return extractStringLiteral(node.binLeft)
    return ""
  else: return ""

proc execSelect(db: LSMTree, astNode: Node): QueryResult =
  result = QueryResult(columns: @["key", "value"], rows: @[])

  var keyFilter = ""
  if astNode.selWhere != nil and astNode.selWhere.whereExpr != nil:
    let whereExpr = astNode.selWhere.whereExpr
    keyFilter = extractStringLiteral(whereExpr)

  if keyFilter != "":
    # Point read
    let (found, val) = db.get(keyFilter)
    if found:
      var row: seq[WireValue] = @[]
      row.add(WireValue(kind: fkString, strVal: keyFilter))
      row.add(WireValue(kind: fkBytes, bytesVal: val))
      result.rows.add(row)
      result.rowCount = 1
  else:
    # Full scan of memory tables
    for entry in db.scanMemTable():
      if entry.deleted:
        continue
      var row: seq[WireValue] = @[]
      row.add(WireValue(kind: fkString, strVal: entry.key))
      row.add(WireValue(kind: fkBytes, bytesVal: entry.value))
      result.rows.add(row)
    result.rowCount = result.rows.len

proc execInsert(db: var LSMTree, query: string): QueryResult =
  result = QueryResult()
  # Manual parsing for simple INSERT: INSERT table { field := 'value' }
  # We use the value as the key for simple KV semantics
  let pattern = re"INSERT\s+(\w+)\s*\{\s*(\w+)\s*:=\s*'([^']+)'\s*\}"
  var matches: array[3, string]
  if query.match(pattern, matches):
    let key = matches[2]   # use the value as key
    let value = matches[2]
    db.put(key, cast[seq[byte]](value))
    result.affectedRows = 1
  else:
    # Try simpler pattern: INSERT table { field := value }
    let pattern2 = re"INSERT\s+(\w+)\s*\{\s*(\w+)\s*:=\s*(\w+)\s*\}"
    var matches2: array[3, string]
    if query.match(pattern2, matches2):
      let key = matches2[2]
      let value = matches2[2]
      db.put(key, cast[seq[byte]](value))
      result.affectedRows = 1

proc execDelete(db: var LSMTree, astNode: Node): QueryResult =
  result = QueryResult()
  var keyFilter = ""
  if astNode.delWhere != nil and astNode.delWhere.whereExpr != nil:
    keyFilter = extractStringLiteral(astNode.delWhere.whereExpr)
  if keyFilter != "":
    db.delete(keyFilter)
    result.affectedRows = 1

proc executeQuery(db: var LSMTree, query: string): (bool, QueryResult, string) =
  try:
    let tokens = tokenize(query)
    let astNode = parse(tokens)

    if astNode.stmts.len == 0:
      return (true, QueryResult(), "")

    let stmt = astNode.stmts[0]
    case stmt.kind
    of nkSelect:
      let qr = execSelect(db, stmt)
      return (true, qr, "")
    of nkInsert:
      let qr = execInsert(db, query)
      return (true, qr, "")
    of nkDelete:
      let qr = execDelete(db, stmt)
      return (true, qr, "")
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

        let (success, result, errorMsg) = executeQuery(server.db, queryStr)
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
