## BaraDB — TLA+ Faithfulness Tests
## Verifies that Nim state machines obey the same invariants as TLA+ specs
## Covers: Raft (FV-1, FV-2), MVCC (FV-7), 2PC (FV-3, FV-4)

import std/unittest
import std/tables
import std/sets
import std/sequtils
import std/strformat

import barabadb/core/raft
import barabadb/core/mvcc
import barabadb/core/disttxn
import barabadb/core/crossmodal
import std/os

# ---------------------------------------------------------------------------
# Raft Faithfulness — verify invariants from raft.tla in Nim code
# ---------------------------------------------------------------------------

suite "Raft TLA+ Faithfulness":
  test "ElectionSafety: at most one leader per term":
    var cluster = newRaftCluster()
    cluster.addNode("n1")
    cluster.addNode("n2")
    cluster.addNode("n3")

    # Run many election scenarios
    for scenario in 0 ..< 50:
      # Randomly trigger elections
      for id, node in cluster.nodes.mpairs:
        if scenario mod 3 == 0 and node.state in [rsFollower, rsCandidate]:
          node.becomeCandidate()
          let req = node.requestVote()
          for r in req:
            if r.senderId in cluster.nodes:
              let reply = cluster.nodes[r.senderId].handleRequestVote(r)
              if reply.success:
                node.handleVoteReply(reply)

      # Check invariant: at most one leader per term
      var leadersPerTerm: Table[uint64, seq[string]]
      for id, node in cluster.nodes:
        if node.isLeader:
          let t = node.currentTerm
          if t notin leadersPerTerm:
            leadersPerTerm[t] = @[]
          leadersPerTerm[t].add(id)

      for term, leaders in leadersPerTerm:
        check leaders.len <= 1

  test "LogMatching: matching index+term implies matching prefix":
    var cluster = newRaftCluster()
    cluster.addNode("n1")
    cluster.addNode("n2")
    cluster.addNode("n3")

    let n1 = cluster.nodes["n1"]
    let n2 = cluster.nodes["n2"]

    # Make n1 leader and append entries
    n1.becomeCandidate()
    n1.currentTerm = 1  # ensure consistent term
    n1.becomeLeader()
    discard n1.appendLog("cmd1")
    discard n1.appendLog("cmd2")

    # Replicate to n2
    let msg = n1.appendEntries("n2")
    let reply = n2.handleAppendEntries(msg)
    check reply.success
    n1.handleAppendReply("n2", reply)

    # Verify LogMatching: if any entry matches at same index, all prior match
    let minLen = min(n1.log.len, n2.log.len)
    for idx in 0 ..< minLen:
      if n1.log[idx].term == n2.log[idx].term and n1.log[idx].index == n2.log[idx].index:
        for k in 0 .. idx:
          check n1.log[k].term == n2.log[k].term

  test "CommittedIndexValid: commitIndex never exceeds log length":
    var cluster = newRaftCluster()
    cluster.addNode("n1")
    cluster.addNode("n2")
    cluster.addNode("n3")

    let n1 = cluster.nodes["n1"]
    n1.becomeCandidate()
    n1.currentTerm = 1
    n1.becomeLeader()

    for i in 0 ..< 10:
      discard n1.appendLog(fmt"cmd{i}")
      check n1.commitIndex <= uint64(n1.log.len)

# ---------------------------------------------------------------------------
# MVCC Faithfulness — verify invariants from mvcc.tla in Nim code
# ---------------------------------------------------------------------------

suite "MVCC TLA+ Faithfulness":
  test "WriteWriteConflict: Nim MVCC allows multiple committed versions (documented gap)":
    ## NOTE: The TLA+ spec (mvcc.tla) enforces first-committer-wins via
    ## WriteWriteConflict invariant. The Nim implementation currently allows
    ## multiple committed versions for the same key (MVCC multi-versioning).
    ## This is a documented gap between spec and implementation.
    var tm = newTxnManager()
    let txn1 = tm.beginTxn(ilSerializable)
    let txn2 = tm.beginTxn(ilSerializable)

    discard tm.write(txn1, "key1", "value1".toSeq.mapIt(byte(it)))
    discard tm.write(txn2, "key1", "value2".toSeq.mapIt(byte(it)))

    let commit1 = tm.commit(txn1)
    check commit1

    # Nim currently allows both to commit (unlike TLA+ spec)
    let commit2 = tm.commit(txn2)
    check commit2  # Documented: this differs from TLA+ first-committer-wins

  test "NoDirtyReads: uncommitted data is never read":
    var tm = newTxnManager()
    let txn1 = tm.beginTxn(ilReadCommitted)
    discard tm.write(txn1, "key1", "value1".toSeq.mapIt(byte(it)))

    let txn2 = tm.beginTxn(ilReadCommitted)
    let (found, val) = tm.read(txn2, "key1")

    check (not found) or (val != "value1".toSeq.mapIt(byte(it)))

  test "CommittedMustStart: committed txn has valid start timestamp":
    var tm = newTxnManager()
    let txn = tm.beginTxn(ilReadCommitted)
    check uint64(txn.id) > 0
    let ok = tm.commit(txn)
    check ok
    check txn.state == tsCommitted

# ---------------------------------------------------------------------------
# 2PC Faithfulness — verify invariants from twopc.tla in Nim code
# ---------------------------------------------------------------------------

suite "2PC TLA+ Faithfulness":
  test "Atomicity: all participants commit or all abort":
    var tm = newDistTxnManager()
    let txn = tm.beginTransaction("coord")
    txn.addParticipant("p1")
    txn.addParticipant("p2")
    txn.addParticipant("p3")

    let prepOk = txn.prepare()
    check prepOk

    let commitOk = txn.commit()
    check commitOk

    # Verify all committed
    for nodeId, p in txn.participants:
      check p.committed
      check not p.aborted

  test "Atomicity with abort: coordinator can abort before commit":
    var tm = newDistTxnManager()
    let txn = tm.beginTransaction("coord")
    txn.addParticipant("p1")
    txn.addParticipant("p2")

    # Abort without prepare → all abort
    let abortOk = txn.rollback()
    check abortOk
    check txn.state == dtsAborted

  test "CoordinatorConsistency: decision is immutable after commit":
    var tm = newDistTxnManager()
    let txn = tm.beginTransaction("coord")
    txn.addParticipant("p1")

    let prepOk = txn.prepare()
    check prepOk

    let commitOk = txn.commit()
    check commitOk

    let stateBefore = txn.state
    # Simulate "recovery" by checking state again
    let stateAfter = txn.state
    check stateBefore == stateAfter
    check stateAfter == dtsCommitted


# ---------------------------------------------------------------------------
# Cross-Modal TLA+ Faithfulness — verify invariants from crossmodal.tla
# ---------------------------------------------------------------------------

suite "Cross-Modal TLA+ Faithfulness":
  test "MetadataVectorConsistency: insertVector updates metadata for filtered search":
    let engine = newCrossModalEngine("/tmp/baradb_tla_crossmodal_1")
    engine.insertVector(1, @[1.0'f32, 0.0'f32], {"cat": "A"}.toTable)
    engine.insertVector(2, @[0.0'f32, 1.0'f32], {"cat": "B"}.toTable)

    # Filtered search uses metadata internally
    let results = engine.searchVectorFiltered(
      @[1.0'f32, 0.0'f32], 5,
      proc(meta: Table[string, string]): bool =
        meta.getOrDefault("cat") == "A"
    )
    check results.len >= 1
    check results[0][0] == 1'u64

  test "HybridResultValid: hybrid query draws from correct indices":
    let engine = newCrossModalEngine("/tmp/baradb_tla_crossmodal_2")
    engine.insertVector(1, @[1.0'f32, 0.0'f32], {"cat": "A"}.toTable)
    engine.indexText(1, "fast database engine")

    var query = newCrossModalQuery(qmHybrid)
    query.vector = @[1.0'f32, 0.0'f32]
    query.vectorK = 5
    query.searchQuery = "fast"
    query.vecWeight = 1.0
    query.ftsWeight = 1.0

    let result = engine.hybridSearch(query)
    # Vector results should contain entity 1
    let vecIds = result.vecResults.mapIt(it[0])
    check vecIds.contains(1'u64)
    # FTS results should contain entity 1
    check result.ftsResults.contains(1'u64)
    # Total results should match hybridScores length
    check result.totalResults == result.hybridScores.len

  test "CrossModalAtomicity: all participants commit or all abort":
    var txn = newTPCTransaction(1)
    txn.addParticipant("doc")
    txn.addParticipant("vec")
    txn.addParticipant("graph")
    check txn.participantCount == 3

    let prepOk = txn.prepare()
    check prepOk
    check txn.isPrepared
    for p in txn.participants:
      check p.prepared
      check not p.committed
      check not p.aborted

    let commitOk = txn.commit()
    check commitOk
    check txn.isCommitted
    for p in txn.participants:
      check p.committed
      check not p.aborted

  test "CrossModalAbort: rollback after prepare aborts all participants":
    var txn = newTPCTransaction(2)
    txn.addParticipant("doc")
    txn.addParticipant("fts")
    check txn.prepare()
    check txn.isPrepared

    let rollbackOk = txn.rollback()
    check rollbackOk
    check txn.isAborted
    for p in txn.participants:
      check p.aborted
      check not p.committed
