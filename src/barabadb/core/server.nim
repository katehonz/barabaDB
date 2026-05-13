## BaraDB Server — async TCP server with wire protocol
import std/asyncdispatch
import std/asyncnet
import std/strutils
import std/sequtils
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
import ../core/disttxn
import ../core/replication
import ../core/sharding
import ../core/gossip
import jwt as jwtlib

type
  Server* = ref object
    config*: BaraConfig
    running*: bool
    db*: LSMTree
    ctx*: ExecutionContext
    txnManager*: TxnManager
    distTxnManager*: DistTxnManager
    replicationManager*: ReplicationManager
    shardRouter*: ShardRouter
    clusterMembership*: ClusterMembership
    gossipProtocol*: GossipProtocol
    tls*: TLSContext
    activeConnections*: int

proc newServer*(config: BaraConfig): Server =
  let dataDir = config.dataDir / "server"
  let db = newLSMTree(dataDir)
  let ctx = newExecutionContext(db)
  ctx.txnManager = newTxnManager()
  var tls: TLSContext = nil
  if config.tlsEnabled and config.certFile.len > 0 and config.keyFile.len > 0:
    let tlsConfig = newTLSConfig(config.certFile, config.keyFile)
    tls = newTLSContext(tlsConfig)

  # Initialize sharding
  let shardRouter = newShardRouter()
  let localId = if config.raftNodeId.len > 0: config.raftNodeId else: "node-" & $config.port
  let cm = newClusterMembership(shardRouter, localId)

  # Wire shard migration callbacks to LSM
  shardRouter.iterateKeys = proc(shardId: int): seq[(string, seq[byte])] {.gcsafe.} =
    var entries: seq[(string, seq[byte])] = @[]
    for (key, value) in db.scanAll():
      if shardRouter.getShard(key) == shardId:
        entries.add((key, value))
    return entries

  shardRouter.storeKeys = proc(shardId: int, entries: seq[(string, seq[byte])]) {.gcsafe.} =
    for (key, value) in entries:
      db.put(key, value)

  shardRouter.deleteKeys = proc(keys: seq[string]) {.gcsafe.} =
    for key in keys:
      db.delete(key)

  # Initialize gossip
  let gossipPort = config.raftPort + 100
  let gp = newGossipProtocol(localId, config.address, config.port, gossipPort = gossipPort)

  # Wire gossip → cluster membership
  gp.onJoin = proc(node: GossipNode) {.gcsafe.} =
    cm.onNodeJoin(node.id, node.host, node.port)

  gp.onLeave = proc(nodeId: string) {.gcsafe.} =
    cm.onNodeLeave(nodeId)

  gp.onSuspect = proc(nodeId: string) {.gcsafe.} =
    cm.onNodeSuspect(nodeId)

  Server(config: config, running: false, db: db, ctx: ctx,
         txnManager: ctx.txnManager, distTxnManager: newDistTxnManager(),
         replicationManager: newReplicationManager(),
         shardRouter: shardRouter,
         clusterMembership: cm,
         gossipProtocol: gp,
         tls: tls)

# ----------------------------------------------------------------------
# Wire Protocol Helpers
# ----------------------------------------------------------------------

proc readUint32BE(data: string, pos: int): uint32 =
  var bytes: array[4, byte]
  for i in 0..3:
    bytes[i] = byte(data[pos + i])
  bigEndian32(addr result, unsafeAddr bytes)

proc parseHeader(data: string): (bool, MessageHeader) =
  if data.len < 12:
    return (false, MessageHeader())
  let rawKind = readUint32BE(data, 0)
  {.push warning[HoleEnumConv]: off.}
  let kind = MsgKind(rawKind)
  {.pop.}
  let length = readUint32BE(data, 4)
  let requestId = readUint32BE(data, 8)
  return (true, MessageHeader(kind: kind, length: length, requestId: requestId))

# ----------------------------------------------------------------------
# Query Execution (pipeline-based)
# ----------------------------------------------------------------------

proc typeToFieldKind*(colType: string): FieldKind =
  let t = colType.toUpper()
  if t.startsWith("INT") or t == "SERIAL" or t == "BIGINT" or t == "SMALLINT" or t == "BIGSERIAL" or t == "SMALLSERIAL":
    return fkInt64
  elif t.startsWith("FLOAT") or t == "REAL" or t == "DOUBLE" or t == "NUMERIC":
    return fkFloat64
  elif t == "BOOLEAN" or t == "BOOL":
    return fkBool
  elif t == "JSON" or t == "JSONB":
    return fkJson
  else:
    return fkString

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
  elif t == "JSON" or t == "JSONB":
    return WireValue(kind: fkJson, jsonVal: val)
  return WireValue(kind: fkString, strVal: val)

proc executeQuery(db: LSMTree, ctx: ExecutionContext, query: string, params: seq[WireValue] = @[],
                   replication: ReplicationManager = nil): (bool, QueryResult, string) =
  try:
    let tokens = tokenize(query)
    let astNode = parse(tokens)

    if astNode.stmts.len == 0:
      return (true, QueryResult(), "")

    let res = executor.executeQuery(ctx, astNode, params)
    if res.success:
      # Ship written key-value pairs to replicas
      if replication != nil and res.keyValuePairs.len > 0:
        for (key, value) in res.keyValuePairs:
          var data = newSeq[byte](key.len + 1 + value.len)
          for i, c in key: data[i] = byte(c)
          data[key.len] = byte(0)
          for i, c in value: data[key.len + 1 + i] = c
          discard replication.writeLsn(data)
      var qr = QueryResult(affectedRows: res.affectedRows, rowCount: res.rows.len)
      qr.columns = res.columns

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
        for col in res.columns:
          var found = ""
          for c in tbl.columns:
            if c.name.toLower() == col.toLower():
              found = c.colType
              break
          colTypes.add(found)
      else:
        colTypes = newSeq[string](res.columns.len)

      qr.columnTypes = colTypes.mapIt(typeToFieldKind(it))
      qr.rows = @[]
      for row in res.rows:
        var wireRow: seq[WireValue] = @[]
        for i, col in res.columns:
          let val = if col in row: row[col] else: ""
          let cType = if i < colTypes.len: colTypes[i] else: ""
          wireRow.add(valueToWire(val, cType))
        qr.rows.add(wireRow)
      return (true, qr, res.message)
    else:
      return (false, QueryResult(), res.message)
  except Exception as e:
    return (false, QueryResult(), e.msg)

# ----------------------------------------------------------------------
# Response Serialization
# ----------------------------------------------------------------------

proc serializeResult(qr: QueryResult, requestId: uint32): seq[byte] =
  var payload: seq[byte] = @[]
  payload.writeUint32(uint32(qr.columns.len))
  for col in qr.columns:
    payload.writeString(col)
  for ct in qr.columnTypes:
    payload.add(byte(ct))
  payload.writeUint32(uint32(qr.rows.len))
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

proc verifyToken(secret, tokenStr: string): (bool, string, string) =
  try:
    let token = tokenStr.toJWT()
    if not token.verify(secret, HS256):
      return (false, "", "")
    let userId = token.claims["sub"].node.str
    let role = if "role" in token.claims: token.claims["role"].node.str else: "user"
    return (true, userId, role)
  except:
    return (false, "", "")

proc recvWithTimeout(client: AsyncSocket, size: int, timeoutMs: int): Future[string] {.async.} =
  if timeoutMs <= 0:
    return await client.recv(size)
  let fut = client.recv(size)
  let timeoutFut = sleepAsync(timeoutMs)
  await fut or timeoutFut
  if fut.finished:
    return fut.read()
  return ""

proc handleClient(server: Server, client: AsyncSocket, clientId: int) {.async.} =
  info("Client " & $clientId & " connected")
  var connCtx = cloneForConnection(server.ctx)
  let idleTimeout = server.config.idleTimeoutMs
  let slowThreshold = server.config.slowQueryThresholdMs
  let slowLog = server.config.slowQueryLogPath
  var authenticated = not server.config.authEnabled
  let secret = server.config.getEffectiveJwtSecret()

  try:
    while true:
      let headerData = await client.recvExactWithTimeout(12, idleTimeout)
      if headerData.len < 12:
        break

      # Detect text-based DISTTXN RPC (starts with "DISTTXN")
      if headerData.len >= 7 and headerData[0..6] == "DISTTXN":
        var rest = headerData[7..^1]
        while '\n' notin rest:
          let more = await client.recvWithTimeout(1024, idleTimeout)
          if more.len == 0: break
          rest.add(more)
        let parts = rest.strip().split(" ")
        if parts.len >= 2:
          let txnId = try: uint64(parseBiggestUint(parts[0])) except: 0'u64
          let action = parts[1].toUpper()
          if server.distTxnManager != nil:
            let txn = server.distTxnManager.getTxn(txnId)
            if action == "PREPARE":
              if txn != nil:
                await client.send("OK\n")
              else:
                await client.send("ERR unknown transaction\n")
            elif action == "COMMIT":
              if txn != nil and txn.state() == dtsPrepared:
                await client.send("OK\n")
              else:
                await client.send("ERR not prepared\n")
            elif action == "ROLLBACK":
              if txn != nil:
                await client.send("OK\n")
              else:
                await client.send("OK\n")
            else:
              await client.send("ERR unknown action\n")
          else:
            await client.send("OK\n")
        else:
          await client.send("ERR invalid message\n")
        continue

      # Detect replication data (starts with "REP ")
      if headerData.len >= 4 and headerData[0..3] == "REP ":
        var rest = headerData[4..^1]
        while '\n' notin rest:
          let more = await client.recvWithTimeout(1024, idleTimeout)
          if more.len == 0: break
          rest.add(more)
        let parts = rest.strip().split(" ")
        if parts.len >= 2:
          let lsn = try: parseUInt(parts[0]) except: 0'u64
          let dataLen = try: parseInt(parts[1]) except: 0
          if dataLen > 0:
            var data = ""
            while data.len < dataLen:
              let chunk = await client.recvWithTimeout(dataLen - data.len, idleTimeout)
              if chunk.len == 0: break
              data.add(chunk)
            if data.len > 0:
              let nullPos = data.find('\0')
              if nullPos >= 0:
                let key = data[0..<nullPos]
                let value = data[nullPos+1..^1]
                if value.len > 0:
                  server.db.put(key, cast[seq[byte]](value))
                else:
                  server.db.delete(key)
          await client.send("ACK " & $lsn & "\n")
        else:
          await client.send("ERR\n")
        continue

      # Detect shard migration data (starts with "MIGRATE ")
      if headerData.len >= 8 and headerData[0..7] == "MIGRATE ":
        var rest = headerData[8..^1]
        while '\n' notin rest:
          let more = await client.recvWithTimeout(1024, idleTimeout)
          if more.len == 0: break
          rest.add(more)
        let headerLine = "MIGRATE " & rest.strip()
        let parts = rest.strip().split(" ")
        if parts.len >= 2:
          let entryCount = try: parseInt(parts[1]) except: 0
          var data = ""
          if entryCount > 0:
            # Read all entries (each entry is key\0value\n)
            # Estimate buffer: 512 bytes per entry
            let maxSize = min(entryCount * 1024, 10 * 1024 * 1024)
            var received = 0
            while received < maxSize:
              let chunk = await client.recvWithTimeout(4096, idleTimeout)
              if chunk.len == 0: break
              data.add(chunk)
              received += chunk.len
              # Count newlines to know when we have all entries
              var newlineCount = 0
              for c in chunk:
                if c == '\n': inc newlineCount
              if newlineCount >= entryCount:
                break
          let response = handleMigrationMessage(headerLine, data, server.shardRouter)
          await client.send(response)
        else:
          await client.send("ERR invalid migrate header\n")
        continue

      let (ok, header) = parseHeader(headerData)
      if not ok:
        break

      var payload = ""
      if header.length > 0:
        payload = await client.recvExactWithTimeout(int(header.length), idleTimeout)
        if payload.len < int(header.length):
          break

      if not authenticated and header.kind != mkAuth:
        let err = makeErrorMessage(header.requestId, 401, "Authentication required")
        await client.send(cast[string](err))
        continue

      case header.kind
      of mkAuth:
        let tokenStr = parseAuthMessage(cast[seq[byte]](payload))
        let (valid, userId, _) = verifyToken(secret, tokenStr)
        if valid:
          authenticated = true
          let okMsg = makeAuthOkMessage(header.requestId)
          await client.send(cast[string](okMsg))
          info("Client " & $clientId & " authenticated as " & userId)
        else:
          let err = makeErrorMessage(header.requestId, 403, "Invalid token")
          await client.send(cast[string](err))

      of mkQuery:
        var pos = 0
        let queryStr = readString(cast[seq[byte]](payload), pos)
        info("[" & $clientId & "] Query: " & queryStr)

        # Shard-aware routing: check if this node should handle the write
        var shardCheck = true
        if server.clusterMembership.nodes.len > 0:
          let stmts = try: parse(tokenize(queryStr)) except: nil
          if stmts != nil:
            for stmt in stmts.stmts:
              if stmt.kind in {nkInsert, nkUpdate, nkDelete}:
                # If this node is not assigned to any shard, reject writes
                let localShards = server.shardRouter.getShardForNode(
                  server.clusterMembership.localNodeId)
                if localShards.len == 0:
                  shardCheck = false
                  let err = serializeError(3, "Node not assigned to any shard", header.requestId)
                  await client.send(cast[string](err))
                break

        if shardCheck:
          let startTicks = getMonoTime().ticks()
          let (success, result, errorMsg) = executeQuery(server.db, connCtx, queryStr, replication=server.replicationManager)
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
        let (success, result, errorMsg) = executeQuery(server.db, connCtx, queryStr, params, replication=server.replicationManager)
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
    if server.activeConnections > 0:
      dec server.activeConnections
    info("Client " & $clientId & " disconnected")
    client.close()

proc run*(server: Server) {.async.} =
  server.running = true
  var clientId = 0

  # Start gossip protocol if configured
  if server.gossipProtocol != nil and server.gossipProtocol.gossipPort > 0:
    server.gossipProtocol.startGossip()
    info("Gossip protocol started on port " & $server.gossipProtocol.gossipPort)

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
  if server.gossipProtocol != nil:
    server.gossipProtocol.stop()
  server.db.close()
