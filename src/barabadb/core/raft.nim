## Raft Consensus — leader election + log replication
import std/tables
import std/sets
import std/deques
import std/random
import std/monotimes
import std/asyncdispatch
import std/asyncnet
import std/streams
import std/strutils
import std/endians
import std/os
import logging
import ../protocol/wire
import ../protocol/ssl

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

  ## Counters / gauges for Prometheus (/metrics). Updated on the raft/async
  ## path; HTTP reads them without locks (best-effort consistency).
  RaftMetrics* = ref object
    electionsTotal*: int64          # times this node became leader
    termChangesTotal*: int64        # currentTerm increases
    appendsTotal*: int64            # appendLog successes
    commitWaitsTotal*: int64        # successful wait-for-commit finishes
    commitWaitMsTotal*: int64       # sum of wait durations (ms)
    commitTimeoutsTotal*: int64     # raft commit timeout
    lostLeadershipTotal*: int64     # append returned index 0
    forwardsTotal*: int64           # follower→leader SQL forwards
    forwardErrorsTotal*: int64      # failed forwards
    appliesTotal*: int64            # applyCommand invocations
    compactionsTotal*: int64        # compactLog that actually dropped entries

  RaftNode* = ref object
    id*: string
    state*: RaftState
    currentTerm*: uint64
    votedFor*: string
    log*: seq[LogEntry]
    commitIndex*: uint64
    lastApplied*: uint64
    ## Compacted prefix: log entries with index <= lastSnapshotIndex are gone.
    ## Safe compaction only discards entries every peer has already matched
    ## (leader) or that this node has applied (follower), so catch-up via
    ## AppendEntries still works without InstallSnapshot payloads.
    lastSnapshotIndex*: uint64
    lastSnapshotTerm*: uint64
    ## Trigger compaction when log.len exceeds this (0 = default 256).
    logMaxEntries*: int
    metrics*: RaftMetrics
    # State machine callback
    applyCommand*: proc(cmd: string, data: seq[byte]) {.gcsafe.}
    # Distributed transaction callbacks (for raft→disttxn integration)
    onDistTxnPrepare*: proc(txnId: uint64, nodes: seq[string]): bool {.gcsafe.}
    onDistTxnCommit*: proc(txnId: uint64) {.gcsafe.}
    onDistTxnRollback*: proc(txnId: uint64) {.gcsafe.}
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
    dataDir*: string
    ## InstallSnapshot follower receive. snapChunkBytes caps a single chunk
    ## (from BARADB_RAFT_SNAP_CHUNK_KB, default 262144); snapIncomingId /
    ## snapIncomingFile track the archive currently being assembled under
    ## dataDir/snap_incoming/.
    snapChunkBytes*: int
    restoreSnapshot*: proc(archivePath: string, baseIndex: uint64,
                           baseTerm: uint64): bool {.gcsafe.}
    snapIncomingId*: uint64
    snapIncomingFile*: string

  RaftMessageKind* = enum
    rmkRequestVote
    rmkRequestVoteReply
    rmkAppendEntries
    rmkAppendEntriesReply
    rmkInstallSnapshot
    rmkInstallSnapshotReply

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
    # InstallSnapshot (prevLogIndex/prevLogTerm reuse: snapshot base index/term;
    # reply uses success/matchIdx as usual)
    snapId*: uint64      # snapshot generation, matches leader's base at build time
    snapOffset*: uint64  # byte offset of this chunk within the archive
    snapData*: seq[byte] # chunk payload (<= snapChunkBytes)
    snapDone*: bool      # last chunk

  RaftCluster* = ref object
    nodes*: Table[string, RaftNode]
    messageQueue*: Deque[RaftMessage]

const RaftStateFile = "raft_state.bin"

proc saveState(node: RaftNode) =
  if node.dataDir.len == 0: return
  createDir(node.dataDir)
  let path = node.dataDir / RaftStateFile
  let tmpPath = path & ".tmp"
  var s = newFileStream(tmpPath, fmWrite)
  if s == nil: return
  s.write(node.currentTerm)
  s.write(uint32(node.votedFor.len))
  s.write(node.votedFor)
  s.write(uint32(node.log.len))
  for entry in node.log:
    s.write(entry.term)
    s.write(entry.index)
    s.write(uint32(entry.command.len))
    s.write(entry.command)
    s.write(uint32(entry.data.len))
    if entry.data.len > 0:
      s.writeData(addr entry.data[0], entry.data.len)
  # Snapshot base (appended for backward-compatible load of older files)
  s.write(node.lastSnapshotIndex)
  s.write(node.lastSnapshotTerm)
  s.close()
  moveFile(tmpPath, path)

proc loadState(node: RaftNode) =
  if node.dataDir.len == 0: return
  let path = node.dataDir / RaftStateFile
  if not fileExists(path): return
  var s = newFileStream(path, fmRead)
  if s == nil: return
  try:
    node.currentTerm = s.readUint64()
    let votedForLen = int(s.readUint32())
    if votedForLen > 0:
      node.votedFor = s.readStr(votedForLen)
    let logLen = int(s.readUint32())
    if logLen > 1_000_000:
      raise newException(ValueError, "Raft log length too large")
    node.log = newSeq[LogEntry](logLen)
    for i in 0..<logLen:
      let term = s.readUint64()
      let index = s.readUint64()
      let cmdLen = int(s.readUint32())
      if cmdLen > 1_000_000:
        raise newException(ValueError, "Raft command length too large")
      let cmd = s.readStr(cmdLen)
      let dataLen = int(s.readUint32())
      if dataLen > 10_000_000:
        raise newException(ValueError, "Raft data length too large")
      var data = newSeq[byte](dataLen)
      if dataLen > 0:
        if s.readData(addr data[0], dataLen) != dataLen:
          raise newException(IOError, "Incomplete Raft log data read")
      node.log[i] = LogEntry(term: term, index: index, command: cmd, data: data)
    # Optional trailing snapshot fields (absent in pre-compaction state files)
    if not s.atEnd:
      node.lastSnapshotIndex = s.readUint64()
      if not s.atEnd:
        node.lastSnapshotTerm = s.readUint64()
      # lastApplied/commitIndex must not sit below the compacted base
      if node.lastApplied < node.lastSnapshotIndex:
        node.lastApplied = node.lastSnapshotIndex
      if node.commitIndex < node.lastSnapshotIndex:
        node.commitIndex = node.lastSnapshotIndex
  except IOError, OSError:
    echo "[WARN] Failed to load Raft state from ", path, ": ", getCurrentExceptionMsg()
  s.close()

proc newRaftNode*(id: string, peers: seq[string], raftPort: int = 0,
                  dataDir: string = ""): RaftNode =
  randomize()
  result = RaftNode(
    id: id,
    state: rsFollower,
    currentTerm: 0,
    votedFor: "",
    log: @[],
    commitIndex: 0,
    lastApplied: 0,
    lastSnapshotIndex: 0,
    lastSnapshotTerm: 0,
    logMaxEntries: 256,
    metrics: RaftMetrics(),
    nextIndex: initTable[string, uint64](),
    matchIndex: initTable[string, uint64](),
    peers: peers,
    leaderId: "",
    electionTimeout: 150 + rand(150),
    heartbeatTimeout: 50,
    votesReceived: initHashSet[string](),
    peerAddrs: initTable[string, tuple[host: string, port: int]](),
    raftPort: raftPort,
    dataDir: dataDir,
    snapChunkBytes: 262144,
    snapIncomingId: 0,
    snapIncomingFile: "",
  )
  result.loadState()

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
    return node.lastSnapshotIndex
  return node.log[^1].index

proc lastLogTerm*(node: RaftNode): uint64 =
  if node.log.len == 0:
    return node.lastSnapshotTerm
  return node.log[^1].term

proc findLogEntryByIndex(node: RaftNode, index: uint64): int =
  ## Find array position for a logical log index.
  ## Returns -1 if not found. Does NOT assume index - 1 == array position.
  for i, entry in node.log:
    if entry.index == index:
      return i
  return -1

proc termAtIndex(node: RaftNode, index: uint64): uint64 =
  ## Term of the log entry (or snapshot base) at `index`, or 0 if unknown.
  if index == 0: return 0
  if index == node.lastSnapshotIndex: return node.lastSnapshotTerm
  let pos = node.findLogEntryByIndex(index)
  if pos >= 0: return node.log[pos].term
  return 0

proc compactLog*(node: RaftNode) =
  ## Drop a fully-replicated / applied log prefix so the in-memory log stays
  ## bounded. Leader: never discard past any peer's matchIndex (catch-up via
  ## AppendEntries remains possible). Follower: discard through lastApplied.
  let maxEntries = if node.logMaxEntries > 0: node.logMaxEntries else: 256
  if node.log.len <= maxEntries:
    return
  var through = node.lastApplied
  if node.state == rsLeader and node.peers.len > 0:
    var minMatch = through
    for peer in node.peers:
      let m = node.matchIndex.getOrDefault(peer, 0'u64)
      if m < minMatch: minMatch = m
    through = minMatch
  if through <= node.lastSnapshotIndex:
    return
  let pos = node.findLogEntryByIndex(through)
  if pos < 0:
    return
  node.lastSnapshotTerm = node.log[pos].term
  node.lastSnapshotIndex = through
  if pos + 1 < node.log.len:
    node.log = node.log[(pos + 1) .. ^1]
  else:
    node.log = @[]
  # Keep lastApplied/commit at least at the snapshot base
  if node.lastApplied < node.lastSnapshotIndex:
    node.lastApplied = node.lastSnapshotIndex
  if node.commitIndex < node.lastSnapshotIndex:
    node.commitIndex = node.lastSnapshotIndex
  if node.metrics != nil:
    inc node.metrics.compactionsTotal
  node.saveState()

proc applyCommitted(node: RaftNode) =
  while node.lastApplied < node.commitIndex:
    inc node.lastApplied
    # Entries at/below the snapshot base were already applied before compact.
    if node.lastApplied <= node.lastSnapshotIndex:
      continue
    let pos = node.findLogEntryByIndex(node.lastApplied)
    if pos >= 0:
      let entry = node.log[pos]
      # Handle distributed transaction commands
      if entry.command.startsWith("DISTTXN:"):
        let parts = entry.command.split(":")
        if parts.len >= 3:
          let action = parts[1]
          let txnId = try: parseUInt(parts[2]) except CatchableError: 0'u64
          if action == "PREPARE" and node.onDistTxnPrepare != nil:
            discard node.onDistTxnPrepare(txnId, @[])
          elif action == "COMMIT" and node.onDistTxnCommit != nil:
            node.onDistTxnCommit(txnId)
          elif action == "ROLLBACK" and node.onDistTxnRollback != nil:
            node.onDistTxnRollback(txnId)
      else:
        if node.applyCommand != nil:
          node.applyCommand(entry.command, entry.data)
        if node.metrics != nil:
          inc node.metrics.appliesTotal
  node.compactLog()

proc becomeFollower*(node: RaftNode, term: uint64) =
  if term > node.currentTerm and node.metrics != nil:
    inc node.metrics.termChangesTotal
  node.state = rsFollower
  node.currentTerm = term
  node.votedFor = ""
  node.votesReceived.clear()
  node.nextIndex.clear()
  node.matchIndex.clear()
  node.saveState()

proc becomeCandidate*(node: RaftNode) =
  node.state = rsCandidate
  inc node.currentTerm
  if node.metrics != nil:
    inc node.metrics.termChangesTotal
  node.votedFor = node.id
  node.votesReceived.clear()
  node.votesReceived.incl(node.id)
  node.saveState()

proc becomeLeader*(node: RaftNode) =
  node.state = rsLeader
  node.leaderId = node.id
  if node.metrics != nil:
    inc node.metrics.electionsTotal
  info("Raft node " & node.id & " became leader for term " & $node.currentTerm)
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
    node.saveState()
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

  if msg.term > node.currentTerm:
    node.becomeFollower(msg.term)
  node.leaderId = msg.senderId

  # Check if log contains entry at prevLogIndex with prevLogTerm
  if msg.prevLogIndex > 0:
    if msg.prevLogIndex < node.lastSnapshotIndex:
      # Leader is behind our snapshot base — reject
      return reply
    if msg.prevLogIndex == node.lastSnapshotIndex:
      if msg.prevLogTerm != node.lastSnapshotTerm:
        return reply
    else:
      let prevPos = node.findLogEntryByIndex(msg.prevLogIndex)
      if prevPos < 0:
        return reply
      if node.log[prevPos].term != msg.prevLogTerm:
        # Delete conflicting entries
        node.log.setLen(prevPos)
        return reply

  # Append new entries
  var logChanged = false
  for entry in msg.entries:
    let pos = node.findLogEntryByIndex(entry.index)
    if pos >= 0:
      if node.log[pos].term != entry.term:
        node.log.setLen(pos)
        node.log.add(entry)
        logChanged = true
    else:
      node.log.add(entry)
      logChanged = true

  if logChanged:
    node.saveState()

  # Update commit index
  if msg.leaderCommit > node.commitIndex:
    node.commitIndex = min(msg.leaderCommit, node.lastLogIndex)
    node.applyCommitted()

  reply.success = true
  reply.matchIdx = node.lastLogIndex
  return reply

proc handleInstallSnapshot*(node: RaftNode, msg: RaftMessage): RaftMessage =
  ## Follower side of InstallSnapshot: assemble the chunk stream into a temp
  ## archive under `dataDir/snap_incoming/`, then hand the completed archive
  ## to the restoreSnapshot callback. Chunks arrive in order from a single
  ## leader over one socket, so we append sequentially and only sanity-check
  ## that snapOffset equals the number of bytes assembled so far.
  ##
  ## NOTE: this runs on the async event loop and restoreSnapshot performs
  ## blocking disk I/O (archive extract + DB reopen). Implementations must be
  ## fast, or defer the heavy work; the baradadb.nim wiring decides.
  var reply = RaftMessage(
    kind: rmkInstallSnapshotReply,
    term: node.currentTerm,
    senderId: node.id,
    success: false,
    matchIdx: node.lastSnapshotIndex,
  )
  if msg.term < node.currentTerm:
    return reply
  if msg.term > node.currentTerm:
    node.becomeFollower(msg.term)
  node.leaderId = msg.senderId

  # Chunk size cap (deferred from the wire-protocol task).
  if msg.snapData.len > node.snapChunkBytes or node.dataDir.len == 0:
    return reply

  let snapDir = node.dataDir / "snap_incoming"
  if msg.snapId != node.snapIncomingId:
    # New snapshot generation: discard any partial assembly and restart.
    if msg.snapOffset != 0:
      return reply
    createDir(snapDir)
    node.snapIncomingId = msg.snapId
    node.snapIncomingFile = snapDir / "snap_" & $msg.snapId & ".tar.gz"
    let f = open(node.snapIncomingFile, fmWrite)  # truncate any leftover
    f.close()

  if node.snapIncomingFile.len == 0:
    return reply

  let assembled = getFileSize(node.snapIncomingFile)
  if msg.snapOffset != uint64(assembled):
    # Gap or overlap: reset so the leader restarts the transfer.
    removeFile(node.snapIncomingFile)
    node.snapIncomingId = 0
    node.snapIncomingFile = ""
    return reply

  if msg.snapData.len > 0:
    let f = open(node.snapIncomingFile, fmAppend)
    try:
      discard f.writeBuffer(addr msg.snapData[0], msg.snapData.len)
    finally:
      f.close()

  if not msg.snapDone:
    reply.success = true
    return reply

  # Transfer complete: restore the data dir and adopt the snapshot base.
  if node.restoreSnapshot == nil or
      not node.restoreSnapshot(node.snapIncomingFile,
                               msg.prevLogIndex, msg.prevLogTerm):
    removeFile(node.snapIncomingFile)
    node.snapIncomingId = 0
    node.snapIncomingFile = ""
    return reply

  node.lastSnapshotIndex = msg.prevLogIndex
  node.lastSnapshotTerm = msg.prevLogTerm
  node.commitIndex = node.lastSnapshotIndex
  node.lastApplied = node.lastSnapshotIndex
  node.log = @[]
  node.snapIncomingId = 0
  node.snapIncomingFile = ""
  node.saveState()
  reply.success = true
  reply.matchIdx = node.lastSnapshotIndex
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
  var nextIdx = node.nextIndex.getOrDefault(peerId, node.lastLogIndex + 1)
  # Never try to send entries already discarded by our snapshot base.
  if nextIdx <= node.lastSnapshotIndex:
    nextIdx = node.lastSnapshotIndex + 1
    node.nextIndex[peerId] = nextIdx
  let prevIdx = nextIdx - 1
  let prevTerm = node.termAtIndex(prevIdx)

  var entries: seq[LogEntry] = @[]
  let startPos = node.findLogEntryByIndex(nextIdx)
  if startPos >= 0:
    for i in startPos..<node.log.len:
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
  if node.metrics != nil:
    inc node.metrics.appendsTotal
  node.saveState()

proc handleVoteReply*(node: RaftNode, reply: RaftMessage) =
  if reply.term > node.currentTerm:
    node.becomeFollower(reply.term)
    return

  if reply.term < node.currentTerm:
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

  if reply.term < node.currentTerm:
    return

  if node.state != rsLeader:
    return

  if reply.success:
    node.matchIndex[peerId] = reply.matchIdx
    node.nextIndex[peerId] = reply.matchIdx + 1

    # Update commit index using true majority calculation
    let majority = (node.peers.len + 1 + 1) div 2  # majority of cluster (peers + leader)
    var newCommitIdx = node.commitIndex

    # Walk logical indices high→low via findLogEntryByIndex (log may be compacted).
    for idx in countdown(int(node.lastLogIndex), int(node.commitIndex) + 1):
      if idx <= 0:
        break
      let pos = node.findLogEntryByIndex(uint64(idx))
      if pos < 0:
        continue
      # Only commit entries from current term (Raft safety property)
      if node.log[pos].term == node.currentTerm:
        var count = 1  # Leader itself
        for peerId2, mIdx in node.matchIndex:
          if mIdx >= uint64(idx):
            inc count
        if count >= majority:
          newCommitIdx = uint64(idx)
          break

    if newCommitIdx > node.commitIndex:
      node.commitIndex = newCommitIdx
      node.applyCommitted()
  else:
    let floor = node.lastSnapshotIndex + 1
    if node.nextIndex.getOrDefault(peerId, 1) > floor:
      dec node.nextIndex[peerId]
    else:
      node.nextIndex[peerId] = floor

proc state*(node: RaftNode): RaftState = node.state
proc isLeader*(node: RaftNode): bool = node.state == rsLeader
proc leaderId*(node: RaftNode): string = node.leaderId
proc logLen*(node: RaftNode): int = node.log.len

proc applyLag*(node: RaftNode): uint64 =
  ## commitIndex - lastApplied (0 when caught up).
  if node.commitIndex > node.lastApplied:
    return node.commitIndex - node.lastApplied
  return 0

proc prometheusText*(node: RaftNode): string =
  ## Prometheus exposition lines for this raft node (gauges + counters).
  let m = if node.metrics != nil: node.metrics else: RaftMetrics()
  let isLead = if node.isLeader: 1 else: 0
  let role = case node.state
    of rsLeader: "leader"
    of rsCandidate: "candidate"
    of rsFollower: "follower"
  result = ""
  result.add("# HELP baradb_raft_is_leader 1 if this node is the raft leader\n")
  result.add("# TYPE baradb_raft_is_leader gauge\n")
  result.add("baradb_raft_is_leader{node=\"" & node.id & "\",role=\"" & role & "\"} " & $isLead & "\n")
  result.add("# HELP baradb_raft_term Current raft term\n")
  result.add("# TYPE baradb_raft_term gauge\n")
  result.add("baradb_raft_term{node=\"" & node.id & "\"} " & $node.currentTerm & "\n")
  result.add("# HELP baradb_raft_log_entries In-memory raft log length\n")
  result.add("# TYPE baradb_raft_log_entries gauge\n")
  result.add("baradb_raft_log_entries{node=\"" & node.id & "\"} " & $node.log.len & "\n")
  result.add("# HELP baradb_raft_commit_index Raft commit index\n")
  result.add("# TYPE baradb_raft_commit_index gauge\n")
  result.add("baradb_raft_commit_index{node=\"" & node.id & "\"} " & $node.commitIndex & "\n")
  result.add("# HELP baradb_raft_last_applied Raft lastApplied index\n")
  result.add("# TYPE baradb_raft_last_applied gauge\n")
  result.add("baradb_raft_last_applied{node=\"" & node.id & "\"} " & $node.lastApplied & "\n")
  result.add("# HELP baradb_raft_apply_lag commitIndex - lastApplied\n")
  result.add("# TYPE baradb_raft_apply_lag gauge\n")
  result.add("baradb_raft_apply_lag{node=\"" & node.id & "\"} " & $node.applyLag & "\n")
  result.add("# HELP baradb_raft_snapshot_index lastSnapshotIndex (compacted base)\n")
  result.add("# TYPE baradb_raft_snapshot_index gauge\n")
  result.add("baradb_raft_snapshot_index{node=\"" & node.id & "\"} " & $node.lastSnapshotIndex & "\n")
  result.add("# HELP baradb_raft_elections_total Times this node became leader\n")
  result.add("# TYPE baradb_raft_elections_total counter\n")
  result.add("baradb_raft_elections_total{node=\"" & node.id & "\"} " & $m.electionsTotal & "\n")
  result.add("# HELP baradb_raft_term_changes_total Term increases observed\n")
  result.add("# TYPE baradb_raft_term_changes_total counter\n")
  result.add("baradb_raft_term_changes_total{node=\"" & node.id & "\"} " & $m.termChangesTotal & "\n")
  result.add("# HELP baradb_raft_appends_total Log appends on this node\n")
  result.add("# TYPE baradb_raft_appends_total counter\n")
  result.add("baradb_raft_appends_total{node=\"" & node.id & "\"} " & $m.appendsTotal & "\n")
  result.add("# HELP baradb_raft_commit_waits_total Successful wait-for-commit completions\n")
  result.add("# TYPE baradb_raft_commit_waits_total counter\n")
  result.add("baradb_raft_commit_waits_total{node=\"" & node.id & "\"} " & $m.commitWaitsTotal & "\n")
  result.add("# HELP baradb_raft_commit_wait_ms_total Sum of commit-wait durations in ms\n")
  result.add("# TYPE baradb_raft_commit_wait_ms_total counter\n")
  result.add("baradb_raft_commit_wait_ms_total{node=\"" & node.id & "\"} " & $m.commitWaitMsTotal & "\n")
  result.add("# HELP baradb_raft_commit_timeouts_total Raft commit wait timeouts\n")
  result.add("# TYPE baradb_raft_commit_timeouts_total counter\n")
  result.add("baradb_raft_commit_timeouts_total{node=\"" & node.id & "\"} " & $m.commitTimeoutsTotal & "\n")
  result.add("# HELP baradb_raft_lost_leadership_total Appends rejected (not leader)\n")
  result.add("# TYPE baradb_raft_lost_leadership_total counter\n")
  result.add("baradb_raft_lost_leadership_total{node=\"" & node.id & "\"} " & $m.lostLeadershipTotal & "\n")
  result.add("# HELP baradb_raft_forwards_total Follower SQL forwards to leader\n")
  result.add("# TYPE baradb_raft_forwards_total counter\n")
  result.add("baradb_raft_forwards_total{node=\"" & node.id & "\"} " & $m.forwardsTotal & "\n")
  result.add("# HELP baradb_raft_forward_errors_total Failed leader forwards\n")
  result.add("# TYPE baradb_raft_forward_errors_total counter\n")
  result.add("baradb_raft_forward_errors_total{node=\"" & node.id & "\"} " & $m.forwardErrorsTotal & "\n")
  result.add("# HELP baradb_raft_applies_total State-machine applyCommand calls\n")
  result.add("# TYPE baradb_raft_applies_total counter\n")
  result.add("baradb_raft_applies_total{node=\"" & node.id & "\"} " & $m.appliesTotal & "\n")
  result.add("# HELP baradb_raft_compactions_total Log prefix compactions\n")
  result.add("# TYPE baradb_raft_compactions_total counter\n")
  result.add("baradb_raft_compactions_total{node=\"" & node.id & "\"} " & $m.compactionsTotal & "\n")
  if m.commitWaitsTotal > 0:
    let avg = m.commitWaitMsTotal div m.commitWaitsTotal
    result.add("# HELP baradb_raft_commit_wait_ms_avg Average commit-wait latency (ms)\n")
    result.add("# TYPE baradb_raft_commit_wait_ms_avg gauge\n")
    result.add("baradb_raft_commit_wait_ms_avg{node=\"" & node.id & "\"} " & $avg & "\n")

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
    if s.readData(result[0].addr, len) != len:
      raise newException(IOError, "Incomplete string read from stream")
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
  # InstallSnapshot trailing fields (appended for wire backward compatibility;
  # pre-v1.3 peers stop reading at matchIdx and ignore these bytes)
  stream.write(msg.snapId)
  stream.write(msg.snapOffset)
  stream.write(uint32(msg.snapData.len))
  if msg.snapData.len > 0:
    stream.writeData(addr msg.snapData[0], msg.snapData.len)
  stream.write(char(if msg.snapDone: 1 else: 0))
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
  # Optional trailing InstallSnapshot fields (absent in pre-v1.3 buffers)
  if not stream.atEnd:
    result.snapId = stream.readUint64()
  if not stream.atEnd:
    result.snapOffset = stream.readUint64()
  if not stream.atEnd:
    let dataLen = int(stream.readUint32())
    result.snapData = newSeq[byte](dataLen)
    if dataLen > 0:
      if stream.readData(addr result.snapData[0], dataLen) != dataLen:
        raise newException(IOError, "Incomplete snapshot data read from stream")
  if not stream.atEnd:
    result.snapDone = stream.readChar() != '\0'
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
    timer*: ElectionTimer
    ## Optional TLS context; nil = plaintext (default, pre-TLS behavior).
    tls*: TLSContext

proc newRaftNetwork*(node: RaftNode, tls: TLSContext = nil): RaftNetwork =
  RaftNetwork(
    node: node,
    running: false,
    peerSockets: initTable[string, AsyncSocket](),
    timer: newElectionTimer(node, node.electionTimeout),
    tls: tls,
  )

const RaftConnectTimeoutMs = 200

proc connectToPeer(net: RaftNetwork, peerId: string) {.async.} =
  ## Dial a peer with a short timeout so a dead peer cannot stall the whole
  ## heartbeat / RequestVote fan-out (default TCP connect can hang for many
  ## seconds, which lets live followers trip their election timers).
  if peerId notin net.node.peerAddrs:
    return
  let (host, port) = net.node.peerAddrs[peerId]
  var sock: AsyncSocket = nil
  try:
    sock = newAsyncSocket()
    let ok = await withTimeout(sock.connect(host, Port(port)), RaftConnectTimeoutMs)
    if not ok:
      sock.close()
      return
    if net.tls != nil:
      try:
        net.tls.wrapClient(sock)
      except CatchableError:
        try: sock.close() except CatchableError: discard
        return
    net.peerSockets[peerId] = sock
  except CatchableError:
    if sock != nil:
      try: sock.close() except CatchableError: discard

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
    except CatchableError:
      try: net.peerSockets[peerId].close() except CatchableError: discard
      net.peerSockets.del(peerId)

proc broadcast*(net: RaftNetwork, msgs: seq[RaftMessage]) {.async.} =
  for i, peer in net.node.peers:
    if i < msgs.len:
      await net.send(peer, msgs[i])

proc processMessage*(net: RaftNetwork, msg: RaftMessage) {.async.} =
  case msg.kind
  of rmkRequestVote:
    let reply = net.node.handleRequestVote(msg)
    await net.send(msg.senderId, reply)
  of rmkRequestVoteReply:
    net.node.handleVoteReply(msg)
  of rmkAppendEntries:
    # A plausible current leader (same acceptance condition as
    # handleAppendEntries) resets the election timer; stale-term
    # messages must not.
    if msg.term >= net.node.currentTerm:
      net.timer.resetTimeout()
    let reply = net.node.handleAppendEntries(msg)
    await net.send(msg.senderId, reply)
  of rmkAppendEntriesReply:
    net.node.handleAppendReply(msg.senderId, msg)
  of rmkInstallSnapshot:
    # Same election-timer rule as AppendEntries: only a plausible current
    # leader resets it.
    if msg.term >= net.node.currentTerm:
      net.timer.resetTimeout()
    let reply = net.node.handleInstallSnapshot(msg)
    await net.send(msg.senderId, reply)
  of rmkInstallSnapshotReply:
    # Leader side of snapshot transfer lands in a follow-up task.
    discard

proc recvExact*(client: AsyncSocket, size: int): Future[string] {.async.} =
  ## Reads exactly `size` bytes from `client`. A short return means the peer
  ## disconnected mid-frame (EOF); callers must treat it as end of stream.
  var buf = ""
  while buf.len < size:
    let chunk = await client.recv(size - buf.len)
    if chunk.len == 0:
      break
    buf.add(chunk)
  return buf

proc receiveLoop(net: RaftNetwork, client: AsyncSocket) {.async.} =
  try:
    while net.running:
      let lenData = await recvExact(client, 4)
      if lenData.len < 4:
        break
      var pos = 0
      let payloadLen = int(readUint32(cast[seq[byte]](lenData), pos))
      let payloadStr = await recvExact(client, payloadLen)
      if payloadStr.len < payloadLen:
        break
      var payload = newSeq[byte](payloadLen)
      for i in 0 ..< payloadLen:
        payload[i] = byte(payloadStr[i])
      let msg = deserializeRaftMessage(payload)
      try:
        await net.processMessage(msg)
      except CatchableError:
        discard
  except CatchableError:
    discard
  finally:
    client.close()

proc heartbeatLoop(net: RaftNetwork) {.async.} =
  ## Fan out heartbeats in parallel so a slow/dead peer cannot delay
  ## AppendEntries to the rest of the cluster.
  while net.running:
    if net.node.state == rsLeader:
      var futs: seq[Future[void]] = @[]
      for peer in net.node.peers:
        let msg = net.node.appendEntries(peer)
        futs.add(net.send(peer, msg))
      for f in futs:
        try:
          await f
        except CatchableError:
          discard
    await sleepAsync(net.node.heartbeatTimeout)

proc timerLoop*(net: RaftNetwork) {.async.}

proc run*(net: RaftNetwork) {.async.} =
  net.socket = newAsyncSocket()
  net.socket.setSockOpt(OptReuseAddr, true)
  net.socket.bindAddr(Port(net.node.raftPort))
  net.socket.listen()
  net.running = true
  net.timer.resetTimeout()
  asyncCheck net.heartbeatLoop()
  asyncCheck net.timerLoop()
  while net.running:
    try:
      let client = await net.socket.accept()
      if net.tls != nil:
        try:
          net.tls.wrapServer(client)
        except CatchableError:
          # Handshake failed (e.g. plaintext dial) — drop, no protocol effect.
          client.close()
          continue
      asyncCheck net.receiveLoop(client)
    except CatchableError:
      break

proc stop*(net: RaftNetwork) =
  net.running = false
  net.timer.stop()
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

proc timerLoop*(net: RaftNetwork) {.async.} =
  ## Production election timer: ticks the node's ElectionTimer until the
  ## network transport is stopped.
  while net.running:
    tick(net.timer, net)
    await sleepAsync(50)
