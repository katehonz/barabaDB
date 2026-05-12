## Deadlock Detection — wait-for graph
import std/tables
import std/sets
import std/algorithm

type
  WaitEdge* = object
    waiter*: uint64    # txn id waiting
    holder*: uint64    # txn id holding the resource

  DeadlockDetector* = ref object
    edges: seq[WaitEdge]
    adjacency: Table[uint64, seq[uint64]]  # waiter -> holders
    txnIds: HashSet[uint64]

proc newDeadlockDetector*(): DeadlockDetector =
  DeadlockDetector(
    edges: @[],
    adjacency: initTable[uint64, seq[uint64]](),
    txnIds: initHashSet[uint64](),
  )

proc addWait*(dd: DeadlockDetector, waiter, holder: uint64) =
  dd.edges.add(WaitEdge(waiter: waiter, holder: holder))
  dd.txnIds.incl(waiter)
  dd.txnIds.incl(holder)
  if waiter notin dd.adjacency:
    dd.adjacency[waiter] = @[]
  dd.adjacency[waiter].add(holder)

proc removeWait*(dd: DeadlockDetector, waiter, holder: uint64) =
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

proc detectCycle*(dd: DeadlockDetector): seq[uint64] =
  var visited = initHashSet[uint64]()
  var inStack = initHashSet[uint64]()
  var parent = initTable[uint64, uint64]()

  proc dfs(node: uint64): seq[uint64] =
    visited.incl(node)
    inStack.incl(node)
    for neighbor in dd.adjacency.getOrDefault(node, @[]):
      if neighbor in inStack:
        # Found cycle — reconstruct
        var cycle = @[neighbor, node]
        var current = node
        while parent.getOrDefault(current, 0'u64) != neighbor and
              parent.getOrDefault(current, 0'u64) != 0:
          current = parent[current]
          if current == 0: break
          cycle.add(current)
        # Verify we actually closed the cycle back to neighbor
        if cycle[^1] != neighbor and parent.getOrDefault(cycle[^1], 0'u64) == neighbor:
          cycle.add(neighbor)
        elif cycle[^1] != neighbor:
          # Incomplete cycle — should not happen with valid parent chain
          return @[]
        cycle.reverse()
        return cycle
      if neighbor notin visited:
        parent[neighbor] = node
        let cycle = dfs(neighbor)
        if cycle.len > 0:
          return cycle
    inStack.excl(node)
    return @[]

  for txnId in dd.txnIds:
    if txnId notin visited:
      let cycle = dfs(txnId)
      if cycle.len > 0:
        return cycle
  return @[]

proc findDeadlockVictim*(dd: DeadlockDetector): uint64 =
  let cycle = dd.detectCycle()
  if cycle.len == 0:
    return 0
  # Choose youngest txn (highest id) as victim
  result = cycle[0]
  for id in cycle:
    if id > result:
      result = id

proc hasDeadlock*(dd: DeadlockDetector): bool =
  return dd.detectCycle().len > 0

proc clear*(dd: DeadlockDetector) =
  dd.edges.setLen(0)
  dd.adjacency.clear()
  dd.txnIds.clear()

proc edgeCount*(dd: DeadlockDetector): int = dd.edges.len
proc txnCount*(dd: DeadlockDetector): int = dd.txnIds.len
