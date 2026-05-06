## Replication — sync and async replication between nodes
import std/tables
import std/sets
import std/locks

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
    lagBytes: 0, lagTime: 0, connected: false,
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

proc disconnectReplica*(rm: ReplicationManager, id: string) =
  acquire(rm.lock)
  if id in rm.replicas:
    rm.replicas[id].state = rsDisconnected
    rm.replicas[id].connected = false
  release(rm.lock)

proc writeLsn*(rm: ReplicationManager, data: seq[byte]): uint64 =
  acquire(rm.lock)
  inc rm.currentLsn
  let lsn = rm.currentLsn

  case rm.mode
  of rmAsync:
    # Fire and forget — don't wait
    release(rm.lock)
    return lsn
  of rmSync:
    # Wait for all replicas
    rm.pendingAcks[lsn] = initHashSet[string]()
    for id, replica in rm.replicas:
      if replica.connected:
        rm.pendingAcks[lsn].incl(id)
    release(rm.lock)
    return lsn
  of rmSemiSync:
    # Wait for N replicas
    rm.pendingAcks[lsn] = initHashSet[string]()
    var count = 0
    for id, replica in rm.replicas:
      if replica.connected and count < rm.syncReplicaCount:
        rm.pendingAcks[lsn].incl(id)
        inc count
    release(rm.lock)
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
