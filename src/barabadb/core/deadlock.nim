## Deadlock Detection — wait-for graph
import std/tables
import std/sets
import std/locks

type
  WaitEdge* = object
    waiter*: uint64    # txn id waiting
    holder*: uint64    # txn id holding the resource

  DeadlockDetector* = ref object
    edges: seq[WaitEdge]
    adjacency: Table[uint64, seq[uint64]]  # waiter -> holders
    txnIds: HashSet[uint64]
    lock: Lock

proc newDeadlockDetector*(): DeadlockDetector =
  new(result)
  initLock(result.lock)
  result.edges = @[]
  result.adjacency = initTable[uint64, seq[uint64]]()
  result.txnIds = initHashSet[uint64]()

proc addWait*(dd: DeadlockDetector, waiter, holder: uint64) =
  acquire(dd.lock)
  defer: release(dd.lock)
  dd.edges.add(WaitEdge(waiter: waiter, holder: holder))
  dd.txnIds.incl(waiter)
  dd.txnIds.incl(holder)
  if waiter notin dd.adjacency:
    dd.adjacency[waiter] = @[]
  dd.adjacency[waiter].add(holder)

proc removeWait*(dd: DeadlockDetector, waiter, holder: uint64) =
  acquire(dd.lock)
  defer: release(dd.lock)
  var newEdges: seq[WaitEdge] = @[]
  for edge in dd.edges:
    if edge.waiter != waiter or edge.holder != holder:
      newEdges.add(edge)
  dd.edges = newEdges

  if waiter in dd.adjacency:
    var newAdj: seq[uint64] = @[]
    for h in dd.adjacency[waiter]:
      if h != holder:
        newAdj.add(h)
    dd.adjacency[waiter] = newAdj

proc removeTxn*(dd: DeadlockDetector, txnId: uint64) =
  acquire(dd.lock)
  defer: release(dd.lock)
  dd.txnIds.excl(txnId)
  dd.adjacency.del(txnId)
  var newEdges: seq[WaitEdge] = @[]
  for edge in dd.edges:
    if edge.waiter != txnId and edge.holder != txnId:
      newEdges.add(edge)
  dd.edges = newEdges
  for wid, holders in dd.adjacency.mpairs:
    var newH: seq[uint64] = @[]
    for h in holders:
      if h != txnId:
        newH.add(h)
    holders = newH

proc detectCycleUnsafe(dd: DeadlockDetector): seq[uint64] =
  var visited = initHashSet[uint64]()
  var inStack = initHashSet[uint64]()

  proc dfs(node: uint64, path: seq[uint64]): seq[uint64] =
    visited.incl(node)
    inStack.incl(node)
    var newPath = path & @[node]
    for neighbor in dd.adjacency.getOrDefault(node, @[]):
      if neighbor in inStack:
        # Found cycle — reconstruct from path
        var cycle: seq[uint64] = @[]
        var found = false
        for n in newPath:
          if n == neighbor:
            found = true
          if found:
            cycle.add(n)
        cycle.add(neighbor)
        return cycle
      if neighbor notin visited:
        let cycle = dfs(neighbor, newPath)
        if cycle.len > 0:
          return cycle
    inStack.excl(node)
    return @[]

  for txnId in dd.txnIds:
    if txnId notin visited:
      let cycle = dfs(txnId, @[])
      if cycle.len > 0:
        return cycle
  return @[]

proc detectCycle*(dd: DeadlockDetector): seq[uint64] =
  acquire(dd.lock)
  defer: release(dd.lock)
  detectCycleUnsafe(dd)

proc findDeadlockVictim*(dd: DeadlockDetector): uint64 =
  acquire(dd.lock)
  defer: release(dd.lock)
  let cycle = detectCycleUnsafe(dd)
  if cycle.len == 0:
    return 0
  # Choose youngest txn (highest id) as victim
  result = cycle[0]
  for id in cycle:
    if id > result:
      result = id

proc hasDeadlock*(dd: DeadlockDetector): bool =
  acquire(dd.lock)
  defer: release(dd.lock)
  return detectCycleUnsafe(dd).len > 0

proc clear*(dd: DeadlockDetector) =
  acquire(dd.lock)
  defer: release(dd.lock)
  dd.edges.setLen(0)
  dd.adjacency.clear()
  dd.txnIds.clear()

proc edgeCount*(dd: DeadlockDetector): int =
  acquire(dd.lock)
  defer: release(dd.lock)
  dd.edges.len

proc txnCount*(dd: DeadlockDetector): int =
  acquire(dd.lock)
  defer: release(dd.lock)
  dd.txnIds.len
