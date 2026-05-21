## Replication — sync and async replication between nodes
import std/tables
import std/sets
import std/locks
import std/net
import std/posix
import std/strutils
import std/nativesockets
import std/monotimes
import std/asyncdispatch


type
  ReplicationMode* = enum
    rmSync    # synchronous — wait for all replicas
    rmAsync   # asynchronous — fire and forget
    rmSemiSync # semi-sync — wait for at least N replicas

  ReplicaState* = enum
    rsConnecting
    rsStreaming
    rsLagging
    rsDisconnected

  Replica* = ref object
    id*: string
    host*: string
    port*: int
    state*: ReplicaState
    lastAckLsn*: uint64
    lagBytes*: int
    lagTime*: int64  # nanoseconds
    lastSeen*: int64
    connected*: bool

  ReplicationManager* = ref object
    lock: Lock
    mode*: ReplicationMode
    replicas*: Table[string, Replica]
    currentLsn*: uint64
    syncReplicaCount*: int  # for semi-sync
    pendingAcks*: Table[uint64, HashSet[string]]  # lsn -> replica_ids waiting
    appliedLsn*: uint64

proc newReplica*(id: string, host: string, port: int): Replica =
  Replica(
    id: id, host: host, port: port,
    state: rsConnecting, lastAckLsn: 0,
    lagBytes: 0, lagTime: 0, lastSeen: 0,
    connected: false,
  )

proc newReplicationManager*(mode: ReplicationMode = rmAsync,
                            syncCount: int = 1): ReplicationManager =
  new(result)
  initLock(result.lock)
  result.mode = mode
  result.replicas = initTable[string, Replica]()
  result.currentLsn = 0
  result.syncReplicaCount = syncCount
  result.pendingAcks = initTable[uint64, HashSet[string]]()
  result.appliedLsn = 0

proc addReplica*(rm: ReplicationManager, replica: Replica) =
  acquire(rm.lock)
  rm.replicas[replica.id] = replica
  release(rm.lock)

proc removeReplica*(rm: ReplicationManager, id: string) =
  acquire(rm.lock)
  rm.replicas.del(id)
  release(rm.lock)

proc connectReplica*(rm: ReplicationManager, id: string) =
  acquire(rm.lock)
  if id in rm.replicas:
    rm.replicas[id].state = rsStreaming
    rm.replicas[id].connected = true
  release(rm.lock)

proc connectWithTimeout(sock: Socket, host: string, port: Port, timeoutMs: int): bool =
  ## Non-blocking connect with timeout to avoid hanging on unreachable hosts.
  sock.getFd.setBlocking(false)
  try:
    sock.connect(host, port)
    sock.getFd.setBlocking(true)
    return true
  except OSError:
    var fds = @[sock.getFd]
    if selectWrite(fds, timeoutMs) <= 0:
      return false
    # Verify connection actually succeeded via SO_ERROR
    var err: cint = 0
    var errLen = cint(sizeof(err)).SockLen
    discard posix.getsockopt(sock.getFd, 1'i32, 4'i32, addr err, addr errLen)
    sock.getFd.setBlocking(true)
    return err == 0

proc shipToReplica(replica: Replica, lsn: uint64, data: seq[byte]): bool =
  ## Send replication data to a replica via TCP.
  ## Protocol: "REP <lsn> <dataLen>\n<data>"
  ## Response: "ACK <lsn>\n" on success
  var sock = newSocket()
  defer: sock.close()
  if not connectWithTimeout(sock, replica.host, Port(replica.port), 500):
    return false
  let header = "REP " & $lsn & " " & $data.len & "\n"
  sock.send(header)
  if data.len > 0:
    sock.send(cast[string](data))
  var response = ""
  sock.readLine(response)
  let parts = response.strip().split(" ")
  return parts.len >= 2 and parts[0] == "ACK"

proc writeLsn*(rm: ReplicationManager, data: seq[byte]): uint64 =
  acquire(rm.lock)
  inc rm.currentLsn
  let lsn = rm.currentLsn

  var replicasToShip: seq[Replica]
  for id, replica in rm.replicas:
    if replica.connected and replica.host.len > 0 and replica.port > 0:
      replicasToShip.add(replica)

  case rm.mode
  of rmAsync:
    release(rm.lock)
    for replica in replicasToShip:
      discard shipToReplica(replica, lsn, data)
    return lsn
  of rmSync:
    if replicasToShip.len > 0:
      rm.pendingAcks[lsn] = initHashSet[string]()
      for replica in replicasToShip:
        rm.pendingAcks[lsn].incl(replica.id)
    release(rm.lock)
    var ackCount = 0
    var ackedIds: seq[string] = @[]
    for replica in replicasToShip:
      if shipToReplica(replica, lsn, data):
        inc ackCount
        ackedIds.add(replica.id)
    # Clean up pendingAcks for successfully acked replicas
    acquire(rm.lock)
    if lsn in rm.pendingAcks:
      for id in ackedIds:
        rm.pendingAcks[lsn].excl(id)
      if rm.pendingAcks[lsn].len == 0:
        rm.pendingAcks.del(lsn)
    release(rm.lock)
    if replicasToShip.len > 0 and ackCount < replicasToShip.len:
      when defined(debug):
        echo "Replication sync: only ", ackCount, "/", replicasToShip.len, " replicas acked for LSN ", lsn
    return lsn
  of rmSemiSync:
    if replicasToShip.len > 0:
      rm.pendingAcks[lsn] = initHashSet[string]()
      var count = 0
      for replica in replicasToShip:
        if count < rm.syncReplicaCount:
          rm.pendingAcks[lsn].incl(replica.id)
          inc count
    release(rm.lock)
    var ackCount = 0
    var ackedIds: seq[string] = @[]
    for replica in replicasToShip:
      if shipToReplica(replica, lsn, data):
        inc ackCount
        ackedIds.add(replica.id)
        if ackCount >= rm.syncReplicaCount:
          break
    # Clean up pendingAcks for successfully acked replicas
    acquire(rm.lock)
    if lsn in rm.pendingAcks:
      for id in ackedIds:
        rm.pendingAcks[lsn].excl(id)
      if rm.pendingAcks[lsn].len == 0:
        rm.pendingAcks.del(lsn)
    release(rm.lock)
    if replicasToShip.len > 0 and ackCount == 0 and rm.syncReplicaCount > 0:
      when defined(debug):
        echo "Replication semi-sync: no replicas acked for LSN ", lsn
    return lsn

proc ackLsn*(rm: ReplicationManager, replicaId: string, lsn: uint64) =
  acquire(rm.lock)
  if replicaId in rm.replicas:
    rm.replicas[replicaId].lastAckLsn = max(rm.replicas[replicaId].lastAckLsn, lsn)
    rm.replicas[replicaId].lagBytes = int(rm.currentLsn - lsn)

  if lsn in rm.pendingAcks:
    rm.pendingAcks[lsn].excl(replicaId)
    if rm.pendingAcks[lsn].len == 0:
      rm.pendingAcks.del(lsn)
      rm.appliedLsn = max(rm.appliedLsn, lsn)

  release(rm.lock)

proc isFullyAcked*(rm: ReplicationManager, lsn: uint64): bool =
  acquire(rm.lock)
  result = lsn notin rm.pendingAcks
  release(rm.lock)

proc minAckLsn*(rm: ReplicationManager): uint64 =
  acquire(rm.lock)
  result = rm.appliedLsn
  release(rm.lock)

proc connectedReplicaCount*(rm: ReplicationManager): int =
  acquire(rm.lock)
  result = 0
  for id, replica in rm.replicas:
    if replica.connected:
      inc result
  release(rm.lock)

proc totalReplicaCount*(rm: ReplicationManager): int =
  acquire(rm.lock)
  result = rm.replicas.len
  release(rm.lock)

proc maxLag*(rm: ReplicationManager): int =
  acquire(rm.lock)
  result = 0
  for id, replica in rm.replicas:
    if replica.lagBytes > result:
      result = replica.lagBytes
  release(rm.lock)

proc replicaStatus*(rm: ReplicationManager): seq[(string, ReplicaState, int)] =
  acquire(rm.lock)
  result = @[]
  for id, replica in rm.replicas:
    result.add((id, replica.state, replica.lagBytes))
  release(rm.lock)

proc switchMode*(rm: ReplicationManager, mode: ReplicationMode) =
  acquire(rm.lock)
  rm.mode = mode
  release(rm.lock)

# ---------------------------------------------------------------------------
# Health check and reconnection
# ---------------------------------------------------------------------------

proc healthCheck*(rm: ReplicationManager) =
  acquire(rm.lock)
  var replicas: seq[(string, Replica)] = @[]
  for id, replica in rm.replicas:
    if replica.connected:
      replicas.add((id, replica))
  release(rm.lock)

  for (id, replica) in replicas:
    var connected = true
    var sock = newSocket()
    try:
      if not connectWithTimeout(sock, replica.host, Port(replica.port), 1000):
        connected = false
      else:
        defer: sock.close()
        sock.send("PING\n")
        var response = ""
        try:
          sock.readLine(response)
          if response.strip() != "PONG":
            connected = false
        except:
          connected = false
    except:
      connected = false
    finally:
      sock.close()

    if not connected:
      acquire(rm.lock)
      if id in rm.replicas:
        rm.replicas[id].connected = false
        rm.replicas[id].state = rsDisconnected
      release(rm.lock)

proc reconnectReplica*(rm: ReplicationManager, id: string): bool =
  result = false
  var replica: Replica
  var found = false
  acquire(rm.lock)
  if id in rm.replicas:
    replica = rm.replicas[id]
    found = true
  release(rm.lock)
  if not found: return false
  if replica.connected or replica.host.len == 0 or replica.port == 0: return false

  var sock = newSocket()
  defer: sock.close()
  if connectWithTimeout(sock, replica.host, Port(replica.port), 2000):
    acquire(rm.lock)
    if id in rm.replicas:
      rm.replicas[id].connected = true
      rm.replicas[id].state = rsStreaming
      rm.replicas[id].lastSeen = getMonoTime().ticks()
      result = true
    release(rm.lock)

proc reconnectAll*(rm: ReplicationManager): int =
  acquire(rm.lock)
  var candidates: seq[(string, Replica)] = @[]
  for id, replica in rm.replicas:
    if not replica.connected and replica.host.len > 0 and replica.port > 0:
      candidates.add((id, replica))
  release(rm.lock)

  result = 0
  for (id, replica) in candidates:
    var sock = newSocket()
    defer: sock.close()
    if connectWithTimeout(sock, replica.host, Port(replica.port), 2000):
      acquire(rm.lock)
      if id in rm.replicas:
        rm.replicas[id].connected = true
        rm.replicas[id].state = rsStreaming
        rm.replicas[id].lastSeen = getMonoTime().ticks()
      release(rm.lock)
      inc result

proc startHealthCheck*(rm: ReplicationManager, intervalMs: int = 5000) {.async.} =
  while true:
    await sleepAsync(intervalMs)
    rm.healthCheck()

proc startReconnectionLoop*(rm: ReplicationManager, intervalMs: int = 10000) {.async.} =
  while true:
    await sleepAsync(intervalMs)
    discard rm.reconnectAll()
