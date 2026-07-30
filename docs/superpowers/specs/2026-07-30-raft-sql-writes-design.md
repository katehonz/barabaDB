# SQL Writes Through Raft (C3b) — Design

Date: 2026-07-30  
Status: **Done** (merged to `main`). Extended by post-C3b work (DDL, forward,
compact, metrics) — see `2026-07-30-raft-cluster-status.md`.

## Problem

With C3a a real Raft cluster elects a leader over TCP, but SQL writes still
bypassed Raft: they went straight to the local LSM. Committed Raft entries
could be applied (`applyCommand`), yet nothing called `appendLog` from the
write path.

## Goal (delivered)

When Raft is enabled, SQL writes commit through the Raft log before the client
sees success:

- **Leader:** execute locally, append KV pairs (`put` / `delete`), wait for
  majority `commitIndex`, return.
- **Followers:** originally reject with `not leader; leader is '…'`; with
  `BARADB_RAFT_CLIENT_PEERS` they **forward** to the leader (post-C3b).
- **Apply:** LSM + secondary B-tree/FTS/HNSW + in-memory graphs
  (`applyReplicatedPut` / `Delete`).
- **Non-raft:** behavior gated on `raftNode == nil`.

## Design (as shipped)

### Write interception

`core/server.nim` `executeQuery`:

1. Classify every statement: `isWrite` / `isRaftDdl` (not only `stmts[0]`).
2. If raft active and write/DDL: require **default** database + leader (or
   forward).
3. After success: pure DML → `appendWriteToRaft`; any DDL in batch →
   `appendDdlToRaft` (full SQL re-exec on apply).

### Wait-for-commit

Poll `commitIndex` outside the storage gate (`appendWriteToRaft` /
`waitRaftCommit`); timeout → `raft commit timeout`.

### Known v1 limitations (still true)

- Multi-DB raft not supported (`raft writes only supported on the 'default' database`).
- `CREATE`/`DROP DATABASE` not raft-replicated.
- Leader local execute before majority (timeout leaves local write; documented).
- No InstallSnapshot full SM dump (safe log compact only).
- No membership changes.

## Tests

- Unit: classification, append/timeout, apply indexes/graphs, compact, metrics
- E2E: `tests/raft_writes_e2e_test.nim` (schema, forward, index SELECT, failover)
