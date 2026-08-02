# Known Limitations — v1.3.0

This page defines **what BaraDB promises** in the v1.3.0 production cut.

| Tier | Meaning |
|------|---------|
| **Supported (GA)** | Documented, tested, appropriate for production apps that fit the scope |
| **Experimental** | Works in tests/ops demos; not a reliability SLA target |
| **Not supported** | Out of scope; may fail or corrupt assumptions |

## Support matrix

| Area | v1.3.0 | Notes |
|------|--------|-------|
| Single-node SQL + LSM storage | **Supported** | — |
| Schema persistence (tables, indexes) | **Supported** | — |
| FTS / HNSW / graphs across restart | **Supported** | — |
| Auth + JWT (when configured) | **Supported** | — |
| Backup / restore (offline, all-databases) | **Supported** | — |
| Multi-database (non-Raft) | **Supported** | — |
| Raft 3-node (single `default` DB) | **Supported** | failover under load, raft TLS, InstallSnapshot recovery — e2e-proven |
| Leader write forwarding | **Supported** | needs `BARADB_RAFT_CLIENT_PEERS` |
| Raft multi-database | **Not supported** | only `default` |
| `CREATE`/`DROP DATABASE` replication | **Not supported** | run per node |
| Raft membership changes (join/leave) | **Not supported** | fixed `BARADB_RAFT_PEERS` set |
| Follower linearizable reads | **Not supported** | best-effort after apply |
| Rolling upgrades | **Not supported** | restart all nodes together — mixed v1.2/v1.3 binaries must not run in one cluster |
| ORC multi-threaded shared LSM | **Not supported** | default is ARC (`nim.cfg`) |
| Postgres wire protocol | **Not supported** | Bara wire + HTTP |

## Single-node GA (what you can rely on)

- Process crash + WAL recovery for the default durability settings
- CREATE TABLE / indexes that survive restart (see engine-persistence work)
- HTTP `/health` and `/metrics` for process liveness
- Offline backup of `data/databases` and restore onto an empty data root

## Raft (supported, single-default-DB scope)

Documented in [distributed.md](distributed.md). Supported scope:

- 3-node cluster, SQL DML/DDL on **`default` only**
- Failover under write load: every acknowledged write survives a leader kill; in-flight writes fail fast — clients must retry
- TLS on the raft port and on follower→leader forwarding (`BARADB_RAFT_TLS_*`)
- Cold-node recovery via InstallSnapshot (`BARADB_RAFT_SNAP_CHUNK_KB`, `BARADB_RAFT_PEER_STALE_MS`)

## Newly documented limitations

- **Legacy non-raft REP replication delete inference** — resolved: the non-raft REP payload now carries an explicit put/delete op tag (`encodeRepPayload`/`decodeRepPayload` in `core/replication.nim`), so PK-only inserts (empty LSM value) replicate as puts instead of being misapplied as deletes.
- **Snapshot-restore ctx staleness** — after an InstallSnapshot restore, HTTP endpoints using the startup-captured ctx may serve stale data until the node is restarted; the `/query` path is fresh per-request. Pre-existing client connections likewise see pre-restore state — reconnect after a restore.
- **FK-cascade divergence under raft** — `ON DELETE/UPDATE CASCADE` (and `SET NULL`) effects are not raft-replicated: followers only apply the parent row's KV change, so cascaded child rows persist on followers. Avoid FK actions on raft-replicated tables, or accept periodic snapshot resync.
- **Uncommitted writes in snapshots** — the leader applies writes locally before raft majority commit; a snapshot taken in that window can include writes that never commit (phantom rows after restore + leadership change). Narrow window; fix tracked for a later release.
- **Event-loop stall during snapshot build/restore** — partially mitigated: the leader's snapshot *send* now tars under the storage gate but runs the CPU-heavy gzip off the event loop on a worker thread (`gzipFileAsync` in `core/backup.nim`), so heartbeats keep firing during compression. The tar itself (send path) and the whole *restore* path (tar extract + DB reopen) still run on the event loop, so very large data dirs can still stall heartbeats during those phases; a full fix (an async/try-lock storage gate so the loop never blocks) is tracked for a later release.

## Operational requirements

- Set a strong `BARADB_JWT_SECRET` and `BARADB_AUTH_ENABLED=true` in production (see prod compose)
- Test restores regularly (`scripts/backup-restore-drill.sh`)
- Do not share one data directory between two running processes

## See also

- [Deployment / runbook](deployment.md)
- [Backup](backup.md)
- [Raft cluster status](../superpowers/specs/2026-07-30-raft-cluster-status.md)
- [Production GA plan](../superpowers/plans/2026-07-30-production-ga.md)
