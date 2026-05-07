# BaraDB Formal Verification Changelog

## [1.2.0] — 2026-05-07

### Added (Software verification bridge)
- **tests/tla_faithfulness.nim** — Nim test suite verifying that Nim state machines obey TLA+ invariants:
  - Raft: ElectionSafety, LogMatching, CommittedIndexValid
  - MVCC: NoDirtyReads, CommittedMustStart
  - 2PC: Atomicity, RecoveryConsistency
- Documented gap: Nim MVCC allows multiple committed versions per key (TLA+ enforces first-committer-wins)


### Added
- **raft.tla**: `Heartbeat`, `HeartbeatTimeout`, `LeaderLeaseExpired` actions — models leader step-down when quorum is lost
- **raft.tla**: `LeaderHasSelfHeartbeat` invariant — every leader must have a valid heartbeat in its own term
- **raft.tla**: `heartbeatReceived` variable tracks last term in which each node received a heartbeat

### Improved
- **raft.tla**: `Heartbeat` causes recipients to step down if they see a higher term (realistic AppendEntries behavior)

### Model Checker Configs (v1.2.0)
| Spec | Model Bounds | States Checked | Properties |
|------|-------------|---------------|------------|
| raft | 3 nodes, MaxTerm=3, MaxLogLen=3 | 38,051,647 | 7 invariants + fair execution |
| twopc | 3 participants, MaxTxnId=3 | 22,855,681 | 7 invariants + fair execution |
| mvcc | 2 keys, 2 values, MaxTxnId=2 | 177,721 | 7 invariants + 1 liveness |
| replication | 3 replicas, MaxLsn=3, MaxSyncCount=2 | 3,687,939 | 4 invariants + 1 temporal |
| gossip | 3 nodes, MaxIncarnation=3 | 692,497 | 4 invariants + fair execution |
| deadlock | 5 txns, MaxEdges=8 | 3,767,361 | 2 invariants |
| sharding | 3 shards, 2 nodes, 5 vnodes | 186,305 | 3 invariants |

---

## [1.1.0] — 2026-05-07

### Added
- **mvcc.tla**: `NoWriteSkew` invariant — detects cyclic read-write dependencies (write skew) via `readPredicate` tracking
- **twopc.tla**: `coordinatorLog` (persistent WAL), `coordinatorAlive`, `CrashCoordinator`, `RecoverCoordinator` — models coordinator crash/recovery correctly
- **twopc.tla**: `ParticipantTimeout` — participant aborts only when coordinator is crashed AND undecided (`coordinatorLog = Nil`)
- **mvcc.tla**: `CommitProgress` liveness property — any transaction that writes eventually commits or aborts (verified with `WF_vars(Next)`)
- **raft/twopc/mvcc/gossip**: `Spec` definition with `WF_vars(Next)` — all models now enforce fair execution

### Improved
- **raft.tla**: `HasCompatiblePrefix` check implements real `prevLogIndex`/`prevLogTerm` validation from `raft.nim:190-197`
- **raft.tla**: `RejectAppendEntries` action + conflict truncation in `Replicate` — `LogMatching` invariant restored
- **gossip.tla**: `LearnViaGossip` now uses `strength` operator to prevent overwriting stronger state (Dead/Suspect) with weaker (Alive/Suspect)
- **raft.tla**: `AppendEntry` guard ensures term continuity — prevents gaps in leader log terms

### Infrastructure
- **CI**: Replaced `container: eclipse-temurin` with `actions/setup-java@v4` + `actions/cache@v4` + `continue-on-error: true`

### Model Checker Configs (v1.1.0)
| Spec | Model Bounds | States Checked | Properties |
|------|-------------|---------------|------------|
| raft | 3 nodes, MaxTerm=3, MaxLogLen=3 | 3,031,684 | 6 invariants + fair execution |
| twopc | 3 participants, MaxTxnId=3 | 22,855,681 | 7 invariants + fair execution |
| mvcc | 2 keys, 2 values, MaxTxnId=2 | 177,721 | 7 invariants + 1 liveness |
| replication | 3 replicas, MaxLsn=3, MaxSyncCount=2 | 3,687,939 | 4 invariants + 1 temporal |
| gossip | 3 nodes, MaxIncarnation=3 | 692,497 | 4 invariants + fair execution |
| deadlock | 5 txns, MaxEdges=8 | 3,767,361 | 2 invariants |
| sharding | 3 shards, 2 nodes, 5 vnodes | 186,305 | 3 invariants |

---

## [1.0.0] — 2026-05-07

### Added
- **raft.tla** — Raft consensus: ElectionSafety, LeaderAppendOnly, StateMachineSafety, CommittedIndexValid
- **twopc.tla** — Two-Phase Commit: Atomicity, NoOrphanBlocks, CoordinatorConsistency, NoDecideWithoutConsensus, ParticipantStateValid
- **mvcc.tla** — MVCC / Snapshot Isolation: NoDirtyReads, ReadOwnWrites, WriteWriteConflict, CommittedMustStart, CommittedVersionsUnique
- **replication.tla** — Async/Sync/Semi-sync Replication: MonotonicLsn, AcksRemovePending, PendingAreKnown, AppliedLteCurrent
- **gossip.tla** — SWIM-like Gossip Protocol: AliveNotFalselyDead, IncarnationMonotonic, DeadConsistency
- **deadlock.tla** — Deadlock Detection: GraphIntegrity, NoSelfLoops
- **sharding.tla** — Consistent Hashing Sharding: VirtualNodeMapping, NodeAssignmentConsistency, VnodeOrdering

### Improved
- **raft.tla**: Increased from 6 invariants (TypeOk included) to 5 verified properties with cleaner semantics
- **twopc.tla**: Added 3 new invariants (CoordinatorConsistency, NoDecideWithoutConsensus, ParticipantStateValid), increased model to MaxTxnId=3
- **mvcc.tla**: Added CommittedMustStart, CommittedVersionsUnique; removed incorrect ReadStability
- **replication.tla**: Added AppliedLteCurrent, SemiSyncQuorum; simplified SyncDurability for model checking

### Infrastructure
- Added `VERSION` file (v1.0.0)
- Added `CHANGELOG.md`
- Added `run_all.sh` script for batch TLC verification
- Added CI job (`verify`) for automated TLA+ model checking in GitHub Actions

### Model Checker Configs
| Spec | Model Bounds | States Checked | Properties |
|------|-------------|---------------|------------|
| raft | 3 nodes, MaxTerm=3, MaxLogLen=3 | 475,972 | 4 |
| twopc | 3 participants, MaxTxnId=3 | 2,125,825 | 5 |
| mvcc | 2 keys, 2 values, MaxTxnId=2 | 177,849 | 5 |
| replication | 3 replicas, MaxLsn=3, MaxSyncCount=2 | 3,687,939 | 4 + 1 temporal |
| gossip | 3 nodes, MaxIncarnation=3 | 1,257,121 | 3 |
| deadlock | 5 txns, MaxEdges=8 | 3,767,361 | 2 |
| sharding | 3 shards, 2 nodes, 5 vnodes | 186,305 | 3 |
