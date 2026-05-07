# BaraDB Formal Verification Suite

**Version:** 1.0.0 (see VERSION)

This directory contains TLA+ specifications for core BaraDB distributed-systems algorithms. These specifications serve as machine-checkable certificates of correctness for the most critical consensus, transaction, replication, membership, concurrency, and sharding protocols.

## Structure

| File | Algorithm | Key Properties |
|------|-----------|----------------|
| `raft.tla` | Raft Consensus | Election safety, leader append-only, state-machine safety, log matching, leader completeness |
| `twopc.tla` | Two-Phase Commit | Atomicity (all commit or all abort), no orphan blocks, coordinator consistency |
| `mvcc.tla` | MVCC / Snapshot Isolation | Read-own-writes, no dirty reads, write-write conflict, read stability, snapshot isolation |
| `replication.tla` | Async / Sync / Semi-sync Replication | Monotonic LSN, sync durability, semi-sync quorum, applied <= current |
| `gossip.tla` | SWIM Gossip Protocol | Alive-not-falsely-dead, incarnation monotonicity, dead consistency |
| `deadlock.tla` | Deadlock Detection | Cycle detection correctness, victim selection consistency, graph integrity |
| `sharding.tla` | Consistent Hash Sharding | Virtual node mapping, node assignment consistency, vnode ordering |

## Prerequisites

- Java Runtime Environment (JRE) 8+ — the bundled `tla2tools.jar` contains TLC and SANY.
- Or [TLA+ Toolbox](https://lamport.azurewebsites.net/tla/toolbox.html) (GUI + TLC model checker).

## Verified State Space (v1.1.0)

| Spec | States Generated | Distinct States | Depth |
|------|-----------------|-----------------|-------|
| raft.tla | 3,031,684 | 833,024 | 47 |
| twopc.tla | 22,855,681 | 2,097,152 | 31 |
| mvcc.tla | 177,849 | 59,860 | 13 |
| replication.tla | 3,687,939 | 490,560 | 22 |
| gossip.tla | 1,257,121 | 110,592 | 28 |
| deadlock.tla | 3,767,361 | 263,950 | 9 |
| sharding.tla | 186,305 | 23,296 | 11 |
| **Total** | **34,963,940** | **3,878,434** | — |

## Running the Model Checker

### All specs at once
```bash
cd formal-verification
./run_all.sh
```

### Individual specs (command line)
```bash
cd formal-verification

# Syntax check (parse)
java -cp tla2tools.jar tla2sany.SANY raft.tla

# Model check with small parameters
java -cp tla2tools.jar tlc2.TLC -config models/raft.cfg raft.tla
java -cp tla2tools.jar tlc2.TLC -config models/twopc.cfg twopc.tla
java -cp tla2tools.jar tlc2.TLC -config models/mvcc.cfg mvcc.tla
java -cp tla2tools.jar tlc2.TLC -config models/replication.cfg replication.tla
java -cp tla2tools.jar tlc2.TLC -config models/gossip.cfg gossip.tla
java -cp tla2tools.jar tlc2.TLC -config models/deadlock.cfg deadlock.tla
java -cp tla2tools.jar tlc2.TLC -config models/sharding.cfg sharding.tla
```

### GUI (TLA+ Toolbox)
1. Open the Toolbox.
2. `File → Open Spec → Add New Spec…` → select a `.tla` file.
3. Create a new model (`TLC Model Checker → New Model`).
4. Click the green play button to verify all invariants and temporal properties.

## Verified Properties

### raft.tla
- `ElectionSafety` — at most one leader per term.
- `LeaderAppendOnly` — a leader never produces invalid log entries.
- `StateMachineSafety` — if a node has committed a log entry at a given index, no other node has a different entry for the same index.
- `CommittedIndexValid` — commitIndex never exceeds the node's log length.
- `LogMatching` — if two logs contain an entry with the same index and term, all preceding entries are identical.

### twopc.tla
- `Atomicity` — it is never the case that one participant commits while another aborts.
- `NoOrphanBlocks` — once a transaction is committed, every participant is committed.
- `CoordinatorConsistency` — once the coordinator decides, it never changes the decision.
- `NoDecideWithoutConsensus` — coordinator only decides when all votes are collected.
- `ParticipantStateValid` — participant states are consistent with the coordinator decision.

### mvcc.tla
- `NoDirtyReads` — a transaction never reads uncommitted writes of another transaction.
- `ReadOwnWrites` — a transaction always reads its own writes.
- `WriteWriteConflict` — no two committed transactions write the same key (first-committer-wins).
- `CommittedMustStart` — committed transactions have a valid start timestamp.
- `CommittedVersionsUnique` — no two committed versions for a key share the same txnId.
- `NoWriteSkew` — no two committed transactions have a circular read-write dependency.

### replication.tla
- `MonotonicLsn` (temporal) — the applied LSN never decreases.
- `AcksRemovePending` — a replica that acked an LSN is no longer pending for it.
- `PendingAreKnown` — all pending acks reference valid replica IDs.
- `AppliedLteCurrent` — applied LSN never exceeds current LSN.

### gossip.tla
- `AliveNotFalselyDead` — an alive member is never reported as dead by any peer.
- `IncarnationMonotonic` — incarnation numbers only increase.
- `DeadConsistency` — once dead, a node knows it is dead (self-consistency).

### deadlock.tla
- `GraphIntegrity` — all edges reference known transaction IDs.
- `NoSelfLoops` — no transaction waits on itself.

### sharding.tla
- `VirtualNodeMapping` — each vnode maps to Nil or a valid shard.
- `NodeAssignmentConsistency` — node-to-shard assignments are well-formed.
- `VnodeOrdering` — virtual nodes are assigned in monotonic position order.

## Extending

To add a new algorithm:
1. Write the TLA+ spec (preferably with PlusCal for readability).
2. Define invariants that capture the safety properties you need.
3. Add a `<name>.tla` file and a matching `<name>.cfg` in `models/`.
4. Run TLC and confirm `No error has been found.`
5. Add the command to `run_all.sh`.
6. Update this README.
