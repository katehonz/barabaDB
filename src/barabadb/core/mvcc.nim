## MVCC — Multi-Version Concurrency Control
import std/tables
import std/locks
import std/monotimes
import std/sets
import deadlock

type
  TxnId* = distinct uint64
  Lsn* = distinct uint64  # Log Sequence Number

  TxnState* = enum
    tsActive
    tsCommitted
    tsAborted

  IsolationLevel* = enum
    ilReadCommitted
    ilRepeatableRead
    ilSerializable

  VersionedRecord* = ref object
    key*: string
    value*: seq[byte]
    xmin*: TxnId  # creating transaction
    xmax*: TxnId  # deleting transaction (0 = not deleted)
    lsn*: Lsn

  Transaction* = ref object
    id*: TxnId
    state*: TxnState
    isolation*: IsolationLevel
    snapshotTxns: HashSet[TxnId]  # active txns at snapshot time
    snapshotMaxTxn: TxnId         # max txn id at snapshot time
    writeSet*: Table[string, VersionedRecord]
    readSet*: HashSet[string]
    startTime*: int64
    savepoints*: seq[Table[string, VersionedRecord]]

  TxnManager* = ref object
    lock: Lock
    nextTxnId: uint64
    nextLsn: uint64
    activeTxns: Table[TxnId, Transaction]
    committedTxns: seq[TxnId]
    committedTxnsSet: HashSet[TxnId]
    abortedTxns: HashSet[TxnId]
    globalVersions*: Table[string, seq[VersionedRecord]]
    txnTimeoutMs: int64
    deadlockDetector*: DeadlockDetector

proc `==`*(a, b: TxnId): bool {.borrow.}
proc `==`*(a, b: Lsn): bool {.borrow.}
proc `$`*(id: TxnId): string = $uint64(id)
proc `$`*(lsn: Lsn): string = $uint64(lsn)

proc newTxnManager*(txnTimeoutMs: int64 = 30000): TxnManager =
  new(result)
  initLock(result.lock)
  result.nextTxnId = 1
  result.nextLsn = 1
  result.activeTxns = initTable[TxnId, Transaction]()
  result.committedTxns = @[]
  result.committedTxnsSet = initHashSet[TxnId]()
  result.abortedTxns = initHashSet[TxnId]()
  result.globalVersions = initTable[string, seq[VersionedRecord]]()
  result.txnTimeoutMs = txnTimeoutMs
  result.deadlockDetector = newDeadlockDetector()

proc allocTxnId(tm: TxnManager): TxnId =
  result = TxnId(tm.nextTxnId)
  inc tm.nextTxnId

proc allocLsn(tm: TxnManager): Lsn =
  result = Lsn(tm.nextLsn)
  inc tm.nextLsn

proc getSnapshot(tm: TxnManager, excludeId: TxnId): (HashSet[TxnId], TxnId) =
  var active = initHashSet[TxnId]()
  for txnId, txn in tm.activeTxns:
    if txnId != excludeId and txn.state == tsActive:
      active.incl(txnId)
  return (active, TxnId(tm.nextTxnId - 1))

proc beginTxn*(tm: TxnManager, isolation: IsolationLevel = ilReadCommitted): Transaction =
  acquire(tm.lock)
  let txnId = tm.allocTxnId()
  let (snapTxns, snapMax) = tm.getSnapshot(txnId)
  let txn = Transaction(
    id: txnId,
    state: tsActive,
    isolation: isolation,
    snapshotTxns: snapTxns,
    snapshotMaxTxn: snapMax,
    writeSet: initTable[string, VersionedRecord](),
    readSet: initHashSet[string](),
    startTime: getMonoTime().ticks(),
    savepoints: @[],
  )
  tm.activeTxns[txnId] = txn
  release(tm.lock)
  return txn

proc isVisible(tm: TxnManager, txn: Transaction, version: VersionedRecord): bool =
  let creator = version.xmin
  let deleter = version.xmax

  # Can't see own aborted writes from other txns
  if creator == txn.id:
    if creator in tm.activeTxns and tm.activeTxns[creator].state == tsAborted:
      return false
    return deleter == TxnId(0) or deleter == txn.id

  # Creator must be committed and visible in snapshot
  if uint64(creator) > uint64(txn.snapshotMaxTxn):
    return false
  if creator in txn.snapshotTxns:
    return false
  if creator in tm.abortedTxns:
    return false
  if creator in tm.activeTxns and tm.activeTxns[creator].state != tsCommitted:
    return false
  # If creator is not active and not committed, it must be aborted
  if creator notin tm.activeTxns and creator notin tm.committedTxnsSet:
    return false

  # Deleter must not be a visible committed txn
  if deleter != TxnId(0):
    if deleter == txn.id:
      return false
    if uint64(deleter) <= uint64(txn.snapshotMaxTxn) and
       deleter notin txn.snapshotTxns:
      if deleter in tm.activeTxns:
        if tm.activeTxns[deleter].state == tsCommitted:
          return false
      else:
        return false

  return true

proc read*(tm: TxnManager, txn: Transaction, key: string): (bool, seq[byte]) =
  acquire(tm.lock)
  # Check write buffer first
  if key in txn.writeSet:
    let version = txn.writeSet[key]
    release(tm.lock)
    if version.value == @[]:
      return (false, @[])
    return (true, version.value)

  # Search global versions
  if key in tm.globalVersions:
    var latest: VersionedRecord = nil
    for version in tm.globalVersions[key]:
      if tm.isVisible(txn, version):
        if latest == nil or uint64(version.lsn) > uint64(latest.lsn):
          latest = version
    if latest != nil:
      txn.readSet.incl(key)
      release(tm.lock)
      if latest.value == @[]:
        return (false, @[])
      return (true, latest.value)

  release(tm.lock)
  return (false, @[])

proc write*(tm: TxnManager, txn: Transaction, key: string, value: seq[byte]): bool =
  acquire(tm.lock)
  if txn.state != tsActive:
    release(tm.lock)
    return false

  # Timeout-based deadlock detection: abort stale transactions
  let now = getMonoTime().ticks()
  for otherId, otherTxn in tm.activeTxns:
    if otherId != txn.id and otherTxn.state == tsActive:
      if now - otherTxn.startTime > tm.txnTimeoutMs * 1_000_000:
        otherTxn.state = tsAborted
        tm.activeTxns.del(otherId)

  # Check for write-write conflict against other active transactions' write sets
  for otherId, otherTxn in tm.activeTxns:
    if otherId != txn.id and otherTxn.state == tsActive:
      if key in otherTxn.writeSet:
        # Wait-for graph: txn is waiting for otherId to finish
        tm.deadlockDetector.addWait(uint64(txn.id), uint64(otherId))
        if tm.deadlockDetector.hasDeadlock():
          let victimId = TxnId(tm.deadlockDetector.findDeadlockVictim())
          tm.deadlockDetector.removeTxn(uint64(victimId))
          if victimId in tm.activeTxns:
            tm.activeTxns[victimId].state = tsAborted
            tm.activeTxns.del(victimId)
        release(tm.lock)
        return false  # write-write conflict with uncommitted txn

  # Check for write-write conflict with committed versions
  if key notin txn.writeSet:
    if key in tm.globalVersions:
      for version in tm.globalVersions[key]:
        if version.xmax == TxnId(0):  # not deleted
          let creator = version.xmin
          if creator != txn.id:
            # Check if the writer is concurrent and committed
            if creator in txn.snapshotTxns or uint64(creator) > uint64(txn.snapshotMaxTxn):
              if creator in tm.activeTxns:
                if tm.activeTxns[creator].state == tsCommitted:
                  release(tm.lock)
                  return false  # write-write conflict
              else:
                # Creator already completed — check if it committed
                # If not in activeTxns, it either committed or aborted
                # We treat completed-but-visible as a conflict
                release(tm.lock)
                return false  # write-write conflict with completed txn

  let lsn = tm.allocLsn()
  let version = VersionedRecord(
    key: key,
    value: value,
    xmin: txn.id,
    xmax: TxnId(0),
    lsn: lsn,
  )
  txn.writeSet[key] = version
  release(tm.lock)
  return true

proc delete*(tm: TxnManager, txn: Transaction, key: string): bool =
  return tm.write(txn, key, @[])

proc compactVersions*(tm: TxnManager)

proc commit*(tm: TxnManager, txn: Transaction): bool =
  acquire(tm.lock)
  if txn.state != tsActive:
    release(tm.lock)
    return false

  # Apply write set to global versions
  for key, version in txn.writeSet:
    if key notin tm.globalVersions:
      tm.globalVersions[key] = @[]

    # Mark previous versions as deleted by this txn
    # Only mark versions that were visible to this transaction
    for i in 0..<tm.globalVersions[key].len:
      if tm.globalVersions[key][i].xmax == TxnId(0):
        let creator = tm.globalVersions[key][i].xmin
        # Only mark as deleted if the version was visible (committed before our snapshot)
        if creator != txn.id:
          if uint64(creator) <= uint64(txn.snapshotMaxTxn) and
             creator notin txn.snapshotTxns:
            tm.globalVersions[key][i].xmax = txn.id

    tm.globalVersions[key].add(version)

  txn.state = tsCommitted
  tm.committedTxns.add(txn.id)
  tm.committedTxnsSet.incl(txn.id)
  tm.activeTxns.del(txn.id)
  tm.deadlockDetector.removeTxn(uint64(txn.id))

  # Compact version chains periodically (every 100 commits)
  if tm.committedTxns.len mod 100 == 0:
    tm.compactVersions()

  release(tm.lock)
  return true

proc compactVersions*(tm: TxnManager) =
  ## Remove old overwritten versions that are no longer visible to any active transaction.
  for key, versions in tm.globalVersions.mpairs:
    if versions.len <= 3:
      continue
    var newVersions: seq[VersionedRecord] = @[]
    for i in 0..<versions.len:
      let v = versions[i]
      # Always keep the latest (non-deleted) version
      if v.xmax == TxnId(0):
        newVersions.add(v)
        continue
      # For old overwritten versions, check if any active txn might still see them
      var mightBeVisible = false
      for txnId, txn in tm.activeTxns:
        if txn.state == tsActive:
          # A version is visible if its creator is not newer than snapshotMaxTxn
          # and the creator was committed at snapshot time
          if uint64(v.xmin) <= uint64(txn.snapshotMaxTxn) and
             v.xmin notin txn.snapshotTxns and
             v.xmin notin tm.abortedTxns:
            mightBeVisible = true
            break
      if mightBeVisible:
        newVersions.add(v)
    versions = newVersions

proc abortTxn*(tm: TxnManager, txn: Transaction): bool =
  acquire(tm.lock)
  if txn.state != tsActive:
    release(tm.lock)
    return false
  txn.state = tsAborted
  tm.activeTxns.del(txn.id)
  tm.abortedTxns.incl(txn.id)
  tm.deadlockDetector.removeTxn(uint64(txn.id))
  release(tm.lock)
  return true

proc savepoint*(tm: TxnManager, txn: Transaction) =
  txn.savepoints.add(txn.writeSet)

proc rollbackToSavepoint*(tm: TxnManager, txn: Transaction): bool =
  if txn.savepoints.len == 0:
    return false
  txn.writeSet = txn.savepoints.pop()
  return true

proc activeCount*(tm: TxnManager): int =
  acquire(tm.lock)
  result = tm.activeTxns.len
  release(tm.lock)

proc txnId*(txn: Transaction): TxnId = txn.id
proc state*(txn: Transaction): TxnState = txn.state
proc isolation*(txn: Transaction): IsolationLevel = txn.isolation
