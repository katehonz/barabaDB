# BaraDB Formal Verification Suite

This directory contains TLA+ specifications for core BaraDB distributed-systems algorithms. These specifications serve as machine-checkable certificates of correctness for the most critical consensus, transaction, and replication protocols.

## Structure

| File | Algorithm | Key Properties |
|------|-----------|----------------|
| `raft.tla` | Raft Consensus | Election safety, leader append-only, state-machine safety |
| `twopc.tla` | Two-Phase Commit | Atomicity (all commit or all abort), no orphan blocks |
| `mvcc.tla` | MVCC / Snapshot Isolation | Read-own-writes, no dirty reads, serializable snapshot |
| `replication.tla` | Async / Sync / Semi-sync Replication | Monotonic LSN, sync durability, semi-sync quorum |

## Prerequisites

- [TLA+ Toolbox](https://lamport.azurewebsites.net/tla/toolbox.html) (GUI + TLC model checker)
- Or the command-line tools: `tlc`, `pcal`, `sany`

## Running the Model Checker

### GUI (TLA+ Toolbox)
1. Open the Toolbox.
2. `File → Open Spec → Add New Spec…` → select a `.tla` file.
3. Create a new model (`TLC Model Checker → New Model`).
4. Click the green play button to verify all invariants and temporal properties.

### Command Line
```bash
cd formal-verification

# Parse
java -cp tla2tools.jar tla2sany.SANY raft.tla

# Model check with small parameters
java -cp tla2tools.jar tlc2.TLC -config models/raft.cfg raft.tla
```

## Verified Properties

### raft.tla
- `ElectionSafety` — at most one leader per term.
- `LeaderAppendOnly` — a leader never overwrites or deletes entries in its own log.
- `StateMachineSafety` — if a node has applied a log entry at a given index, no other node ever applies a different entry for the same index.

### twopc.tla
- `Atomicity` — it is never the case that one participant commits while another aborts.
- `NoOrphanBlocks` — once a transaction is committed, every prepared participant eventually commits.

### mvcc.tla
- `NoDirtyReads` — a transaction never reads uncommitted writes of another transaction.
- `ReadOwnWrites` — a transaction always reads its own most recent writes.
- `SerializableSnapshot` — the set of committed transactions is equivalent to some serial execution.

### replication.tla
- `MonotonicLsn` (temporal) — the applied LSN never decreases.
- `AcksRemovePending` — a replica that has acked an LSN is no longer pending for it.
- `PendingAreKnown` — all pending acks refer to valid replica IDs.

## Extending

To add a new algorithm:
1. Write the TLA+ spec (preferably with PlusCal for readability).
2. Define invariants that capture the safety properties you need.
3. Add a `<name>.tla` file and a matching `<name>.cfg` in `models/`.
4. Run TLC and confirm `No error has been found.`
