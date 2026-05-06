## Raft Consensus — leader election + log replication
import std/tables
import std/sets
import std/deques
import std/algorithm
import std/random
import std/monotimes
import std/asyncdispatch
import std/asyncnet
import std/streams
import std/strutils
import std/endians
import ../protocol/wire

type
  RaftState* = enum
    rsFollower
    rsCandidate
    rsLeader

  LogEntry* = object
    term*: uint64
    index*: uint64
    command*: string
    data*: seq[byte]

  RaftNode* = ref object
    id*: string
    state*: RaftState
    currentTerm*: uint64
    votedFor*: string
    log*: seq[LogEntry]
    commitIndex*: uint64
    lastApplied*: uint64
    # Leader state
    nextIndex*: Table[string, uint64]
    matchIndex*: Table[string, uint64]
    # Cluster
    peers*: seq[string]
    leaderId*: string
    # Timing
    electionTimeout*: int
    heartbeatTimeout*: int
    votesReceived*: HashSet[string]
    peerAddrs*: Table[string, tuple[host: string, port: int]]
    raftPort*: int

  RaftMessageKind* = enum
    rmkRequestVote
    rmkRequestVoteReply
    rmkAppendEntries
    rmkAppendEntriesReply

  RaftMessage* = object
    kind*: RaftMessageKind
    term*: uint64
    senderId*: string
    # RequestVote
    lastLogIndex*: uint64
    lastLogTerm*: uint64
    # AppendEntries
    prevLogIndex*: uint64
    prevLogTerm*: uint64
    entries*: seq[LogEntry]
    leaderCommit*: uint64
    # Reply
    success*: bool
    matchIdx*: uint64

  RaftCluster* = ref object
    nodes*: Table[string, RaftNode]
    messageQueue*: Deque[RaftMessage]

proc newRaftNode*(id: string, peers: seq[string], raftPort: int = 0): RaftNode =
  randomize()
  RaftNode(
    id: id,
    state: rsFollower,
    currentTerm: 0,
    votedFor: "",
    log: @[],
    commitIndex: 0,
    lastApplied: 0,
    nextIndex: initTable[string, uint64](),
    matchIndex: initTable[string, uint64](),
    peers: peers,
    leaderId: "",
    electionTimeout: 150 + rand(150),
    heartbeatTimeout: 50,
    votesReceived: initHashSet[string](),
    peerAddrs: initTable[string, tuple[host: string, port: int]](),
    raftPort: raftPort,
  )

proc newRaftCluster*(): RaftCluster =
  RaftCluster(
    nodes: initTable[string, RaftNode](),
    messageQueue: initDeque[RaftMessage](),
  )

proc addNode*(cluster: RaftCluster, id: string) =
  var peers: seq[string] = @[]
  for existingId in cluster.nodes.keys:
    peers.add(existingId)
    cluster.nodes[existingId].peers.add(id)
  cluster.nodes[id] = newRaftNode(id, peers)

proc lastLogIndex*(node: RaftNode): uint64 =
  if node.log.len == 0:
    return 0
  return node.log[^1].index

proc lastLogTerm*(node: RaftNode): uint64 =
  if node.log.len == 0:
    return 0
  return node.log[^1].term

proc becomeFollower*(node: RaftNode, term: uint64) =
  node.state = rsFollower
  node.currentTerm = term
  node.votedFor = ""
  node.votesReceived.clear()

proc becomeCandidate*(node: RaftNode) =
  node.state = rsCandidate
  inc node.currentTerm
  node.votedFor = node.id
  node.votesReceived.clear()
  node.votesReceived.incl(node.id)

proc becomeLeader*(node: RaftNode) =
  node.state = rsLeader
  node.leaderId = node.id
  for peer in node.peers:
    node.nextIndex[peer] = node.lastLogIndex + 1
    node.matchIndex[peer] = 0

proc handleRequestVote*(node: RaftNode, msg: RaftMessage): RaftMessage =
  var reply = RaftMessage(
    kind: rmkRequestVoteReply,
    term: node.currentTerm,
    senderId: node.id,
    success: false,
  )

  if msg.term < node.currentTerm:
    return reply

  if msg.term > node.currentTerm:
    node.becomeFollower(msg.term)

  let canVote = node.votedFor == "" or node.votedFor == msg.senderId
  let logOk = msg.lastLogTerm > node.lastLogTerm or
              (msg.lastLogTerm == node.lastLogTerm and msg.lastLogIndex >= node.lastLogIndex)

  if canVote and logOk:
    node.votedFor = msg.senderId
    reply.success = true
    reply.term = node.currentTerm

  return reply

proc handleAppendEntries*(node: RaftNode, msg: RaftMessage): RaftMessage =
  var reply = RaftMessage(
    kind: rmkAppendEntriesReply,
    term: node.currentTerm,
    senderId: node.id,
    success: false,
    matchIdx: 0,
  )

  if msg.term < node.currentTerm:
    return reply

  if msg.term >= node.currentTerm:
    node.becomeFollower(msg.term)
    node.leaderId = msg.senderId

  # Check if log contains entry at prevLogIndex with prevLogTerm
  if msg.prevLogIndex > 0:
    if msg.prevLogIndex > uint64(node.log.len):
      return reply
    if node.log[msg.prevLogIndex - 1].term != msg.prevLogTerm:
      # Delete conflicting entries
      node.log.setLen(int(msg.prevLogIndex - 1))
      return reply

  # Append new entries
  for entry in msg.entries:
    let idx = int(entry.index - 1)
    if idx < node.log.len:
      if node.log[idx].term != entry.term:
        node.log.setLen(idx)
        node.log.add(entry)
    else:
      node.log.add(entry)

  # Update commit index
  if msg.leaderCommit > node.commitIndex:
    node.commitIndex = min(msg.leaderCommit, node.lastLogIndex)

  reply.success = true
  reply.matchIdx = node.lastLogIndex
  return reply

proc requestVote*(node: RaftNode): seq[RaftMessage] =
  result = @[]
  for peer in node.peers:
    result.add(RaftMessage(
      kind: rmkRequestVote,
      term: node.currentTerm,
      senderId: node.id,
      lastLogIndex: node.lastLogIndex,
      lastLogTerm: node.lastLogTerm,
    ))

proc appendEntries*(node: RaftNode, peerId: string): RaftMessage =
  let nextIdx = node.nextIndex.getOrDefault(peerId, node.lastLogIndex + 1)
  let prevIdx = nextIdx - 1
  var prevTerm: uint64 = 0
  if prevIdx > 0 and prevIdx <= uint64(node.log.len):
    prevTerm = node.log[prevIdx - 1].term

  var entries: seq[LogEntry] = @[]
  if nextIdx > 0:
    for i in int(nextIdx - 1)..<node.log.len:
      entries.add(node.log[i])

  return RaftMessage(
    kind: rmkAppendEntries,
    term: node.currentTerm,
    senderId: node.id,
    prevLogIndex: prevIdx,
    prevLogTerm: prevTerm,
    entries: entries,
    leaderCommit: node.commitIndex,
  )

proc appendLog*(node: RaftNode, command: string, data: seq[byte] = @[]): LogEntry =
  if node.state != rsLeader:
    return LogEntry()
  result = LogEntry(
    term: node.currentTerm,
    index: node.lastLogIndex + 1,
    command: command,
    data: data,
  )
  node.log.add(result)

proc handleVoteReply*(node: RaftNode, reply: RaftMessage) =
  if reply.term > node.currentTerm:
    node.becomeFollower(reply.term)
    return

  if node.state != rsCandidate:
    return

  if reply.success:
    node.votesReceived.incl(reply.senderId)
    if node.votesReceived.len > (node.peers.len + 1) div 2:
      node.becomeLeader()

proc handleAppendReply*(node: RaftNode, peerId: string, reply: RaftMessage) =
  if reply.term > node.currentTerm:
    node.becomeFollower(reply.term)
    return

  if node.state != rsLeader:
    return

  if reply.success:
    node.matchIndex[peerId] = reply.matchIdx
    node.nextIndex[peerId] = reply.matchIdx + 1

    # Update commit index
    var matchIndices: seq[uint64] = @[node.lastLogIndex]
    for p, idx in node.matchIndex:
      matchIndices.add(idx)
    matchIndices.sort()

    let medianIdx = matchIndices[matchIndices.len div 2]
    if medianIdx > node.commitIndex:
      if medianIdx <= node.lastLogIndex and
         node.log[medianIdx - 1].term == node.currentTerm:
        node.commitIndex = medianIdx
  else:
    if node.nextIndex[peerId] > 1:
      dec node.nextIndex[peerId]

proc state*(node: RaftNode): RaftState = node.state
proc isLeader*(node: RaftNode): bool = node.state == rsLeader
proc leaderId*(node: RaftNode): string = node.leaderId
proc logLen*(node: RaftNode): int = node.log.len

# Leader election timer loop
type
  ElectionTimer* = ref object
    node: RaftNode
    timeoutMs: int
    lastHeartbeat: int64
    running: bool

proc newElectionTimer*(node: RaftNode, timeoutMs: int = 150): ElectionTimer =
  ElectionTimer(
    node: node,
    timeoutMs: timeoutMs,
    lastHeartbeat: getMonoTime().ticks(),
    running: false,
  )

proc resetTimeout*(timer: ElectionTimer) =
  timer.lastHeartbeat = getMonoTime().ticks()

proc checkTimeout*(timer: ElectionTimer): bool =
  let elapsed = (getMonoTime().ticks() - timer.lastHeartbeat) div 1_000_000
  return elapsed > timer.timeoutMs

proc stop*(timer: ElectionTimer) =
  timer.running = false

# ---------------------------------------------------------------------------
# Network Transport — async TCP communication for Raft
# ---------------------------------------------------------------------------

const
  RaftMagic = "RAFT"
  RaftProtoVersion = 1'u32

proc writeString(s: Stream, str: string) =
  s.write(uint32(str.len))
  if str.len > 0:
    s.writeData(str[0].unsafeAddr, str.len)

proc readString(s: Stream): string =
  let len = int(s.readUint32())
  if len > 0:
    result = newString(len)
    discard s.readData(result[0].addr, len)
  else:
    result = ""

proc writeLogEntry(s: Stream, entry: LogEntry) =
  s.write(entry.term)
  s.write(entry.index)
  s.writeString(entry.command)
  s.write(uint32(entry.data.len))
  if entry.data.len > 0:
    for b in entry.data:
      s.write(char(b))

proc readLogEntry(s: Stream): LogEntry =
  result.term = s.readUint64()
  result.index = s.readUint64()
  result.command = s.readString()
  let dataLen = int(s.readUint32())
  result.data = newSeq[byte](dataLen)
  for i in 0 ..< dataLen:
    result.data[i] = byte(s.readChar())

proc serialize*(msg: RaftMessage): seq[byte] =
  let stream = newStringStream()
  stream.write(RaftMagic)
  stream.write(RaftProtoVersion)
  stream.write(uint32(ord(msg.kind)))
  stream.write(msg.term)
  stream.writeString(msg.senderId)
  stream.write(msg.lastLogIndex)
  stream.write(msg.lastLogTerm)
  stream.write(msg.prevLogIndex)
  stream.write(msg.prevLogTerm)
  stream.write(uint32(msg.entries.len))
  for entry in msg.entries:
    stream.writeLogEntry(entry)
  stream.write(msg.leaderCommit)
  stream.write(char(if msg.success: 1 else: 0))
  stream.write(msg.matchIdx)
  let strData = stream.data
  result = newSeq[byte](strData.len)
  for i in 0 ..< strData.len:
    result[i] = byte(strData[i])
  stream.close()

proc deserializeRaftMessage*(data: seq[byte]): RaftMessage =
  let stream = newStringStream(cast[string](data))
  let magic = stream.readStr(4)
  if magic != RaftMagic:
    raise newException(ValueError, "Invalid Raft magic bytes")
  let version = stream.readUint32()
  if version != RaftProtoVersion:
    raise newException(ValueError, "Unsupported Raft protocol version")
  result.kind = RaftMessageKind(stream.readUint32())
  result.term = stream.readUint64()
  result.senderId = stream.readString()
  result.lastLogIndex = stream.readUint64()
  result.lastLogTerm = stream.readUint64()
  result.prevLogIndex = stream.readUint64()
  result.prevLogTerm = stream.readUint64()
  let entryCount = int(stream.readUint32())
  result.entries = newSeq[LogEntry](entryCount)
  for i in 0 ..< entryCount:
    result.entries[i] = stream.readLogEntry()
  result.leaderCommit = stream.readUint64()
  result.success = stream.readChar() != '\0'
  result.matchIdx = stream.readUint64()
  stream.close()

# ---------------------------------------------------------------------------
# RaftNetwork — async TCP transport
# ---------------------------------------------------------------------------

type
  RaftNetwork* = ref object
    node*: RaftNode
    socket*: AsyncSocket
    running*: bool
    peerSockets*: Table[string, AsyncSocket]

proc newRaftNetwork*(node: RaftNode): RaftNetwork =
  RaftNetwork(
    node: node,
    running: false,
    peerSockets: initTable[string, AsyncSocket](),
  )

proc connectToPeer(net: RaftNetwork, peerId: string) {.async.} =
  if peerId notin net.node.peerAddrs:
    return
  let (host, port) = net.node.peerAddrs[peerId]
  try:
    let sock = newAsyncSocket()
    await sock.connect(host, Port(port))
    net.peerSockets[peerId] = sock
  except:
    discard

proc send*(net: RaftNetwork, peerId: string, msg: RaftMessage) {.async.} =
  if peerId notin net.peerSockets:
    await net.connectToPeer(peerId)
  if peerId in net.peerSockets:
    let data = serialize(msg)
    let payloadLen = uint32(data.len)
    var header = newSeq[byte](4)
    bigEndian32(addr header[0], unsafeAddr payloadLen)
    try:
      await net.peerSockets[peerId].send(cast[string](header) & cast[string](data))
    except:
      net.peerSockets.del(peerId)

proc broadcast*(net: RaftNetwork, msgs: seq[RaftMessage]) {.async.} =
  for i, peer in net.node.peers:
    if i < msgs.len:
      await net.send(peer, msgs[i])

proc processMessage(net: RaftNetwork, msg: RaftMessage) {.async.} =
  case msg.kind
  of rmkRequestVote:
    let reply = net.node.handleRequestVote(msg)
    await net.send(msg.senderId, reply)
  of rmkRequestVoteReply:
    net.node.handleVoteReply(msg)
  of rmkAppendEntries:
    let reply = net.node.handleAppendEntries(msg)
    await net.send(msg.senderId, reply)
  of rmkAppendEntriesReply:
    net.node.handleAppendReply(msg.senderId, msg)

proc receiveLoop(net: RaftNetwork, client: AsyncSocket) {.async.} =
  try:
    while net.running:
      let lenData = await client.recv(4)
      if lenData.len < 4:
        break
      var pos = 0
      let payloadLen = int(readUint32(cast[seq[byte]](lenData), pos))
      let payloadStr = await client.recv(payloadLen)
      if payloadStr.len < payloadLen:
        break
      var payload = newSeq[byte](payloadLen)
      for i in 0 ..< payloadLen:
        payload[i] = byte(payloadStr[i])
      let msg = deserializeRaftMessage(payload)
      asyncCheck net.processMessage(msg)
  except:
    discard
  finally:
    client.close()

proc heartbeatLoop(net: RaftNetwork) {.async.} =
  while net.running:
    if net.node.state == rsLeader:
      for peer in net.node.peers:
        let msg = net.node.appendEntries(peer)
        await net.send(peer, msg)
    await sleepAsync(net.node.heartbeatTimeout)

proc run*(net: RaftNetwork) {.async.} =
  net.socket = newAsyncSocket()
  net.socket.setSockOpt(OptReuseAddr, true)
  net.socket.bindAddr(Port(net.node.raftPort), "127.0.0.1")
  net.socket.listen()
  net.running = true
  asyncCheck net.heartbeatLoop()
  while net.running:
    try:
      let client = await net.socket.accept()
      asyncCheck net.receiveLoop(client)
    except:
      break

proc stop*(net: RaftNetwork) =
  net.running = false
  if net.socket != nil:
    net.socket.close()
  for peerId, sock in net.peerSockets:
    sock.close()
  net.peerSockets.clear()

# ---------------------------------------------------------------------------
# ElectionTimer integration with network transport
# ---------------------------------------------------------------------------

proc startElection*(timer: ElectionTimer, net: RaftNetwork) =
  if timer.node.state != rsCandidate:
    timer.node.becomeCandidate()
  if net != nil:
    let msgs = timer.node.requestVote()
    for i, peer in timer.node.peers:
      if i < msgs.len:
        asyncCheck net.send(peer, msgs[i])

proc tick*(timer: ElectionTimer, net: RaftNetwork = nil) =
  case timer.node.state
  of rsFollower:
    if timer.checkTimeout():
      timer.startElection(net)
      timer.resetTimeout()
  of rsCandidate:
    if timer.checkTimeout():
      # Election timed out — restart
      timer.node.becomeCandidate()
      if net != nil:
        let msgs = timer.node.requestVote()
        for i, peer in timer.node.peers:
          if i < msgs.len:
            asyncCheck net.send(peer, msgs[i])
      timer.resetTimeout()
  of rsLeader:
    timer.resetTimeout()  # Keep alive
