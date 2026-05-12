## Graph Engine — adjacency list storage with graph algorithms
import std/tables
import std/deques
import std/algorithm
import std/math
import std/sets
import std/hashes
import std/streams
import std/locks

type
  EdgeId* = distinct uint64
  NodeId* = distinct uint64

  Edge* = object
    id*: EdgeId
    src*: NodeId
    dst*: NodeId
    label*: string
    properties*: Table[string, string]
    weight*: float64

  GraphNode* = object
    id*: NodeId
    label*: string
    properties*: Table[string, string]

  AdjacencyEntry* = object
    edgeId*: EdgeId
    neighbor*: NodeId
    weight*: float64
    label*: string

  Graph* = ref object
    nodes*: Table[NodeId, GraphNode]
    edges*: Table[EdgeId, Edge]
    adjacency*: Table[NodeId, seq[AdjacencyEntry]]  # outgoing
    reverseAdj*: Table[NodeId, seq[AdjacencyEntry]]  # incoming
    nextNodeId: uint64
    nextEdgeId: uint64
    lock*: Lock

proc `==`*(a, b: EdgeId): bool = uint64(a) == uint64(b)
proc `==`*(a, b: NodeId): bool = uint64(a) == uint64(b)
proc hash*(x: EdgeId): Hash = hash(uint64(x))
proc hash*(x: NodeId): Hash = hash(uint64(x))

proc newGraph*(): Graph =
  new(result)
  initLock(result.lock)
  result.nodes = initTable[NodeId, GraphNode]()
  result.edges = initTable[EdgeId, Edge]()
  result.adjacency = initTable[NodeId, seq[AdjacencyEntry]]()
  result.reverseAdj = initTable[NodeId, seq[AdjacencyEntry]]()
  result.nextNodeId = 1
  result.nextEdgeId = 1

proc addNode*(g: Graph, label: string, properties: Table[string, string] = initTable[string, string]()): NodeId =
  acquire(g.lock)
  defer: release(g.lock)
  let id = NodeId(g.nextNodeId)
  inc g.nextNodeId
  g.nodes[id] = GraphNode(id: id, label: label, properties: properties)
  g.adjacency[id] = @[]
  g.reverseAdj[id] = @[]
  return id

proc addEdge*(g: Graph, src, dst: NodeId, label: string = "",
              properties: Table[string, string] = initTable[string, string](),
              weight: float64 = 1.0): EdgeId =
  acquire(g.lock)
  defer: release(g.lock)
  if src notin g.nodes:
    raise newException(KeyError, "Source node does not exist: " & $uint64(src))
  if dst notin g.nodes:
    raise newException(KeyError, "Destination node does not exist: " & $uint64(dst))
  let id = EdgeId(g.nextEdgeId)
  inc g.nextEdgeId
  g.edges[id] = Edge(id: id, src: src, dst: dst, label: label,
                     properties: properties, weight: weight)
  g.adjacency[src].add(AdjacencyEntry(edgeId: id, neighbor: dst, weight: weight, label: label))
  g.reverseAdj[dst].add(AdjacencyEntry(edgeId: id, neighbor: src, weight: weight, label: label))
  return id

proc getNode*(g: Graph, id: NodeId): GraphNode =
  acquire(g.lock)
  defer: release(g.lock)
  return g.nodes[id]

proc getEdge*(g: Graph, id: EdgeId): Edge =
  acquire(g.lock)
  defer: release(g.lock)
  return g.edges[id]

proc neighbors*(g: Graph, nodeId: NodeId): seq[NodeId] =
  acquire(g.lock)
  defer: release(g.lock)
  result = @[]
  for entry in g.adjacency.getOrDefault(nodeId, @[]):
    result.add(entry.neighbor)

proc inNeighbors*(g: Graph, nodeId: NodeId): seq[NodeId] =
  acquire(g.lock)
  defer: release(g.lock)
  result = @[]
  for entry in g.reverseAdj.getOrDefault(nodeId, @[]):
    result.add(entry.neighbor)

proc removeNode*(g: Graph, nodeId: NodeId) =
  acquire(g.lock)
  defer: release(g.lock)
  if nodeId notin g.nodes:
    return

  for entry in g.adjacency.getOrDefault(nodeId, @[]):
    g.edges.del(entry.edgeId)
    var newRev: seq[AdjacencyEntry] = @[]
    for rev in g.reverseAdj.getOrDefault(entry.neighbor, @[]):
      if rev.neighbor != nodeId:
        newRev.add(rev)
    g.reverseAdj[entry.neighbor] = newRev

  for entry in g.reverseAdj.getOrDefault(nodeId, @[]):
    g.edges.del(entry.edgeId)
    var newAdj: seq[AdjacencyEntry] = @[]
    for adj in g.adjacency.getOrDefault(entry.neighbor, @[]):
      if adj.neighbor != nodeId:
        newAdj.add(adj)
    g.adjacency[entry.neighbor] = newAdj

  g.nodes.del(nodeId)
  g.adjacency.del(nodeId)
  g.reverseAdj.del(nodeId)

proc bfs*(g: Graph, start: NodeId, maxDepth: int = -1): seq[NodeId] =
  acquire(g.lock)
  defer: release(g.lock)
  result = @[]
  var visited = initHashSet[NodeId]()
  var queue = initDeque[(NodeId, int)]()
  queue.addLast((start, 0))
  visited.incl(start)

  while queue.len > 0:
    let (node, depth) = queue.popFirst()
    result.add(node)
    if maxDepth >= 0 and depth >= maxDepth:
      continue
    for entry in g.adjacency.getOrDefault(node, @[]):
      if entry.neighbor notin visited:
        visited.incl(entry.neighbor)
        queue.addLast((entry.neighbor, depth + 1))

proc dfs*(g: Graph, start: NodeId, maxDepth: int = -1): seq[NodeId] =
  acquire(g.lock)
  defer: release(g.lock)
  result = @[]
  var visited = initHashSet[NodeId]()
  var stack: seq[(NodeId, int)] = @[(start, 0)]

  while stack.len > 0:
    let (node, depth) = stack.pop()
    if node in visited:
      continue
    visited.incl(node)
    result.add(node)
    if maxDepth >= 0 and depth >= maxDepth:
      continue
    for entry in g.adjacency.getOrDefault(node, @[]):
      if entry.neighbor notin visited:
        stack.add((entry.neighbor, depth + 1))

proc shortestPath*(g: Graph, start, target: NodeId): seq[NodeId] =
  acquire(g.lock)
  defer: release(g.lock)
  var visited = initHashSet[NodeId]()
  var parent = initTable[NodeId, NodeId]()
  var queue = initDeque[NodeId]()
  queue.addLast(start)
  visited.incl(start)

  while queue.len > 0:
    let node = queue.popFirst()
    if node == target:
      var path: seq[NodeId] = @[target]
      var current = target
      while current in parent:
        current = parent[current]
        path.add(current)
      path.reverse()
      return path

    for entry in g.adjacency.getOrDefault(node, @[]):
      if entry.neighbor notin visited:
        visited.incl(entry.neighbor)
        parent[entry.neighbor] = node
        queue.addLast(entry.neighbor)

  return @[]

proc dijkstra*(g: Graph, start: NodeId): Table[NodeId, float64] =
  acquire(g.lock)
  defer: release(g.lock)
  result = initTable[NodeId, float64]()
  var visited = initHashSet[NodeId]()

  result[start] = 0.0

  while true:
    var bestNode: NodeId
    var bestDist = Inf
    for nodeId, dist in result:
      if nodeId notin visited and dist < bestDist:
        bestDist = dist
        bestNode = nodeId

    if bestDist == Inf:
      break

    visited.incl(bestNode)

    for entry in g.adjacency.getOrDefault(bestNode, @[]):
      let newDist = bestDist + entry.weight
      if entry.neighbor notin result or newDist < result[entry.neighbor]:
        result[entry.neighbor] = newDist

proc pageRank*(g: Graph, iterations: int = 20, dampingFactor: float64 = 0.85): Table[NodeId, float64] =
  acquire(g.lock)
  defer: release(g.lock)
  result = initTable[NodeId, float64]()
  let n = g.nodes.len
  if n == 0:
    return

  let initialRank = 1.0 / float64(n)
  for nodeId in g.nodes.keys:
    result[nodeId] = initialRank

  for iter in 0..<iterations:
    var newRanks = initTable[NodeId, float64]()
    var danglingSum: float64 = 0

    for nodeId in g.nodes.keys:
      let outDegree = g.adjacency.getOrDefault(nodeId, @[]).len
      if outDegree == 0:
        danglingSum += result[nodeId]

    for nodeId in g.nodes.keys:
      var rank = (1.0 - dampingFactor) / float64(n)
      rank += dampingFactor * danglingSum / float64(n)

      for entry in g.reverseAdj.getOrDefault(nodeId, @[]):
        let srcOutDegree = g.adjacency.getOrDefault(entry.neighbor, @[]).len
        if srcOutDegree > 0:
          rank += dampingFactor * result[entry.neighbor] / float64(srcOutDegree)

      newRanks[nodeId] = rank

    result = newRanks

proc nodeCount*(g: Graph): int =
  acquire(g.lock)
  defer: release(g.lock)
  return g.nodes.len

proc edgeCount*(g: Graph): int =
  acquire(g.lock)
  defer: release(g.lock)
  return g.edges.len

# ---------------------------------------------------------------------------
# Persistence — binary save/load
# ---------------------------------------------------------------------------

const
  GraphFileMagic = "BGRF"
  GraphFileVersion = 1'u32

proc writeString(s: Stream, str: string) =
  s.write(uint32(str.len))
  if str.len > 0:
    s.writeData(str[0].unsafeAddr, str.len)

proc readString(s: Stream): string =
  let len = s.readUint32()
  if len > 0:
    result = newString(int(len))
    discard s.readData(result[0].addr, int(len))
  else:
    result = ""

proc saveToFile*(g: Graph, path: string) =
  acquire(g.lock)
  defer: release(g.lock)
  let s = newFileStream(path, fmWrite)
  if s.isNil:
    raise newException(IOError, "Cannot open graph file for writing: " & path)

  s.write(GraphFileMagic)
  s.write(GraphFileVersion)
  s.write(uint32(g.nodes.len))
  s.write(uint32(g.edges.len))
  s.write(g.nextNodeId)
  s.write(g.nextEdgeId)

  for nodeId, node in g.nodes:
    s.write(uint64(nodeId))
    s.writeString(node.label)
    s.write(uint32(node.properties.len))
    for key, val in node.properties:
      s.writeString(key)
      s.writeString(val)

  for edgeId, edge in g.edges:
    s.write(uint64(edgeId))
    s.write(uint64(edge.src))
    s.write(uint64(edge.dst))
    s.writeString(edge.label)
    s.write(edge.weight)
    s.write(uint32(edge.properties.len))
    for key, val in edge.properties:
      s.writeString(key)
      s.writeString(val)

  s.close()

proc loadFromFile*(path: string): Graph =
  let s = newFileStream(path, fmRead)
  if s.isNil:
    raise newException(IOError, "Cannot open graph file for reading: " & path)

  let magic = s.readStr(4)
  if magic != GraphFileMagic:
    raise newException(ValueError, "Invalid graph file magic bytes")

  let version = s.readUint32()
  if version != GraphFileVersion:
    raise newException(ValueError, "Unsupported graph file version: " & $version)

  let nodeCount = int(s.readUint32())
  let edgeCount = int(s.readUint32())
  let nextNodeId = s.readUint64()
  let nextEdgeId = s.readUint64()

  result = Graph(
    nodes: initTable[NodeId, GraphNode](),
    edges: initTable[EdgeId, Edge](),
    adjacency: initTable[NodeId, seq[AdjacencyEntry]](),
    reverseAdj: initTable[NodeId, seq[AdjacencyEntry]](),
    nextNodeId: nextNodeId,
    nextEdgeId: nextEdgeId,
    lock: Lock(),
  )
  initLock(result.lock)
  acquire(result.lock)

  for i in 0 ..< nodeCount:
    let id = NodeId(s.readUint64())
    let label = s.readString()
    let propCount = int(s.readUint32())
    var props = initTable[string, string]()
    for j in 0 ..< propCount:
      let key = s.readString()
      let val = s.readString()
      props[key] = val
    result.nodes[id] = GraphNode(id: id, label: label, properties: props)
    result.adjacency[id] = @[]
    result.reverseAdj[id] = @[]

  for i in 0 ..< edgeCount:
    let id = EdgeId(s.readUint64())
    let src = NodeId(s.readUint64())
    let dst = NodeId(s.readUint64())
    let label = s.readString()
    let weight = s.readFloat64()
    let propCount = int(s.readUint32())
    var props = initTable[string, string]()
    for j in 0 ..< propCount:
      let key = s.readString()
      let val = s.readString()
      props[key] = val
    result.edges[id] = Edge(id: id, src: src, dst: dst, label: label,
                            properties: props, weight: weight)
    result.adjacency[src].add(AdjacencyEntry(edgeId: id, neighbor: dst,
                                              weight: weight, label: label))
    result.reverseAdj[dst].add(AdjacencyEntry(edgeId: id, neighbor: src,
                                               weight: weight, label: label))

  release(result.lock)
  s.close()
