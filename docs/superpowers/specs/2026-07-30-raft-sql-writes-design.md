# SQL Writes Through Raft (C3b) — Design

Date: 2026-07-30
Status: Approved direction (user: "ок ... продължавай"); implementation follows.

## Problem

With C3a a real Raft cluster elects a leader over TCP, but SQL writes still
bypass Raft entirely: they go straight to the local LSM and (optionally) to
the legacy `ReplicationManager` (unconnected in production). Committed Raft
entries can be applied (`applyCommand` is wired and invoked on commit), yet
nothing ever calls `appendLog` from the write path.

## Goal

When Raft is enabled, SQL writes are committed through the Raft log before
the client sees success:

- Leader: execute locally (constraints validated as today), append the
  resulting KV pairs to the Raft log, wait for majority commit, then return.
- Followers: reject write statements with a clear "not leader" error naming
  the known leader; apply committed entries via the existing `applyCommand`
  loop (raft.nim:195-215).
- Non-raft deployments: byte-identical behavior to today.

Non-goals (C3c+): leader forwarding/proxy, read consistency levels,
schema/DDL replication (DDL produces no keyValuePairs today — out of scope),
membership, snapshots.

## Design

### Write interception point

`core/server.nim:206-227` — the server-level `executeQuery` parses the AST
(server.nim:213) and, after successful execution, already ships
`res.keyValuePairs` to the ReplicationManager (server.nim:219-227). The Raft
path slots into the same place with the same data source:

1. Classify the statement right after parse: write = `stmt.kind in {nkInsert,
   nkUpdate, nkDelete, nkMerge}` (DDL is out of scope; SELECT unaffected).
   New helper `isWrite(stmt)` in `exec/params.nim` next to `isDDL`.
2. If Raft is active for this server (`server.raftNode != nil`):
   - Not leader (`node.state != rsLeader`): return error
     `not leader; leader is '<node.leaderId>'` (or `no leader elected`).
     The statement is NOT executed.
   - Leader: execute as today. If `res.success` and
     `res.keyValuePairs.len > 0`: for each `(key, value)` append one log
     entry — `cmd = "put"` with data `key \x00 value`, or `cmd = "delete"`
     with data `key` when value is empty (this is EXACTLY the format the
     existing `applyCommand` in baradadb.nim:336-343 already consumes — no
     format changes, frozen). Then wait until `node.commitIndex` reaches the
     last appended index (see below) before returning `res`.
   - The legacy `replication.writeLsn` hook is skipped when the Raft write
     path handled the statement (no double shipping).
3. Single-node raft (enabled, no peers): majority is self — appends commit
   immediately; behavior is correct with negligible overhead.

### Wait-for-commit

No raft.nim changes (the state machine stays TLA-frozen). Poll from
server.nim: after appending, `while node.commitIndex < lastIdx`: sleep 10ms,
up to `config.raftWriteTimeoutMs` (new env `BARADB_RAFT_WRITE_TIMEOUT_MS`,
default 5000). Commit advances on the 50ms heartbeat cadence via the
existing `handleAppendReply`/`applyCommitted` path, so typical latency is
one heartbeat. On timeout: return an error (`raft commit timeout`) — the
entry may still commit later; documented limitation. Local execution already
happened (it validates constraints and produces kvPairs) — leader double-
applies via applyCommand on commit, which is idempotent for put/delete KV.

### Server wiring

`Server` gains `raftNode*: RaftNode` (nil by default) in core/server.nim;
baradadb.nim assigns it when raft is enabled (the node already exists there).
server.nim imports core/raft (no cycle: raft.nim does not import server).

### Known v1 limitations (documented in code)

- Leader losing leadership between local execution and appendLog (narrow
  race): appendLog returns the empty entry (index 0) — surfaced as a
  `lost leadership` error; the local write already applied (uncommitted).
- Transactional writes: kvPairs are emitted at COMMIT (executor.nim:970-979)
  — the COMMIT statement is the raft-replicated unit (classify nkCommitTxn?
  — resolve in planning: COMMIT's kvPairs flow through the same hook since
  the existing replication hook already catches them).
- DDL is not replicated (no kvPairs today).

## Testing

1. Unit (`tests/bugfix_test.nim`): `isWrite` classification for
   INSERT/UPDATE/DELETE/MERGE vs SELECT/DDL.
2. Follower rejection (in-process or E2E): write on a follower returns the
   "not leader" error naming the leader; the statement is not executed.
3. E2E (extend `tests/raft_e2e_test.nim` or sibling): 3 real nodes; write a
   row on the leader via the Nim client (adaptors/nim/baradb_sqlite pattern
   from nimforum_smoke_test); poll a SELECT on a follower until the row
   appears (deadline ~5s — follower applies on commit via applyCommand);
   write on a follower → rejected; kill leader → re-election → writes work
   on the new leader.
4. Full `nimble test` green (673+ `[OK]`).

## Risks

- Double application on the leader (executor + applyCommand): idempotent
  KV semantics — verify put/delete idempotency holds for the value encoding
  (same key → same value; delete of existing key).
- `node.log[idx-1]` positional indexing in the leader commit loop
  (raft.nim:407) — pre-existing, out of scope unless the E2E trips it.
- Apply lag on followers (heartbeat cadence): tests poll with deadlines,
  never fixed sleeps.
