## Community Detection — Louvain algorithm
import std/tables
import std/sets
import std/algorithm
import std/math
import std/sequtils
import engine

type
  LouvainResult* = ref object
    communities*: Table[NodeId, int]  # node -> community id
    modularity*: float64
    numCommunities*: int

proc louvain*(g: Graph): LouvainResult =
  result = LouvainResult(
    communities: initTable[NodeId, int](),
    modularity: 0.0,
    numCommunities: 0,
  )

  if g.nodeCount == 0:
    return

  # Phase 1: assign each node to its own community
  var community: Table[NodeId, int] = initTable[NodeId, int]()
  var nodeCommunity = initTable[NodeId, int]()
  var commNodes = initTable[int, seq[NodeId]]()
  var inEdges = initTable[int, int]()
  var totalEdges = initTable[int, int]()
  var m = 0  # total edge weight

  for nodeId in g.nodes.keys:
    let cid = nodeCommunity.len
    community[nodeId] = cid
    nodeCommunity[nodeId] = cid
    commNodes[cid] = @[nodeId]
    inEdges[cid] = 0
    totalEdges[cid] = 0

    for entry in g.adjacency.getOrDefault(nodeId, @[]):
      inc m  # count each edge once
      if entry.neighbor in community and community[entry.neighbor] == community[nodeId]:
        inEdges[cid] += 1
      totalEdges[cid] += 1

  var numComms = nodeCommunity.len

  # Iterate until no improvement
  var improved = true
  var iterations = 0
  while improved and iterations < 100:
    improved = false
    inc iterations

    var changedNodes = g.nodes.keys.toSeq
    # Randomize order
    changedNodes.sort(proc(a, b: NodeId): int = cmp(uint64(a), uint64(b)))

    for nodeId in changedNodes:
      let oldComm = community[nodeId]

      # Compute gain for moving to each neighbor community
      var neighborComms = initHashSet[int]()
      for entry in g.adjacency.getOrDefault(nodeId, @[]):
        if entry.neighbor in community:
          let nc = community[entry.neighbor]
          if nc != oldComm:
            neighborComms.incl(nc)

      if neighborComms.len == 0:
        continue

      # Calculate delta modularity for moving
      var bestComm = oldComm
      var bestDeltaQ = 0.0'f64

      var k_i = 0
      var k_i_in = 0
      for entry in g.adjacency.getOrDefault(nodeId, @[]):
        inc k_i
        if entry.neighbor in community and community[entry.neighbor] == oldComm:
          inc k_i_in

      for nc in neighborComms:
        var k_i_comm = 0
        for entry in g.adjacency.getOrDefault(nodeId, @[]):
          if entry.neighbor in community and community[entry.neighbor] == nc:
            inc k_i_comm

        var sigmaTot = 0
        for nid in commNodes.getOrDefault(nc, @[]):
          for entry in g.adjacency.getOrDefault(nid, @[]):
            inc sigmaTot

        var sigmaIn = 0
        for nid in commNodes.getOrDefault(nc, @[]):
          for entry in g.adjacency.getOrDefault(nid, @[]):
            if entry.neighbor in community and community[entry.neighbor] == nc:
              inc sigmaIn

        let mFloat = float64(m)
        var deltaQ = float64(k_i_comm) / mFloat
        deltaQ -= float64(sigmaTot) * float64(k_i) / (2.0 * mFloat * mFloat)

        if deltaQ > bestDeltaQ:
          bestDeltaQ = deltaQ
          bestComm = nc

      if bestComm != oldComm and bestDeltaQ > 1e-10:
        # Move node to best community
        community[nodeId] = bestComm
        commNodes[oldComm] = commNodes[oldComm].filterIt(it != nodeId)
        if bestComm notin commNodes:
          commNodes[bestComm] = @[]
        commNodes[bestComm].add(nodeId)
        improved = true

    # Cleanup empty communities
    let commKeys = commNodes.keys.toSeq
    for cid in commKeys:
      if commNodes[cid].len == 0:
        commNodes.del(cid)

  # Compute final modularity
  var totalM = float64(m)
  if totalM > 0:
    var Q: float64 = 0
    for cid in commNodes.keys:
      var e_cc: float64 = 0
      var a_c: float64 = 0
      for nid in commNodes[cid]:
        for entry in g.adjacency.getOrDefault(nid, @[]):
          if entry.neighbor in community and community[entry.neighbor] == cid:
            e_cc += 1.0
          a_c += 1.0
      e_cc /= totalM
      a_c = (a_c / (2 * totalM))
      a_c *= a_c
      Q += e_cc - a_c
    result.modularity = Q

  result.communities = community
  result.numCommunities = commNodes.len

# Pattern matching — simple subgraph isomorphism search
type
  PatternNode* = object
    id*: int
    label*: string
    properties*: Table[string, string]

  PatternEdge* = object
    srcId*: int
    dstId*: int
    label*: string
    isDirected*: bool

  GraphPattern* = ref object
    nodes*: seq[PatternNode]
    edges*: seq[PatternEdge]

  PatternMatch* = ref object
    mapping*: seq[(int, NodeId)]  # pattern node id -> graph node id
    nodes*: seq[NodeId]

proc newGraphPattern*(): GraphPattern =
  GraphPattern(nodes: @[], edges: @[])

proc addNode*(pattern: GraphPattern, id: int, label: string,
              properties: Table[string, string] = initTable[string, string]()) =
  pattern.nodes.add(PatternNode(id: id, label: label, properties: properties))

proc addEdge*(pattern: GraphPattern, srcId, dstId: int, label: string = "",
              isDirected: bool = true) =
  pattern.edges.add(PatternEdge(srcId: srcId, dstId: dstId, label: label,
                                isDirected: isDirected))

proc matchPattern*(g: Graph, pattern: GraphPattern, maxMatches: int = 100): seq[PatternMatch] =
  result = @[]
  if pattern.nodes.len == 0:
    return

  # Find candidate sets for each pattern node
  var candidates = initTable[int, seq[NodeId]]()
  for pn in pattern.nodes:
    candidates[pn.id] = @[]
    for gid in g.nodes.keys:
      let gn = g.nodes[gid]
      if pn.label.len == 0 or gn.label == pn.label:
        var propsMatch = true
        for pk, pv in pn.properties:
          if gn.properties.getOrDefault(pk, "") != pv:
            propsMatch = false
            break
        if propsMatch:
          candidates[pn.id].add(gid)

  # Skip if any pattern node has no candidates
  for pn in pattern.nodes:
    if candidates[pn.id].len == 0:
      return

  # Simple backtracking search
  var mapping = initTable[int, NodeId]()
  var usedNodes = initHashSet[NodeId]()
  let pnIds = pattern.nodes.mapIt(it.id)
  var stack: seq[(int, int)] = @[(0, 0)]  # (idx, candidatePos)

  while stack.len > 0:
    let (idx, cpos) = stack[^1]
    if result.len >= maxMatches:
      return
    if idx >= pnIds.len:
      let match = PatternMatch(mapping: @[], nodes: @[])
      for pid, gid in mapping:
        match.mapping.add((pid, gid))
        match.nodes.add(gid)
      result.add(match)
      stack.setLen(stack.len - 1)
      if mapping.len > 0:
        let lastPid = pnIds[mapping.len - 1]
        usedNodes.excl(mapping[lastPid])
        mapping.del(lastPid)
      continue

    let pid = pnIds[idx]
    if cpos >= candidates[pid].len:
      stack.setLen(stack.len - 1)
      if mapping.len > 0:
        let lastPid = pnIds[mapping.len - 1]
        usedNodes.excl(mapping[lastPid])
        mapping.del(lastPid)
      continue

    # Advance candidate position
    stack[^1] = (idx, cpos + 1)

    let gid = candidates[pid][cpos]
    if gid in usedNodes:
      continue

    var edgesValid = true
    for edge in pattern.edges:
      if edge.srcId == pid and edge.dstId in mapping:
        let targetGid = mapping[edge.dstId]
        var found = false
        for adj in g.adjacency.getOrDefault(gid, @[]):
          if adj.neighbor == targetGid:
            if edge.label.len == 0 or adj.label == edge.label:
              found = true
              break
        if not found:
          edgesValid = false
          break
      elif edge.dstId == pid and edge.srcId in mapping:
        let sourceGid = mapping[edge.srcId]
        var found = false
        for adj in g.adjacency.getOrDefault(sourceGid, @[]):
          if adj.neighbor == gid:
            if edge.label.len == 0 or adj.label == edge.label:
              found = true
              break
        if not found:
          edgesValid = false
          break

    if edgesValid:
      mapping[pid] = gid
      usedNodes.incl(gid)
      stack.add((idx + 1, 0))
