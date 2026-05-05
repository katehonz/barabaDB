## Sharding — hash-based and range-based data distribution
import std/tables
import std/hashes
import std/algorithm
import std/sets

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
  return 0

proc getShardConsistent*(router: ShardRouter, key: string): int =
  if router.vnodeRing.len == 0:
    return getShardHash(router, key)
  let h = hashKey(key)
  for (ringHash, shardId) in router.vnodeRing:
    if h <= ringHash:
      return shardId
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
  if shardId < router.shards.len:
    return router.shards[shardId].nodeIds
  return @[]

proc allShards*(router: ShardRouter): seq[Shard] =
  return router.shards

proc activeShardCount*(router: ShardRouter): int =
  result = 0
  for s in router.shards:
    if s.isActive:
      inc result

proc rebalance*(router: var ShardRouter, nodes: seq[string]) =
  if nodes.len == 0:
    return
  # Clear existing assignments
  for i in 0..<router.shards.len:
    router.shards[i].nodeIds = @[]

  # Round-robin assign replicas
  for i in 0..<router.shards.len:
    for r in 0..<router.replicas:
      let nodeIdx = (i + r) mod nodes.len
      router.shards[i].nodeIds.add(nodes[nodeIdx])

proc shardCount*(router: ShardRouter): int = router.shards.len

# Auto-rebalance with active node management
type
  ClusterMembership* = ref object
    nodes*: seq[string]
    router*: ShardRouter

proc newClusterMembership*(router: ShardRouter): ClusterMembership =
  ClusterMembership(nodes: @[], router: router)

proc addNode*(cm: ClusterMembership, nodeId: string) =
  if nodeId in cm.nodes:
    return
  cm.nodes.add(nodeId)
  if cm.nodes.len >= 2:  # Only rebalance with 2+ nodes
    cm.router.rebalance(cm.nodes)

proc removeNode*(cm: ClusterMembership, nodeId: string) =
  var newNodes: seq[string] = @[]
  for n in cm.nodes:
    if n != nodeId:
      newNodes.add(n)
  cm.nodes = newNodes
  if cm.nodes.len >= 1:
    cm.router.rebalance(cm.nodes)

proc onNodeJoin*(cm: ClusterMembership, nodeId: string) =
  echo "[cluster] node joined: ", nodeId
  cm.addNode(nodeId)

proc onNodeLeave*(cm: ClusterMembership, nodeId: string) =
  echo "[cluster] node left: ", nodeId
  cm.removeNode(nodeId)

proc onNodeFail*(cm: ClusterMembership, nodeId: string) =
  echo "[cluster] node failed: ", nodeId
  cm.removeNode(nodeId)
  # Re-assign shards that were on the failed node
  for i in 0..<cm.router.shards.len:
    var newReplicas: seq[string] = @[]
    for rid in cm.router.shards[i].nodeIds:
      if rid != nodeId:
        newReplicas.add(rid)
    cm.router.shards[i].nodeIds = newReplicas

proc nodeCount*(cm: ClusterMembership): int = cm.nodes.len
proc activeNodes*(cm: ClusterMembership): seq[string] = cm.nodes
