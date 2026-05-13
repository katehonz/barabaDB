## Sharding — hash-based and range-based data distribution with data migration
import std/hashes
import std/algorithm
import std/net
import std/strutils
import std/nativesockets
import std/tables

type
  ShardStrategy* = enum
    ssHash = "hash"
    ssRange = "range"
    ssConsistent = "consistent"

  Shard* = object
    id*: int
    name*: string
    minKey*: string
    maxKey*: string
    nodeIds*: seq[string]  # replica node ids
    isActive*: bool
    entryCount*: int

  ShardRouter* = ref object
    strategy*: ShardStrategy
    shards*: seq[Shard]
    vnodeRing*: seq[(uint64, int)]  # (hash, shard_id) sorted
    replicas*: int
    localNodeId*: string
    # Callback for iterating keys in a shard (provided by storage layer)
    iterateKeys*: proc(shardId: int): seq[(string, seq[byte])] {.gcsafe.}
    # Callback for storing keys locally (provided by storage layer)
    storeKeys*: proc(shardId: int, entries: seq[(string, seq[byte])]) {.gcsafe.}
    # Callback for deleting keys (provided by storage layer)
    deleteKeys*: proc(keys: seq[string]) {.gcsafe.}

  ShardConfig* = object
    numShards*: int
    replicas*: int
    strategy*: ShardStrategy

proc defaultShardConfig*(): ShardConfig =
  ShardConfig(numShards: 4, replicas: 1, strategy: ssHash)

proc newShardRouter*(config: ShardConfig = defaultShardConfig()): ShardRouter =
  result = ShardRouter(
    strategy: config.strategy,
    shards: @[],
    vnodeRing: @[],
    replicas: config.replicas,
  )
  for i in 0..<config.numShards:
    result.shards.add(Shard(
      id: i,
      name: "shard_" & $i,
      minKey: "",
      maxKey: "",
      nodeIds: @[],
      isActive: true,
      entryCount: 0,
    ))

proc hashKey*(key: string): uint64 =
  return uint64(hash(key))

proc getShardHash*(router: ShardRouter, key: string): int =
  let h = hashKey(key)
  return int(h mod uint64(router.shards.len))

proc getShardRange*(router: ShardRouter, key: string): int =
  for i, shard in router.shards:
    if key >= shard.minKey and key <= shard.maxKey:
      return i
  return -1  # key outside all defined ranges

proc getShardConsistent*(router: ShardRouter, key: string): int =
  if router.vnodeRing.len == 0:
    return getShardHash(router, key)
  let h = hashKey(key)
  var lo = 0
  var hi = router.vnodeRing.len - 1
  while lo < hi:
    let mid = (lo + hi) div 2
    if router.vnodeRing[mid][0] < h:
      lo = mid + 1
    else:
      hi = mid
  if lo < router.vnodeRing.len and h <= router.vnodeRing[lo][0]:
    return router.vnodeRing[lo][1]
  return router.vnodeRing[0][1]

proc getShard*(router: ShardRouter, key: string): int =
  case router.strategy
  of ssHash: router.getShardHash(key)
  of ssRange: router.getShardRange(key)
  of ssConsistent: router.getShardConsistent(key)

proc addVirtualNodes*(router: var ShardRouter, numVnodes: int = 100) =
  for shard in router.shards:
    for i in 0..<numVnodes:
      let vnodeKey = shard.name & "_vnode_" & $i
      router.vnodeRing.add((hashKey(vnodeKey), shard.id))
  router.vnodeRing.sort(proc(a, b: (uint64, int)): int = cmp(a[0], b[0]))

proc setRangeBounds*(router: var ShardRouter, bounds: seq[(string, string)]) =
  for i, bound in bounds:
    if i < router.shards.len:
      router.shards[i].minKey = bound[0]
      router.shards[i].maxKey = bound[1]

proc assignNode*(router: var ShardRouter, shardId: int, nodeId: string) =
  if shardId < router.shards.len:
    router.shards[shardId].nodeIds.add(nodeId)

proc getShardForNode*(router: ShardRouter, nodeId: string): seq[int] =
  result = @[]
  for i, shard in router.shards:
    if nodeId in shard.nodeIds:
      result.add(i)

proc replicasOf*(router: ShardRouter, key: string): seq[string] =
  let shardId = router.getShard(key)
  if shardId >= 0 and shardId < router.shards.len:
    return router.shards[shardId].nodeIds
  return @[]

proc allShards*(router: ShardRouter): seq[Shard] =
  return router.shards

proc activeShardCount*(router: ShardRouter): int =
  result = 0
  for s in router.shards:
    if s.isActive:
      inc result

# ---------------------------------------------------------------------------
# Data Migration Protocol
# Protocol: "MIGRATE <shardId> <entryCount>\n<key1>\0<val1>\n<key2>\0<val2>..."
# Response: "MIGRATE_OK <shardId>\n"
# ---------------------------------------------------------------------------

proc connectWithTimeout(sock: Socket, host: string, port: Port, timeoutMs: int): bool =
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

proc sendMigrationBatch(host: string, port: int, shardId: int,
                        entries: seq[(string, seq[byte])]): bool =
  try:
    var sock = newSocket()
    if not connectWithTimeout(sock, host, Port(port), 5000):
      sock.close()
      return false
    let header = "MIGRATE " & $shardId & " " & $entries.len & "\n"
    sock.send(header)
    for (key, value) in entries:
      # Use \0 as separator between key and value, \n as entry delimiter
      var valStr = newString(value.len)
      for i, b in value: valStr[i] = char(b)
      let entry = key & "\0" & valStr & "\n"
      sock.send(entry)
    var response = ""
    sock.readLine(response)
    sock.close()
    return response.strip().startsWith("MIGRATE_OK")
  except CatchableError:
    return false

proc migrateData*(router: var ShardRouter, nodes: seq[string],
                  nodeAddrs: Table[string, tuple[host: string, port: int]]) =
  ## Migrate data when shard assignments change.
  ## Moves keys out of shards that are no longer owned by local node.
  if router.iterateKeys == nil or router.storeKeys == nil:
    return

  if router.localNodeId.len == 0:
    return

  for shard in router.shards.mitems:
    let isOwner = router.localNodeId in shard.nodeIds
    if not isOwner:
      # We previously owned this shard but no longer do — ship data to new owner
      let entries = router.iterateKeys(shard.id)
      if entries.len > 0:
        # Find a new owner for this shard
        for newNodeId in shard.nodeIds:
          if newNodeId != router.localNodeId and newNodeId in nodeAddrs:
            let (host, port) = nodeAddrs[newNodeId]
            if sendMigrationBatch(host, port, shard.id, entries):
              if router.deleteKeys != nil:
                var keys = newSeq[string](entries.len)
                for i, e in entries: keys[i] = e[0]
                router.deleteKeys(keys)
            break

proc rebalance*(router: var ShardRouter, nodes: seq[string]) =
  if nodes.len == 0:
    return

  # Remember old assignments for migration
  var oldAssignments: seq[seq[string]] = @[]
  for shard in router.shards:
    oldAssignments.add(shard.nodeIds)

  # Clear existing assignments
  for i in 0..<router.shards.len:
    router.shards[i].nodeIds = @[]

  # Round-robin assign replicas
  for i in 0..<router.shards.len:
    for r in 0..<router.replicas:
      let nodeIdx = (i + r) mod nodes.len
      router.shards[i].nodeIds.add(nodes[nodeIdx])

proc applyMigrationBatch*(router: var ShardRouter, shardId: int,
                          entries: seq[(string, seq[byte])]) =
  if router.storeKeys != nil:
    router.storeKeys(shardId, entries)
    if shardId < router.shards.len:
      router.shards[shardId].entryCount += entries.len

proc shardCount*(router: ShardRouter): int = router.shards.len

# ---------------------------------------------------------------------------
# ClusterMembership — gossip integration
# ---------------------------------------------------------------------------

type
  ClusterMembership* = ref object
    nodes*: seq[string]
    router*: ShardRouter
    nodeAddrs*: Table[string, tuple[host: string, port: int]]
    localNodeId*: string
    localHost*: string
    localPort*: int

proc newClusterMembership*(router: ShardRouter, localNodeId: string = ""): ClusterMembership =
  let cm = ClusterMembership(nodes: @[], router: router, localNodeId: localNodeId)
  cm.router.localNodeId = localNodeId
  cm.nodeAddrs = initTable[string, tuple[host: string, port: int]]()
  cm

proc addNode*(cm: ClusterMembership, nodeId: string,
              host: string = "", port: int = 0) =
  if nodeId == cm.localNodeId:
    return
  if nodeId in cm.nodes:
    # Update address if provided
    if host.len > 0:
      cm.nodeAddrs[nodeId] = (host, port)
    return
  cm.nodes.add(nodeId)
  if host.len > 0:
    cm.nodeAddrs[nodeId] = (host, port)
  if cm.nodes.len >= 2:
    cm.router.rebalance(cm.nodes)
    # Migrate data if we have migration callbacks and node addresses
    if cm.router.iterateKeys != nil:
      cm.router.migrateData(cm.nodes, cm.nodeAddrs)

proc removeNode*(cm: ClusterMembership, nodeId: string) =
  var newNodes: seq[string] = @[]
  for n in cm.nodes:
    if n != nodeId:
      newNodes.add(n)
  cm.nodes = newNodes
  cm.nodeAddrs.del(nodeId)
  if cm.nodes.len >= 1:
    cm.router.rebalance(cm.nodes)

proc onNodeJoin*(cm: ClusterMembership, nodeId: string,
                 host: string = "", port: int = 0) =
  echo "[cluster] node joined: ", nodeId
  cm.addNode(nodeId, host, port)

proc onNodeLeave*(cm: ClusterMembership, nodeId: string) =
  echo "[cluster] node left: ", nodeId
  # Re-assign shards that were on the leaving node
  for i in 0..<cm.router.shards.len:
    var newReplicas: seq[string] = @[]
    for rid in cm.router.shards[i].nodeIds:
      if rid != nodeId:
        newReplicas.add(rid)
    cm.router.shards[i].nodeIds = newReplicas
  cm.removeNode(nodeId)

proc onNodeFail*(cm: ClusterMembership, nodeId: string) =
  echo "[cluster] node failed: ", nodeId
  cm.onNodeLeave(nodeId)

proc onNodeSuspect*(cm: ClusterMembership, nodeId: string) =
  echo "[cluster] node suspect: ", nodeId
  # Don't trigger rebalance on suspect — wait for dead confirmation

proc nodeCount*(cm: ClusterMembership): int = cm.nodes.len
proc activeNodes*(cm: ClusterMembership): seq[string] = cm.nodes

# ---------------------------------------------------------------------------
# Migration message handler (for server integration)
# ---------------------------------------------------------------------------

proc handleMigrationMessage*(headerLine: string, data: string,
                              router: var ShardRouter): string =
  ## Process incoming MIGRATE message and return response.
  ## Called by the server when it receives a MIGRATE request.
  let parts = headerLine.strip().split(" ")
  if parts.len < 3:
    return "ERR invalid migrate header\n"

  let shardId = try: parseInt(parts[1]) except: -1
  let entryCount = try: parseInt(parts[2]) except: 0

  if shardId < 0 or entryCount < 0:
    return "ERR invalid shard id or entry count\n"

  if entryCount == 0:
    return "MIGRATE_OK " & $shardId & "\n"

  # Parse key-value pairs from data
  var entries: seq[(string, seq[byte])] = @[]
  var currentKey = ""
  var currentVal: seq[byte] = @[]
  var inValue = false

  for c in data:
    if not inValue:
      if c == '\0':
        inValue = true
      else:
        currentKey.add(c)
    else:
      if c == '\n':
        entries.add((currentKey, currentVal))
        currentKey = ""
        currentVal = @[]
        inValue = false
      else:
        currentVal.add(byte(c))

  if entries.len > 0:
    router.applyMigrationBatch(shardId, entries)

  return "MIGRATE_OK " & $shardId & "\n"
