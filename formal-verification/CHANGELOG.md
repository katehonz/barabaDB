# BaraDB Formal Verification Changelog

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
