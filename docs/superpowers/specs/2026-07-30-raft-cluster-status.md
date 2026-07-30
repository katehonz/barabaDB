# Raft Cluster Status — C3a / C3b / post-C3b

Date: 2026-07-30  
Status: **Shipped on `main`** (tip includes metrics).  
Branch: all work merged to `main` only (feature branch removed).

## Phase map

| Phase | Spec / plan | Status | What landed |
|-------|-------------|--------|-------------|
| **C3a** Network bootstrap | `raft-network-bootstrap-design.md` + plan | **Done** | `id@host:port` peers, election timer in production, AppendEntries resets timer, `dataDir` persistence, partial-read frames, `tests/raft_e2e_test.nim` |
| **C3b** SQL writes | `raft-sql-writes-design.md` + plan | **Done** | `isWrite`, follower reject / forward, leader append+wait-commit, rich apply (LSM+index+graph), multi-stmt gate, default-DB only, `tests/raft_writes_e2e_test.nim` |
| **C3c-lite** DDL + ops | (this status doc) | **Done** | DDL via `ddl` log entries; leader forwarding (`BARADB_RAFT_CLIENT_PEERS`); safe log compact + snapshot metadata; Prometheus + `/health` raft |

## Key commits (main)

| Commit (short) | Summary |
|----------------|---------|
| C3a series | peers, timer, frames, e2e election |
| `38c1c01`…`a462d21` | C3b classification → append → e2e → docs |
| `0d51497` | multi-stmt gate, rich apply, delete kv |
| `50f827f` | graph apply, non-default DB reject |
| `095698b` | DDL through raft |
| `9df8316` | leader write/DDL forwarding |
| `53704e1` | safe log compaction + snapshot base |
| `1b3c261` | raft metrics on `/metrics` + `/health` |

## Production behavior (summary)

1. Enable with `BARADB_RAFT_*` env (see `docs/en/distributed.md`).
2. Cluster elects a leader over TCP; state in `dataDir/raft/raft_state.bin`.
3. DML/DDL on **default** DB only: leader appends, waits for majority, returns.
4. Followers forward to leader if `BARADB_RAFT_CLIENT_PEERS` is set; else `not leader`.
5. Apply updates LSM + secondary engines; DDL re-executes SQL on each node.
6. Log soft-cap via safe prefix compact; metrics on HTTP port `BARADB_PORT+440`.

## Explicit non-goals still open

- Multi-database raft (only `default`)
- `CREATE`/`DROP DATABASE` replication
- Membership change (join/leave) protocol
- InstallSnapshot with full SM / LSM payload (v1 uses safe-prefix compact only)
- Raft port TLS / mutual auth
- Read consistency levels (read-your-writes, linearizable reads on followers)
- Automatic client redirect without `CLIENT_PEERS`

## Tests

| Suite | Covers |
|-------|--------|
| `tests/raft_e2e_test.nim` | 3-process election + failover |
| `tests/raft_writes_e2e_test.nim` | DDL + DML replicate, forward, index SELECT, failover writes |
| `tests/test_all.nim` | in-process raft, append/wait, compact, metrics |
| `tests/tla_faithfulness.nim` | ElectionSafety, LogMatching, … |
| `tests/bugfix_test.nim` | peers / client peers / isWrite / isRaftDdl |

## Docs to keep in sync

- `docs/en/distributed.md` / `docs/bg/distributed.md` — operator guide
- `docs/en/monitoring.md` — health/metrics (raft section)
- `CHANGELOG.md` — `[1.2.0] Unreleased` Raft section
- README raft status line
