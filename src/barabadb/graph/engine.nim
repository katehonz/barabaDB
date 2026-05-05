## Graph Engine — adjacency list storage with graph algorithms
import std/tables
import std/deques
import std/algorithm
import std/math
import std/sets
import std/hashes

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

proc `==`*(a, b: EdgeId): bool = uint64(a) == uint64(b)
proc `==`*(a, b: NodeId): bool = uint64(a) == uint64(b)
proc hash*(x: EdgeId): Hash = hash(uint64(x))
proc hash*(x: NodeId): Hash = hash(uint64(x))

proc newGraph*(): Graph =
  Graph(
    nodes: initTable[NodeId, GraphNode](),
    edges: initTable[EdgeId, Edge](),
    adjacency: initTable[NodeId, seq[AdjacencyEntry]](),
    reverseAdj: initTable[NodeId, seq[AdjacencyEntry]](),
    nextNodeId: 1,
    nextEdgeId: 1,
  )

proc addNode*(g: Graph, label: string, properties: Table[string, string] = initTable[string, string]()): NodeId =
  let id = NodeId(g.nextNodeId)
  inc g.nextNodeId
  g.nodes[id] = GraphNode(id: id, label: label, properties: properties)
  g.adjacency[id] = @[]
  g.reverseAdj[id] = @[]
  return id

proc addEdge*(g: Graph, src, dst: NodeId, label: string = "",
              properties: Table[string, string] = initTable[string, string](),
              weight: float64 = 1.0): EdgeId =
  let id = EdgeId(g.nextEdgeId)
  inc g.nextEdgeId
  g.edges[id] = Edge(id: id, src: src, dst: dst, label: label,
                     properties: properties, weight: weight)
  g.adjacency[src].add(AdjacencyEntry(edgeId: id, neighbor: dst, weight: weight, label: label))
  g.reverseAdj[dst].add(AdjacencyEntry(edgeId: id, neighbor: src, weight: weight, label: label))
  return id

proc getNode*(g: Graph, id: NodeId): GraphNode =
  g.nodes[id]

proc getEdge*(g: Graph, id: EdgeId): Edge =
  g.edges[id]

proc neighbors*(g: Graph, nodeId: NodeId): seq[NodeId] =
  result = @[]
  for entry in g.adjacency.getOrDefault(nodeId, @[]):
    result.add(entry.neighbor)

proc inNeighbors*(g: Graph, nodeId: NodeId): seq[NodeId] =
  result = @[]
  for entry in g.reverseAdj.getOrDefault(nodeId, @[]):
    result.add(entry.neighbor)

proc removeNode*(g: Graph, nodeId: NodeId) =
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
    for neighbor in g.neighbors(node):
      if neighbor notin visited:
        visited.incl(neighbor)
        queue.addLast((neighbor, depth + 1))

proc dfs*(g: Graph, start: NodeId, maxDepth: int = -1): seq[NodeId] =
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
    for neighbor in g.neighbors(node):
      if neighbor notin visited:
        stack.add((neighbor, depth + 1))

proc shortestPath*(g: Graph, start, target: NodeId): seq[NodeId] =
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

    for neighbor in g.neighbors(node):
      if neighbor notin visited:
        visited.incl(neighbor)
        parent[neighbor] = node
        queue.addLast(neighbor)

  return @[]

proc dijkstra*(g: Graph, start: NodeId): Table[NodeId, float64] =
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

proc nodeCount*(g: Graph): int = g.nodes.len
proc edgeCount*(g: Graph): int = g.edges.len
