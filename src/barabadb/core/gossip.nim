## Gossip Protocol — membership and failure detection
import std/tables
import std/random
import std/monotimes

type
  NodeState* = enum
    nsAlive
    nsSuspect
    nsDead

  GossipNode* = ref object
    id*: string
    host*: string
    port*: int
    state*: NodeState
    incarnation*: uint64
    lastSeen*: int64
    metadata*: Table[string, string]

  GossipMessage* = object
    senderId*: string
    senderIncarnation*: uint64
    nodes*: seq[(string, NodeState, uint64)]  # (id, state, incarnation)

  GossipProtocol* = ref object
    self*: GossipNode
    members*: Table[string, GossipNode]
    suspectTimeout*: int64    # nanoseconds
    deadTimeout*: int64       # nanoseconds
    fanout*: int              # number of nodes to gossip to per round
    onJoin*: proc(node: GossipNode) {.gcsafe.}
    onLeave*: proc(nodeId: string) {.gcsafe.}
    onSuspect*: proc(nodeId: string) {.gcsafe.}

proc newGossipNode*(id: string, host: string, port: int): GossipNode =
  GossipNode(
    id: id, host: host, port: port,
    state: nsAlive, incarnation: 1,
    lastSeen: getMonoTime().ticks(),
    metadata: initTable[string, string](),
  )

proc newGossipProtocol*(id: string, host: string, port: int,
                        fanout: int = 3): GossipProtocol =
  let self = newGossipNode(id, host, port)
  GossipProtocol(
    self: self,
    members: initTable[string, GossipNode](),
    suspectTimeout: 5_000_000_000,  # 5 seconds
    deadTimeout: 15_000_000_000,    # 15 seconds
    fanout: fanout,
    onJoin: nil,
    onLeave: nil,
    onSuspect: nil,
  )

proc join*(gp: GossipProtocol, seedNode: GossipNode) =
  gp.members[seedNode.id] = seedNode
  if gp.onJoin != nil:
    gp.onJoin(seedNode)

proc addMember*(gp: GossipProtocol, node: GossipNode) =
  if node.id == gp.self.id:
    return
  gp.members[node.id] = node
  if gp.onJoin != nil:
    gp.onJoin(node)

proc removeMember*(gp: GossipProtocol, nodeId: string) =
  gp.members.del(nodeId)
  if gp.onLeave != nil:
    gp.onLeave(nodeId)

proc suspect*(gp: GossipProtocol, nodeId: string) =
  if nodeId in gp.members:
    gp.members[nodeId].state = nsSuspect
    if gp.onSuspect != nil:
      gp.onSuspect(nodeId)

proc declareDead*(gp: GossipProtocol, nodeId: string) =
  if nodeId in gp.members:
    gp.members[nodeId].state = nsDead
    if gp.onLeave != nil:
      gp.onLeave(nodeId)

proc createGossipMessage*(gp: GossipProtocol): GossipMessage =
  result = GossipMessage(
    senderId: gp.self.id,
    senderIncarnation: gp.self.incarnation,
    nodes: @[],
  )
  for id, node in gp.members:
    result.nodes.add((id, node.state, node.incarnation))

proc applyGossipMessage*(gp: GossipProtocol, msg: GossipMessage) =
  for (nodeId, state, incarnation) in msg.nodes:
    if nodeId == gp.self.id:
      # Someone suspects us — increment incarnation to refute
      if state == nsSuspect and incarnation >= gp.self.incarnation:
        inc gp.self.incarnation
      continue

    if nodeId in gp.members:
      let existing = gp.members[nodeId]
      if incarnation > existing.incarnation:
        existing.state = state
        existing.incarnation = incarnation
        existing.lastSeen = getMonoTime().ticks()
        if state == nsDead:
          gp.removeMember(nodeId)
      elif incarnation == existing.incarnation and state == nsDead:
        existing.state = nsDead
        gp.removeMember(nodeId)
    else:
      # New node
      if state != nsDead:
        let newNode = GossipNode(
          id: nodeId, host: "", port: 0,
          state: state, incarnation: incarnation,
          lastSeen: getMonoTime().ticks(),
        )
        gp.addMember(newNode)

proc selectGossipTargets*(gp: GossipProtocol): seq[GossipNode] =
  var alive: seq[GossipNode] = @[]
  for id, node in gp.members:
    if node.state == nsAlive:
      alive.add(node)
  result = @[]
  let count = min(gp.fanout, alive.len)
  for i in 0..<count:
    let idx = rand(alive.len - 1)
    result.add(alive[idx])
    alive.delete(idx)

proc checkHealth*(gp: GossipProtocol) =
  let now = getMonoTime().ticks()
  var toRemove: seq[string] = @[]
  for id, node in gp.members:
    let elapsed = now - node.lastSeen
    if node.state == nsAlive and elapsed > gp.suspectTimeout:
      node.state = nsSuspect
      if gp.onSuspect != nil:
        gp.onSuspect(id)
    elif node.state == nsSuspect and elapsed > gp.deadTimeout:
      toRemove.add(id)
  for id in toRemove:
    gp.declareDead(id)

proc aliveMembers*(gp: GossipProtocol): seq[GossipNode] =
  result = @[]
  for id, node in gp.members:
    if node.state == nsAlive:
      result.add(node)

proc memberCount*(gp: GossipProtocol): int = gp.members.len
proc aliveCount*(gp: GossipProtocol): int = gp.aliveMembers().len

proc memberIds*(gp: GossipProtocol): seq[string] =
  result = @[]
  for id in gp.members.keys:
    result.add(id)

proc isMember*(gp: GossipProtocol, nodeId: string): bool =
  return nodeId in gp.members

proc getMember*(gp: GossipProtocol, nodeId: string): GossipNode =
  gp.members.getOrDefault(nodeId, nil)
