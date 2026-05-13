## Gossip Protocol — membership and failure detection with UDP transport
import std/tables
import std/random
import std/monotimes
import std/asyncdispatch
import std/net
import std/strutils
import std/streams
import std/os

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
    nodes*: seq[(string, NodeState, uint64, string, int)]  # (id, state, incarnation, host, port)

  GossipProtocol* = ref object
    self*: GossipNode
    members*: Table[string, GossipNode]
    suspectTimeout*: int64    # nanoseconds
    deadTimeout*: int64       # nanoseconds
    fanout*: int              # number of nodes to gossip to per round
    gossipPort*: int
    running*: bool
    sock*: Socket
    onJoin*: proc(node: GossipNode) {.gcsafe.}
    onLeave*: proc(nodeId: string) {.gcsafe.}
    onSuspect*: proc(nodeId: string) {.gcsafe.}
    onMembershipChanged*: proc() {.gcsafe.}

# ---------------------------------------------------------------------------
# GossipMessage binary serialization (for UDP transport)
# ---------------------------------------------------------------------------

const GossipMagic = "GOSS"
const GossipProtoVersion = 1'u32

proc serialize*(msg: GossipMessage): seq[byte] =
  let s = newStringStream()
  s.write(GossipMagic)
  s.write(GossipProtoVersion)
  s.write(uint32(msg.senderId.len))
  if msg.senderId.len > 0:
    s.writeData(msg.senderId[0].unsafeAddr, msg.senderId.len)
  s.write(msg.senderIncarnation)
  s.write(uint32(msg.nodes.len))
  for (id, state, incarnation, host, port) in msg.nodes:
    s.write(uint32(id.len))
    if id.len > 0:
      s.writeData(id[0].unsafeAddr, id.len)
    s.write(uint32(ord(state)))
    s.write(incarnation)
    s.write(uint32(host.len))
    if host.len > 0:
      s.writeData(host[0].unsafeAddr, host.len)
    s.write(uint32(port))
  let strData = s.data
  result = newSeq[byte](strData.len)
  for i in 0 ..< strData.len:
    result[i] = byte(strData[i])
  s.close()

proc deserializeGossipMessage*(data: seq[byte]): GossipMessage =
  let s = newStringStream(cast[string](data))
  let magic = s.readStr(4)
  if magic != GossipMagic:
    raise newException(ValueError, "Invalid gossip magic")
  let version = s.readUint32()
  if version != GossipProtoVersion:
    raise newException(ValueError, "Unsupported gossip protocol version")
  let senderIdLen = int(s.readUint32())
  result.senderId = if senderIdLen > 0: s.readStr(senderIdLen) else: ""
  result.senderIncarnation = s.readUint64()
  let nodeCount = int(s.readUint32())
  result.nodes = newSeq[(string, NodeState, uint64, string, int)](nodeCount)
  for i in 0 ..< nodeCount:
    let idLen = int(s.readUint32())
    let id = if idLen > 0: s.readStr(idLen) else: ""
    let state = NodeState(s.readUint32())
    let incarnation = s.readUint64()
    let hostLen = int(s.readUint32())
    let host = if hostLen > 0: s.readStr(hostLen) else: ""
    let port = int(s.readUint32())
    result.nodes[i] = (id, state, incarnation, host, port)
  s.close()

# ---------------------------------------------------------------------------
# Core Gossip Protocol
# ---------------------------------------------------------------------------

proc newGossipNode*(id: string, host: string, port: int): GossipNode =
  GossipNode(
    id: id, host: host, port: port,
    state: nsAlive, incarnation: 1,
    lastSeen: getMonoTime().ticks(),
    metadata: initTable[string, string](),
  )

proc newGossipProtocol*(id: string, host: string, port: int,
                        fanout: int = 3, gossipPort: int = 0): GossipProtocol =
  let self = newGossipNode(id, host, port)
  GossipProtocol(
    self: self,
    members: initTable[string, GossipNode](),
    suspectTimeout: 5_000_000_000,  # 5 seconds
    deadTimeout: 15_000_000_000,    # 15 seconds
    fanout: fanout,
    gossipPort: gossipPort,
    running: false,
    sock: nil,
    onJoin: nil,
    onLeave: nil,
    onSuspect: nil,
    onMembershipChanged: nil,
  )

proc join*(gp: GossipProtocol, seedNode: GossipNode) =
  gp.members[seedNode.id] = seedNode
  if gp.onJoin != nil:
    gp.onJoin(seedNode)
  if gp.onMembershipChanged != nil:
    gp.onMembershipChanged()

proc addMember*(gp: GossipProtocol, node: GossipNode) =
  if node.id == gp.self.id:
    return
  let existed = node.id in gp.members
  gp.members[node.id] = node
  if not existed and gp.onJoin != nil:
    gp.onJoin(node)
  if gp.onMembershipChanged != nil:
    gp.onMembershipChanged()

proc removeMember*(gp: GossipProtocol, nodeId: string) =
  if nodeId in gp.members:
    gp.members.del(nodeId)
    if gp.onLeave != nil:
      gp.onLeave(nodeId)
    if gp.onMembershipChanged != nil:
      gp.onMembershipChanged()

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
    if gp.onMembershipChanged != nil:
      gp.onMembershipChanged()

proc createGossipMessage*(gp: GossipProtocol): GossipMessage =
  result = GossipMessage(
    senderId: gp.self.id,
    senderIncarnation: gp.self.incarnation,
    nodes: @[],
  )
  for id, node in gp.members:
    result.nodes.add((id, node.state, node.incarnation, node.host, node.port))

proc applyGossipMessage*(gp: GossipProtocol, msg: GossipMessage) =
  for (nodeId, state, incarnation, host, port) in msg.nodes:
    if nodeId == gp.self.id:
      if state == nsSuspect and incarnation >= gp.self.incarnation:
        inc gp.self.incarnation
      continue

    if nodeId in gp.members:
      let existing = gp.members[nodeId]
      if incarnation > existing.incarnation:
        existing.state = state
        existing.incarnation = incarnation
        existing.lastSeen = getMonoTime().ticks()
        if host.len > 0: existing.host = host
        if port > 0: existing.port = port
        if state == nsDead:
          gp.removeMember(nodeId)
      elif incarnation == existing.incarnation and state == nsDead:
        existing.state = nsDead
        gp.removeMember(nodeId)
    else:
      if state != nsDead:
        let newNode = GossipNode(
          id: nodeId, host: host, port: port,
          state: state, incarnation: incarnation,
          lastSeen: getMonoTime().ticks(),
        )
        gp.addMember(newNode)

  if gp.onMembershipChanged != nil:
    gp.onMembershipChanged()

proc selectGossipTargets*(gp: GossipProtocol): seq[GossipNode] =
  var alive: seq[GossipNode] = @[]
  for id, node in gp.members:
    if node.state == nsAlive and node.host.len > 0 and node.port > 0:
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

# ---------------------------------------------------------------------------
# UDP transport layer (using blocking sockets for simplicity)
# ---------------------------------------------------------------------------

proc sendGossipUdp(gp: GossipProtocol, target: GossipNode, msg: GossipMessage) =
  if target.host.len == 0 or target.port == 0:
    return
  try:
    let sock = newSocket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    let data = serialize(msg)
    sock.sendTo(target.host, Port(target.port), cast[string](data))
    sock.close()
  except:
    discard

proc broadcastGossip(gp: GossipProtocol) =
  let msg = gp.createGossipMessage()
  let targets = gp.selectGossipTargets()
  for target in targets:
    gp.sendGossipUdp(target, msg)

proc handleIncomingGossip(gp: GossipProtocol, data: string, senderAddr: string) =
  try:
    let msg = deserializeGossipMessage(cast[seq[byte]](data))
    if msg.senderId in gp.members:
      gp.members[msg.senderId].lastSeen = getMonoTime().ticks()
    elif msg.senderId != gp.self.id:
      var host = senderAddr
      if ':' in host:
        host = host.split(":")[0]
      let newNode = GossipNode(
        id: msg.senderId, host: host, port: gp.gossipPort,
        state: nsAlive, incarnation: msg.senderIncarnation,
        lastSeen: getMonoTime().ticks(),
      )
      gp.addMember(newNode)
    gp.applyGossipMessage(msg)
  except:
    discard

proc startHealthCheck*(gp: GossipProtocol, intervalMs: int = 1000) {.async.} =
  while gp.running:
    await sleepAsync(intervalMs)
    gp.checkHealth()

proc startGossipRound*(gp: GossipProtocol, intervalMs: int = 2000) {.async.} =
  while gp.running:
    await sleepAsync(intervalMs)
    gp.broadcastGossip()

proc startGossipListener*(gp: GossipProtocol) {.async.} =
  gp.sock = newSocket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
  gp.sock.setSockOpt(OptReuseAddr, true)
  gp.sock.bindAddr(Port(gp.gossipPort))
  gp.running = true
  while gp.running:
    try:
      var data = newString(65535)
      var senderAddr = ""
      var senderPort: Port
      let bytesRead = gp.sock.recvFrom(data, 65535, senderAddr, senderPort)
      if bytesRead > 0:
        data.setLen(bytesRead)
        gp.handleIncomingGossip(data, senderAddr)
    except:
      # Small sleep on error to avoid spin
      gp.sock.close()
      # Recreate socket for next iteration
      try:
        gp.sock = newSocket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        gp.sock.setSockOpt(OptReuseAddr, true)
        gp.sock.bindAddr(Port(gp.gossipPort))
      except:
        break

proc startGossip*(gp: GossipProtocol, healthIntervalMs: int = 1000,
                  gossipIntervalMs: int = 2000) =
  gp.running = true
  asyncCheck gp.startGossipListener()
  asyncCheck gp.startHealthCheck(healthIntervalMs)
  asyncCheck gp.startGossipRound(gossipIntervalMs)

proc stop*(gp: GossipProtocol) =
  gp.running = false
  if gp.sock != nil:
    gp.sock.close()
    gp.sock = nil
