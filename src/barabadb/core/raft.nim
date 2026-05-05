## Raft Consensus — leader election + log replication
import std/tables
import std/sets
import std/deques
import std/algorithm
import std/random

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

proc newRaftNode*(id: string, peers: seq[string]): RaftNode =
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
