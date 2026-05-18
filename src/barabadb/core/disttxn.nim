## Distributed Transactions — cross-node atomic operations
import std/tables
import std/locks
import std/monotimes
import std/net
import std/strutils
import std/nativesockets

type
  DistTxnState* = enum
    dtsActive
    dtsPreparing
    dtsPrepared
    dtsCommitting
    dtsCommitted
    dtsAborting
    dtsAborted

  DistTxnParticipant* = object
    nodeId*: string
    host*: string
    port*: int
    prepared*: bool
    committed*: bool
    aborted*: bool
    errorMsg*: string

  DistributedTransaction* = ref object
    id*: uint64
    coordinator*: string
    participants*: Table[string, DistTxnParticipant]
    state*: DistTxnState
    timeout*: int64  # nanoseconds
    startTime*: int64
    lock: Lock

  DistTxnManager* = ref object
    lock: Lock
    nextId: uint64
    activeTxns*: Table[uint64, DistributedTransaction]
    timeoutNs*: int64
    defaultTimeout*: int64

proc newDistributedTransaction*(coordinator: string,
                                timeout: int64 = 30_000_000_000): DistributedTransaction =
  new(result)
  initLock(result.lock)
  result.coordinator = coordinator
  result.participants = initTable[string, DistTxnParticipant]()
  result.state = dtsActive
  result.timeout = timeout
  result.startTime = getMonoTime().ticks()

proc newDistTxnManager*(): DistTxnManager =
  new(result)
  initLock(result.lock)
  result.nextId = 1
  result.activeTxns = initTable[uint64, DistributedTransaction]()
  result.timeoutNs = 60_000_000_000  # 1 minute
  result.defaultTimeout = 30_000_000_000  # 30 seconds

proc beginTransaction*(tm: DistTxnManager, coordinator: string): DistributedTransaction =
  acquire(tm.lock)
  result = newDistributedTransaction(coordinator, tm.defaultTimeout)
  result.id = tm.nextId
  inc tm.nextId
  tm.activeTxns[result.id] = result
  release(tm.lock)

proc addParticipant*(txn: DistributedTransaction, nodeId: string,
                     host: string = "", port: int = 0) =
  acquire(txn.lock)
  txn.participants[nodeId] = DistTxnParticipant(
    nodeId: nodeId, host: host, port: port,
    prepared: false, committed: false, aborted: false,
  )
  release(txn.lock)

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
    sock.getFd.setBlocking(true)
    return true

proc sendDistTxnRpc(host: string, port: int, txnId: uint64, action: string, timeoutMs: int = 5000): bool =
  ## Send 2PC RPC to participant node via TCP text protocol.
  ## Protocol: "DISTTXN <txnId> <action>\n" where action = PREPARE|COMMIT|ROLLBACK
  ## Response: "OK\n" or "ERR <msg>\n"
  try:
    var sock = newSocket()
    if not connectWithTimeout(sock, host, Port(port), timeoutMs):
      sock.close()
      return false
    let msg = "DISTTXN " & $txnId & " " & action & "\n"
    sock.send(msg)
    var response = ""
    sock.readLine(response)
    sock.close()
    return response.strip() == "OK"
  except CatchableError:
    return false

type
  ParticipantInfo = object
    nodeId: string
    host: string
    port: int

proc prepare*(txn: DistributedTransaction): bool =
  # Phase 1: validate state and collect participants while holding lock
  var participants: seq[ParticipantInfo] = @[]
  var wasActive = false
  acquire(txn.lock)
  if txn.state == dtsActive:
    txn.state = dtsPreparing
    wasActive = true
    for nodeId, participant in txn.participants:
      if participant.host.len > 0 and participant.port > 0:
        participants.add(ParticipantInfo(nodeId: nodeId, host: participant.host, port: participant.port))
  release(txn.lock)

  if not wasActive:
    return false

  # Phase 2: perform network I/O without holding the lock
  var preparedNodes: seq[string] = @[]
  var allOk = true
  for p in participants:
    let ok = sendDistTxnRpc(p.host, p.port, txn.id, "PREPARE")
    if ok:
      preparedNodes.add(p.nodeId)
    else:
      allOk = false

  # Phase 3: update state while holding lock
  acquire(txn.lock)
  if allOk:
    txn.state = dtsPrepared
    for nodeId, _ in txn.participants.mpairs:
      txn.participants[nodeId].prepared = true
  else:
    # Rollback already-prepared participants
    for nodeId in preparedNodes:
      if txn.participants.hasKey(nodeId):
        discard sendDistTxnRpc(txn.participants[nodeId].host, txn.participants[nodeId].port, txn.id, "ROLLBACK")
        txn.participants[nodeId].prepared = false
        txn.participants[nodeId].aborted = true
    txn.state = dtsAborted
  release(txn.lock)
  return allOk

proc commit*(txn: DistributedTransaction): bool =
  # Phase 1: validate state and collect participants while holding lock
  var participants: seq[ParticipantInfo] = @[]
  var wasPrepared = false
  acquire(txn.lock)
  if txn.state == dtsPrepared:
    txn.state = dtsCommitting
    wasPrepared = true
    for nodeId, participant in txn.participants:
      if participant.host.len > 0 and participant.port > 0:
        participants.add(ParticipantInfo(nodeId: nodeId, host: participant.host, port: participant.port))
  release(txn.lock)

  if not wasPrepared:
    return false

  # Phase 2: perform network I/O without holding the lock
  var committedNodes: seq[string] = @[]
  var allOk = true
  for p in participants:
    let ok = sendDistTxnRpc(p.host, p.port, txn.id, "COMMIT")
    if ok:
      committedNodes.add(p.nodeId)
    else:
      allOk = false

  # Phase 3: update state while holding lock
  acquire(txn.lock)
  if allOk:
    txn.state = dtsCommitted
    for nodeId, _ in txn.participants.mpairs:
      txn.participants[nodeId].committed = true
  elif committedNodes.len > 0:
    txn.state = dtsCommitted
    for nodeId in committedNodes:
      if txn.participants.hasKey(nodeId):
        txn.participants[nodeId].committed = true
  else:
    txn.state = dtsAborted
  release(txn.lock)
  return allOk or committedNodes.len > 0

proc rollback*(txn: DistributedTransaction): bool =
  # Phase 1: validate state and collect participants while holding lock
  var participants: seq[ParticipantInfo] = @[]
  var canRollback = false
  acquire(txn.lock)
  if txn.state in {dtsActive, dtsPreparing, dtsPrepared}:
    txn.state = dtsAborting
    canRollback = true
    for nodeId, participant in txn.participants:
      if participant.host.len > 0 and participant.port > 0:
        participants.add(ParticipantInfo(nodeId: nodeId, host: participant.host, port: participant.port))
  release(txn.lock)

  if not canRollback:
    return false

  # Phase 2: perform network I/O without holding the lock
  for p in participants:
    discard sendDistTxnRpc(p.host, p.port, txn.id, "ROLLBACK")

  # Phase 3: update state while holding lock
  acquire(txn.lock)
  txn.state = dtsAborted
  release(txn.lock)
  return true

proc participantCount*(txn: DistributedTransaction): int =
  acquire(txn.lock)
  result = txn.participants.len
  release(txn.lock)

proc state*(txn: DistributedTransaction): DistTxnState =
  acquire(txn.lock)
  result = txn.state
  release(txn.lock)

proc isCommitted*(txn: DistributedTransaction): bool =
  return txn.state() == dtsCommitted

proc isAborted*(txn: DistributedTransaction): bool =
  return txn.state() == dtsAborted

proc getTxn*(tm: DistTxnManager, id: uint64): DistributedTransaction =
  acquire(tm.lock)
  result = tm.activeTxns.getOrDefault(id, nil)
  release(tm.lock)

proc cleanupCompleted*(tm: DistTxnManager) =
  acquire(tm.lock)
  var toRemove: seq[uint64] = @[]
  for id, txn in tm.activeTxns:
    if txn.state == dtsCommitted or txn.state == dtsAborted:
      toRemove.add(id)
  for id in toRemove:
    tm.activeTxns.del(id)
  release(tm.lock)

proc activeCount*(tm: DistTxnManager): int =
  acquire(tm.lock)
  result = tm.activeTxns.len
  release(tm.lock)

# Saga pattern for long-running distributed transactions
type
  SagaStep* = object
    name*: string
    nodeId*: string
    execute*: proc(): bool {.gcsafe.}  # returns true on success
    compensate*: proc() {.gcsafe.}      # undo the step

  Saga* = ref object
    steps*: seq[SagaStep]
    completedSteps*: seq[int]  # indices of completed steps

proc newSaga*(): Saga =
  Saga(steps: @[], completedSteps: @[])

proc addStep*(saga: Saga, step: SagaStep) =
  saga.steps.add(step)

proc execute*(saga: Saga): bool =
  saga.completedSteps = @[]
  for i, step in saga.steps:
    if step.execute():
      saga.completedSteps.add(i)
    else:
      # Rollback: compensate completed steps in reverse order
      for j in countdown(saga.completedSteps.len - 1, 0):
        let idx = saga.completedSteps[j]
        saga.steps[idx].compensate()
      return false
  return true

proc stepCount*(saga: Saga): int = saga.steps.len
proc completedCount*(saga: Saga): int = saga.completedSteps.len
