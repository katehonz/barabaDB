## BaraDB Server — async TCP server with wire protocol
import std/asyncdispatch
import std/asyncnet
import std/strutils
import std/sequtils
import std/tables
import std/endians
import std/monotimes
import std/times
import std/locks
import std/nativesockets
when defined(windows):
  from std/winlean import TCP_NODELAY
else:
  from std/posix import TCP_NODELAY
import config
import logging
import ../protocol/wire
import ../protocol/ssl
import ../query/lexer
import ../query/parser
import ../query/ast
import ../query/executor
import ../query/exec/params
import ../query/exec/dml
import ../storage/lsm
import ../storage/gate
import ../core/mvcc
import ../core/disttxn
import ../core/replication
import ../core/raft
import ../core/sharding
import ../core/gossip
import ../protocol/ratelimit
import ../core/registry
import jwt as jwtlib

type
  Server* = ref object
    config*: BaraConfig
    running*: bool
    db*: LSMTree
    ctx*: ExecutionContext
    registry*: DatabaseRegistry
    txnManager*: TxnManager
    distTxnManager*: DistTxnManager
    replicationManager*: ReplicationManager
    raftNode*: RaftNode
    shardRouter*: ShardRouter
    clusterMembership*: ClusterMembership
    gossipProtocol*: GossipProtocol
    tls*: TLSContext
    rateLimiter*: RateLimiter
    activeConnections*: int
    activeConnectionsLock*: Lock

proc newServerWithRegistry*(config: BaraConfig, registry: DatabaseRegistry): Server =
  # CRITICAL: Reject empty JWT secret when auth is enabled
  if config.authEnabled and config.jwtSecret.len == 0:
    raise newException(ValueError, 
      "Security error: authEnabled is true but jwtSecret is empty. " &
      "Set BARADB_JWT_SECRET environment variable or jwt_secret in baradb.json")
  
  let dbInfo = getOrCreateDatabase(registry, "default")
  let db = dbInfo.db
  let ctx = cast[ExecutionContext](cast[pointer](dbInfo.ctx))
  ctx.txnManager = newTxnManager()
  var tls: TLSContext = nil
  if config.tlsEnabled and config.certFile.len > 0 and config.keyFile.len > 0:
    let tlsConfig = newTLSConfig(config.certFile, config.keyFile)
    tls = newTLSContext(tlsConfig)

  # Initialize sharding / gossip. Server fields own the refs; locals used inside
  # callback closures are {.cursor.} so ARC does not form uncollectable cycles
  # (local + closure env + object callback fields).
  let localId = if config.raftNodeId.len > 0: config.raftNodeId else: "node-" & $config.port
  let gossipPort = config.raftPort + 100
  let rl = newRateLimiter(rlaTokenBucket, config.rateLimitGlobal, config.rateLimitPerClient)

  result = Server(config: config, running: false, db: db, ctx: ctx,
         registry: registry,
         txnManager: ctx.txnManager, distTxnManager: newDistTxnManager(),
         replicationManager: newReplicationManager(),
         shardRouter: newShardRouter(),
         clusterMembership: nil,
         gossipProtocol: newGossipProtocol(localId, config.address, config.port, gossipPort = gossipPort),
         tls: tls,
         rateLimiter: rl)
  result.clusterMembership = newClusterMembership(result.shardRouter, localId)
  initLock(result.activeConnectionsLock)

  # Wire shard migration callbacks to LSM (default database)
  block:
    let shardRouter {.cursor.} = result.shardRouter
    let dbRef {.cursor.} = db
    shardRouter.iterateKeys = proc(shardId: int): seq[(string, seq[byte])] {.gcsafe.} =
      var entries: seq[(string, seq[byte])] = @[]
      for (key, value) in dbRef.scanAll():
        if shardRouter.getShard(key) == shardId:
          entries.add((key, value))
      return entries
    shardRouter.storeKeys = proc(shardId: int, entries: seq[(string, seq[byte])]) {.gcsafe.} =
      for (key, value) in entries:
        dbRef.put(key, value)
    shardRouter.deleteKeys = proc(keys: seq[string]) {.gcsafe.} =
      for key in keys:
        dbRef.delete(key)

  # Wire gossip → cluster membership
  block:
    let gp {.cursor.} = result.gossipProtocol
    let cm {.cursor.} = result.clusterMembership
    gp.onJoin = proc(node: GossipNode) {.gcsafe.} =
      cm.onNodeJoin(node.id, node.host, node.port)
    gp.onLeave = proc(nodeId: string) {.gcsafe.} =
      cm.onNodeLeave(nodeId)
    gp.onSuspect = proc(nodeId: string) {.gcsafe.} =
      cm.onNodeSuspect(nodeId)

proc newServerWithDb*(config: BaraConfig, db: LSMTree): Server =
  let registry = newDatabaseRegistry(config)
  let ctx = newExecutionContext(db, registry)
  registry.setContextFactory(proc(d: LSMTree, r: DatabaseRegistry): ContextRef {.closure.} =
    cast[ContextRef](cast[pointer](newExecutionContext(d, r))))
  # Use the existing db for default
  registry.setDatabase("default", db, cast[ContextRef](cast[pointer](ctx)))
  return newServerWithRegistry(config, registry)

proc newServer*(config: BaraConfig): Server =
  let registry = newDatabaseRegistry(config)
  registry.setContextFactory(proc(d: LSMTree, r: DatabaseRegistry): ContextRef {.closure.} =
    cast[ContextRef](cast[pointer](newExecutionContext(d, r))))
  registry.loadExistingDatabases()
  registry.ensureDefaultDatabase()
  return newServerWithRegistry(config, registry)

# ----------------------------------------------------------------------
# Wire Protocol Helpers
# ----------------------------------------------------------------------

proc bytesToString(data: seq[byte]): string =
  ## Safely convert seq[byte] to string (copies data)
  result = newString(data.len)
  for i in 0..<data.len:
    result[i] = char(data[i])

proc stringToBytes(data: string): seq[byte] =
  ## Safely convert string to seq[byte] (copies data)
  result = newSeq[byte](data.len)
  for i in 0..<data.len:
    result[i] = byte(data[i])

proc readUint32BE(data: string, pos: int): uint32 =
  if pos + 4 > data.len:
    raise newException(ValueError, "readUint32BE: index out of bounds")
  var bytes: array[4, byte]
  for i in 0..3:
    bytes[i] = byte(data[pos + i])
  bigEndian32(addr result, unsafeAddr bytes)

proc parseHeader(data: string): (bool, MessageHeader) =
  if data.len < 12:
    return (false, MessageHeader())
  let rawKind = readUint32BE(data, 0)
  if rawKind < 0x01 or (rawKind > 0x09 and rawKind < 0x80) or rawKind > 0x89:
    return (false, MessageHeader())
  let kind = cast[MsgKind](rawKind)
  let length = readUint32BE(data, 4)
  # Reject oversized messages before any buffer allocation: recvExactWithTimeout
  # pre-allocates `length` bytes before the auth check, so an unbounded uint32
  # (up to ~4 GiB) is a pre-auth memory-exhaustion DoS. Cap at the wire max.
  if length > uint32(MaxWireStringLen):
    return (false, MessageHeader())
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
  if val == "\\N" or val.toLower() == "null":
    return WireValue(kind: fkNull)
  let t = colType.toUpper()
  if t.startsWith("INT") or t == "SERIAL" or t == "BIGINT" or t == "SMALLINT" or t == "BIGSERIAL" or t == "SMALLSERIAL":
    try:
      return WireValue(kind: fkInt64, int64Val: parseInt(val))
    except ValueError: discard
  elif t.startsWith("FLOAT") or t == "REAL" or t == "DOUBLE" or t == "NUMERIC" or t.startsWith("DOUBLE"):
    try:
      return WireValue(kind: fkFloat64, float64Val: parseFloat(val))
    except ValueError: discard
  elif t == "BOOLEAN" or t == "BOOL":
    let lv = val.toLower()
    if lv in ["true", "t", "yes", "1"]:
      return WireValue(kind: fkBool, boolVal: true)
    elif lv in ["false", "f", "no", "0"]:
      return WireValue(kind: fkBool, boolVal: false)
  elif t == "JSON" or t == "JSONB":
    return WireValue(kind: fkJson, jsonVal: val)
  return WireValue(kind: fkString, strVal: val)

proc forwardRecvExact(sock: AsyncSocket, size: int): Future[string] {.async.} =
  var buf = ""
  while buf.len < size:
    let chunk = await sock.recv(size - buf.len)
    if chunk.len == 0: break
    buf.add(chunk)
  return buf

proc forwardQueryToLeader*(host: string, port: int, query: string,
                           tls: TLSContext = nil,
                           params: seq[WireValue] = @[],
                           timeoutMs: int = 5000): Future[(bool, QueryResult, string)] {.async.} =
  ## Proxy a write/DDL to the known leader's SQL port. Used by followers when
  ## BARADB_RAFT_CLIENT_PEERS maps leader id → host:clientPort.
  ## `tls` is the local server's client-port TLS context: when the wire port
  ## serves TLS, the leader's does too, so the forwarding dial must complete a
  ## client handshake. The context is reused as-is (verifyMode stays
  ## CVerifyNone — do NOT enable verifyPeer on the reused context); OpenSSL
  ## contexts are role-agnostic in Nim's stdlib, wrapConnectedSocket with
  ## handshakeAsClient sets the role.
  var sock: AsyncSocket = nil
  try:
    sock = newAsyncSocket()
    let okConn = await withTimeout(sock.connect(host, Port(port)), min(timeoutMs, 2000))
    if not okConn:
      return (false, QueryResult(), "leader forward connect timeout")
    if tls != nil:
      try:
        tls.wrapClient(sock)
      except CatchableError:
        return (false, QueryResult(), "leader forward TLS handshake failed")
    let reqId = 1'u32
    let msg = if params.len > 0:
        makeQueryParamsMessage(reqId, query, params)
      else:
        makeQueryMessage(reqId, query)
    await sock.send(cast[string](msg))

    var qr = QueryResult()
    var gotComplete = false
    while true:
      let headerData = await forwardRecvExact(sock, 12)
      if headerData.len < 12:
        break
      var hbytes = newSeq[byte](headerData.len)
      for i, c in headerData: hbytes[i] = byte(c)
      var pos = 0
      let kind = MsgKind(readUint32(hbytes, pos))
      let length = int(readUint32(hbytes, pos))
      discard readUint32(hbytes, pos)  # requestId
      let payloadStr = if length > 0: await forwardRecvExact(sock, length) else: ""
      if payloadStr.len < length:
        break
      var payload = newSeq[byte](payloadStr.len)
      for i, c in payloadStr: payload[i] = byte(c)
      case kind
      of mkError:
        var epos = 0
        discard readUint32(payload, epos)
        let emsg = readString(payload, epos)
        return (false, QueryResult(), emsg)
      of mkData:
        var dpos = 0
        let colCount = int(readUint32(payload, dpos))
        qr.columns = @[]
        for i in 0 ..< colCount:
          qr.columns.add(readString(payload, dpos))
        qr.columnTypes = @[]
        for i in 0 ..< colCount:
          qr.columnTypes.add(FieldKind(payload[dpos]))
          inc dpos
        let rowCount = int(readUint32(payload, dpos))
        qr.rowCount = rowCount
        qr.rows = @[]
        for r in 0 ..< rowCount:
          var row: seq[WireValue] = @[]
          for c in 0 ..< colCount:
            row.add(deserializeValue(payload, dpos))
          qr.rows.add(row)
      of mkComplete:
        var cpos = 0
        if payload.len >= 4:
          qr.affectedRows = int(readUint32(payload, cpos))
        gotComplete = true
        break
      else:
        discard
    if gotComplete:
      return (true, qr, "")
    return (false, QueryResult(), "leader forward incomplete response")
  except CatchableError as e:
    return (false, QueryResult(), "leader forward failed: " & e.msg)
  finally:
    if sock != nil:
      try: sock.close() except CatchableError: discard

proc waitRaftCommit(node: RaftNode, lastIdx: uint64, timeoutMs: int): Future[(bool, string)] {.async.} =
  let start = getMonoTime()
  let deadline = start + initDuration(milliseconds = timeoutMs)
  while node.commitIndex < lastIdx and getMonoTime() < deadline:
    await sleepAsync(10)
  let waitedMs = int64((getMonoTime() - start).inMilliseconds)
  if node.commitIndex < lastIdx:
    if node.metrics != nil:
      inc node.metrics.commitTimeoutsTotal
    return (false, "raft commit timeout")
  if node.metrics != nil:
    inc node.metrics.commitWaitsTotal
    node.metrics.commitWaitMsTotal += waitedMs
  return (true, "")

proc appendWriteToRaft*(node: RaftNode,
                        kvPairs: seq[tuple[key: string, value: seq[byte], deleted: bool]],
                        timeoutMs: int): Future[(bool, string)] {.async.} =
  ## C3b leader write path: append each written KV pair to the Raft log and
  ## wait for majority commit. The `deleted` flag encodes a delete — an empty
  ## value alone is a put (PK-only tables store an empty LSM value); the entry
  ## format matches applyCommand ("put": key \x00 value, "delete": key).
  ##
  ## MUST be called from the async event-loop thread that owns `node` and
  ## WITHOUT holding the storage gate: commitIndex advances via
  ## handleAppendReply on the same loop, and applyCommand re-enters the
  ## (non-reentrant) gate — waiting under the gate would deadlock the loop.
  var lastIdx = 0'u64
  for pair in kvPairs:
    let entry = if pair.deleted:
        node.appendLog("delete", cast[seq[byte]](pair.key))
      else:
        node.appendLog("put", cast[seq[byte]](pair.key & "\x00" & cast[string](pair.value)))
    if entry.index == 0:
      if node.metrics != nil:
        inc node.metrics.lostLeadershipTotal
      return (false, "lost leadership during raft append")
    lastIdx = entry.index
  return await waitRaftCommit(node, lastIdx, timeoutMs)

proc appendDdlToRaft*(node: RaftNode, sql: string,
                      timeoutMs: int): Future[(bool, string)] {.async.} =
  ## C3c schema path: append one "ddl" log entry with the original SQL text.
  ## Followers re-execute it via applyCommand (executor, no raft recursion).
  ## MUST be called outside the storage gate (same as appendWriteToRaft).
  let entry = node.appendLog("ddl", cast[seq[byte]](sql))
  if entry.index == 0:
    if node.metrics != nil:
      inc node.metrics.lostLeadershipTotal
    return (false, "lost leadership during raft append")
  return await waitRaftCommit(node, entry.index, timeoutMs)

proc executeQuery(db: LSMTree, ctx: ExecutionContext, query: string, params: seq[WireValue] = @[],
                   replication: ReplicationManager = nil,
                   raftNode: RaftNode = nil,
                   raftWriteTimeoutMs: int = 5000,
                   raftPeerClientAddrs: Table[string, tuple[host: string, port: int]] =
                     initTable[string, tuple[host: string, port: int]](),
                   forwardTls: TLSContext = nil): Future[(bool, QueryResult, string)] {.async.} =
  ## All storage access is under the global StorageGate so HTTP worker threads
  ## and the TCP event loop never touch ORC-managed LSM/executor state concurrently.
  ## The gate is released BEFORE the Raft commit wait — see appendWriteToRaft.
  var ok = false
  var qr = QueryResult()
  var msg = ""
  var kvPairs: seq[tuple[key: string, value: seq[byte], deleted: bool]] = @[]
  var needsRaftDdl = false
  var needsForward = false
  var forwardHost = ""
  var forwardPort = 0
  withStorageGate:
    try:
      let tokens = tokenize(query)
      let astNode = parse(tokens)

      if astNode.stmts.len == 0:
        return (true, QueryResult(), "")

      # C3b/C3c: DML + schema DDL go through the Raft log — only the leader
      # of the default database may accept them. Inspect every statement so
      # "SELECT 1; INSERT/CREATE ..." cannot bypass the gate.
      var hasWrite = false
      needsRaftDdl = false
      for stmt in astNode.stmts:
        if isWrite(stmt): hasWrite = true
        if isRaftDdl(stmt): needsRaftDdl = true
      if raftNode != nil and (hasWrite or needsRaftDdl):
        let dbName = if ctx.currentDatabase.len > 0: ctx.currentDatabase else: "default"
        if dbName != "default":
          return (false, QueryResult(),
            "raft writes only supported on the 'default' database; current is '" &
            dbName & "'")
        if raftNode.state != rsLeader:
          let who = if raftNode.leaderId.len > 0: raftNode.leaderId else: "none elected"
          # Transparent leader forwarding when client SQL addresses are known.
          if who != "none elected" and who in raftPeerClientAddrs:
            let peerAddr = raftPeerClientAddrs[who]
            needsForward = true
            forwardHost = peerAddr.host
            forwardPort = peerAddr.port
          else:
            return (false, QueryResult(), "not leader; leader is '" & who & "'")

      if not needsForward:
        let res = executor.executeQuery(ctx, astNode, params)
        if res.success:
          # Ship written key-value pairs to replicas (legacy path; skipped when
          # the raft path below handles the statement).
          if raftNode == nil and replication != nil and res.keyValuePairs.len > 0:
            for pair in res.keyValuePairs:
              # Legacy REP wire format: explicit 'P'/'D' op tag (see
              # encodeRepPayload). The tag — not an empty value — distinguishes
              # a put from a delete, so PK-only rows (empty value) replicate as
              # puts instead of vanishing as deletes.
              discard replication.writeLsn(
                encodeRepPayload(pair.deleted, pair.key, pair.value))
          qr = QueryResult(affectedRows: res.affectedRows, rowCount: res.rows.len)
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
              let val = if col in row: valueToString(row[col]) else: "\\N"
              let cType = if i < colTypes.len: colTypes[i] else: ""
              wireRow.add(valueToWire(val, cType))
            qr.rows.add(wireRow)
          ok = true
          msg = res.message
          kvPairs = res.keyValuePairs
        else:
          return (false, QueryResult(), res.message)
    except Exception as e:
      return (false, QueryResult(), e.msg)
  # Follower write/DDL: proxy to leader SQL port (outside the storage gate).
  if needsForward:
    let (okF, qrF, errF) = await forwardQueryToLeader(forwardHost, forwardPort,
      query, forwardTls, params, raftWriteTimeoutMs)
    if raftNode != nil and raftNode.metrics != nil:
      if okF: inc raftNode.metrics.forwardsTotal
      else: inc raftNode.metrics.forwardErrorsTotal
    return (okF, qrF, errF)
  # Raft log append + majority wait (outside the storage gate).
  # DDL batches ship the original SQL once (re-executed on apply). Pure DML
  # ships KV pairs. Mixed DDL+DML in one query uses the DDL path only so the
  # whole batch is re-run in order on followers.
  if ok and raftNode != nil:
    if needsRaftDdl:
      let (raftOk, raftErr) = await appendDdlToRaft(raftNode, query, raftWriteTimeoutMs)
      if not raftOk:
        return (false, QueryResult(), raftErr)
    elif kvPairs.len > 0:
      let (raftOk, raftErr) = await appendWriteToRaft(raftNode, kvPairs, raftWriteTimeoutMs)
      if not raftOk:
        return (false, QueryResult(), raftErr)
  return (ok, qr, msg)

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
  # Timeout: caller will close the socket, which cancels the pending recv
  return ""

proc slowQueryLog(logPath: string, query: string, durationMs: int, clientId: int) =
  if logPath.len == 0:
    return
  try:
    let f = open(logPath, fmAppend)
    defer: f.close()
    let line = $getMonoTime().ticks() & " | " & $clientId & " | " & $durationMs & "ms | " & query & "\n"
    f.write(line)
  except IOError: discard

proc verifyToken(secret, tokenStr: string): (bool, string, string, string) =
  try:
    let token = tokenStr.toJWT()
    if not token.verify(secret, HS256):
      return (false, "", "", "")
    let userId = token.claims["sub"].node.str
    let role = if "role" in token.claims: token.claims["role"].node.str else: "user"
    let database = if "database" in token.claims: token.claims["database"].node.str else: ""
    return (true, userId, role, database)
  except ValueError, KeyError:
    return (false, "", "", "")

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
        if not authenticated:
          await client.send("ERR auth required\n")
          continue
        var rest = headerData[7..^1]
        while '\n' notin rest:
          let more = await client.recvWithTimeout(1024, idleTimeout)
          if more.len == 0: break
          rest.add(more)
        let parts = rest.strip().split(" ")
        if parts.len >= 2:
          let txnId = try: uint64(parseBiggestUint(parts[0])) except CatchableError: 0'u64
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
        if not authenticated:
          await client.send("ERR auth required\n")
          continue
        var rest = headerData[4..^1]
        while '\n' notin rest:
          let more = await client.recvWithTimeout(1024, idleTimeout)
          if more.len == 0: break
          rest.add(more)
        let parts = rest.strip().split(" ")
        if parts.len >= 2:
          let lsn = try: parseUInt(parts[0]) except CatchableError: 0'u64
          let dataLen = try: parseInt(parts[1]) except CatchableError: 0
          if dataLen > 0:
            var data = ""
            while data.len < dataLen:
              let chunk = await client.recvWithTimeout(dataLen - data.len, idleTimeout)
              if chunk.len == 0: break
              data.add(chunk)
            if data.len > 0:
              # Op tag — not value length — decides put vs delete, so a PK-only
              # put (empty value) is applied as a put and the row survives.
              let decoded = decodeRepPayload(cast[seq[byte]](data))
              case decoded.op
              of ropPut, ropDelete:
                # Apply through applyReplicatedPut/Delete (not raw db.put/delete)
                # so secondary B-tree/FTS/HNSW/graph indexes stay consistent on
                # the replica — the same path raft uses. server.ctx is the
                # canonical default ctx whose index structures the per-connection
                # query clones share. Under the storage gate: those structures
                # are shared with hunos HTTP workers and are only safe to mutate
                # under it.
                withStorageGate:
                  if decoded.op == ropPut:
                    applyReplicatedPut(server.ctx, decoded.key, decoded.value)
                  else:
                    applyReplicatedDelete(server.ctx, decoded.key)
              of ropInvalid:
                discard
          await client.send("ACK " & $lsn & "\n")
        else:
          await client.send("ERR\n")
        continue

      # Detect shard migration data (starts with "MIGRATE ")
      if headerData.len >= 8 and headerData[0..7] == "MIGRATE ":
        if not authenticated:
          await client.send("ERR auth required\n")
          continue
        var rest = headerData[8..^1]
        while '\n' notin rest:
          let more = await client.recvWithTimeout(1024, idleTimeout)
          if more.len == 0: break
          rest.add(more)
        let headerLine = "MIGRATE " & rest.strip()
        let parts = rest.strip().split(" ")
        if parts.len >= 2:
          let entryCount = try: parseInt(parts[1]) except CatchableError: 0
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
        await client.send(bytesToString(err))
        continue

      # Rate limiting for query messages
      if header.kind in {mkQuery, mkQueryParams}:
        let clientKey = "client-" & $clientId
        if not server.rateLimiter.allowRequest(clientKey):
          let err = serializeError(429, "Rate limit exceeded", header.requestId)
          await client.send(bytesToString(err))
          continue

      case header.kind
      of mkAuth:
        let tokenStr = parseAuthMessage(stringToBytes(payload))
        let (valid, userId, role, jwtDatabase) = verifyToken(secret, tokenStr)
        if valid:
          authenticated = true
          connCtx.currentUser = userId
          connCtx.currentRole = role
          let okMsg = makeAuthOkMessage(header.requestId)
          await client.send(bytesToString(okMsg))
          info("Client " & $clientId & " authenticated as " & userId)
          # Switch to database from JWT claim if provided
          if jwtDatabase.len > 0 and server.registry != nil and isValidDbName(jwtDatabase):
            let info = getDatabaseInfo(server.registry, jwtDatabase)
            if info != nil:
              let targetCtx = cast[ExecutionContext](cast[pointer](info.ctx))
              let oldDb = connCtx.currentDatabase
              connCtx.db = info.db
              connCtx.tables = targetCtx.tables
              connCtx.btrees = targetCtx.btrees
              connCtx.views = targetCtx.views
              connCtx.ftsIndexes = targetCtx.ftsIndexes
              connCtx.vectorIndexes = targetCtx.vectorIndexes
              connCtx.users = targetCtx.users
              connCtx.policies = targetCtx.policies
              connCtx.graphs = targetCtx.graphs
              connCtx.autoIncCounters = targetCtx.autoIncCounters
              connCtx.sequences = targetCtx.sequences
              connCtx.currentDatabase = jwtDatabase
              if oldDb.len > 0 and oldDb != jwtDatabase:
                decrementConnections(server.registry, oldDb)
              incrementConnections(server.registry, jwtDatabase)
        else:
          let err = makeErrorMessage(header.requestId, 403, "Invalid token")
          await client.send(bytesToString(err))

      of mkQuery:
        var pos = 0
        let queryStr = readString(stringToBytes(payload), pos)
        info("[" & $clientId & "] Query: " & queryStr)

        # Shard-aware routing: check if this node should handle the write
        var shardCheck = true
        if server.clusterMembership.nodes.len > 0:
          let stmts = try: parse(tokenize(queryStr)) except CatchableError: nil
          if stmts != nil:
            for stmt in stmts.stmts:
              if stmt.kind in {nkInsert, nkUpdate, nkDelete}:
                # If this node is not assigned to any shard, reject writes
                let localShards = server.shardRouter.getShardForNode(
                  server.clusterMembership.localNodeId)
                if localShards.len == 0:
                  shardCheck = false
                  let err = serializeError(3, "Node not assigned to any shard", header.requestId)
                  await client.send(bytesToString(err))
                break

        if shardCheck:
          let startTicks = getMonoTime().ticks()
          let (success, result, errorMsg) = await executeQuery(connCtx.db, connCtx, queryStr,
            replication=server.replicationManager, raftNode=server.raftNode,
            raftWriteTimeoutMs=server.config.raftWriteTimeoutMs,
            raftPeerClientAddrs=server.config.raftPeerClientAddrs,
            forwardTls=server.tls)
          let durationMs = int((getMonoTime().ticks() - startTicks) div 1_000_000)

          if durationMs >= slowThreshold:
            slowQueryLog(slowLog, queryStr, durationMs, clientId)

          if success:
            let dataMsg = serializeResult(result, header.requestId)
            await client.send(bytesToString(dataMsg))
            let completeMsg = serializeComplete(result.affectedRows, header.requestId)
            await client.send(bytesToString(completeMsg))
          else:
            let errorMsg = serializeError(1, errorMsg, header.requestId)
            await client.send(bytesToString(errorMsg))

      of mkQueryParams:
        let (queryStr, params) = readQueryParamsMessage(stringToBytes(payload))
        info("[" & $clientId & "] QueryParams: " & queryStr & " (" & $params.len & " params)")

        let startTicks = getMonoTime().ticks()
        let (success, result, errorMsg) = await executeQuery(connCtx.db, connCtx, queryStr, params,
          replication=server.replicationManager, raftNode=server.raftNode,
          raftWriteTimeoutMs=server.config.raftWriteTimeoutMs,
          raftPeerClientAddrs=server.config.raftPeerClientAddrs,
          forwardTls=server.tls)
        let durationMs = int((getMonoTime().ticks() - startTicks) div 1_000_000)

        if durationMs >= slowThreshold:
          slowQueryLog(slowLog, queryStr, durationMs, clientId)

        if success:
          let dataMsg = serializeResult(result, header.requestId)
          await client.send(bytesToString(dataMsg))
          let completeMsg = serializeComplete(result.affectedRows, header.requestId)
          await client.send(bytesToString(completeMsg))
        else:
          let errorMsg = serializeError(1, errorMsg, header.requestId)
          await client.send(bytesToString(errorMsg))

      of mkPing:
        var pongMsg = WireMessage(
          header: MessageHeader(kind: mkPong, length: 0, requestId: header.requestId),
          payload: @[],
        )
        await client.send(bytesToString(serializeMessage(pongMsg)))

      of mkClose:
        break

      else:
        let errorMsg = serializeError(2, "Unsupported message kind: " & $header.kind, header.requestId)
        await client.send(bytesToString(errorMsg))

  except Exception as e:
    errorMsg("Client " & $clientId & " error: " & e.msg)
  finally:
    # Decrement database connection counter
    if server.registry != nil and connCtx.currentDatabase.len > 0:
      decrementConnections(server.registry, connCtx.currentDatabase)
    acquire(server.activeConnectionsLock)
    try:
      if server.activeConnections > 0:
        dec server.activeConnections
    finally:
      release(server.activeConnectionsLock)
    info("Client " & $clientId & " disconnected")
    client.close()

proc setTcpNoDelay(sock: AsyncSocket) =
  ## Enable TCP_NODELAY using the correct protocol level (IPPROTO_TCP).
  ## asyncnet.setSockOpt uses SOL_SOCKET by default which fails for OptNoDelay.
  setSockOptInt(sock.getFd, IPPROTO_TCP.cint, TCP_NODELAY, 1)

proc run*(server: Server) {.async.} =
  server.running = true
  var clientId = 0

  # Start gossip protocol if configured
  if server.gossipProtocol != nil and server.gossipProtocol.gossipPort > 0:
    server.gossipProtocol.startGossip()
    info("Gossip protocol started on port " & $server.gossipProtocol.gossipPort)

  let sock = newAsyncSocket()
  sock.setSockOpt(OptReuseAddr, true)
  setTcpNoDelay(sock)
  sock.bindAddr(Port(server.config.port), server.config.address)
  sock.listen()
  if server.config.tlsEnabled:
    info("BaraDB TLS listening on " & server.config.address & ":" & $server.config.port)
  else:
    info("BaraDB listening on " & server.config.address & ":" & $server.config.port)
  while server.running:
    let client = await sock.accept()
    setTcpNoDelay(client)
    acquire(server.activeConnectionsLock)
    var shouldAccept = true
    try:
      if server.config.maxConnections > 0 and server.activeConnections >= server.config.maxConnections:
        shouldAccept = false
      else:
        inc server.activeConnections
    finally:
      release(server.activeConnectionsLock)
    if not shouldAccept:
      client.close()
      continue
    if server.tls != nil:
      try:
        server.tls.wrapServer(client)
      except Exception as e:
        errorMsg("TLS handshake failed: " & e.msg)
        acquire(server.activeConnectionsLock)
        try:
          if server.activeConnections > 0:
            dec server.activeConnections
        finally:
          release(server.activeConnectionsLock)
        client.close()
        continue
    inc clientId
    asyncCheck server.handleClient(client, clientId)

proc stop*(server: Server) =
  server.running = false
  if server.gossipProtocol != nil:
    server.gossipProtocol.stop()
  if server.registry != nil:
    server.registry.closeAll()
  else:
    server.db.close()
