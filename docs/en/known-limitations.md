# Known Limitations — v1.2.0 Production GA

This page defines **what BaraDB promises** in the v1.2.0 production cut.

| Tier | Meaning |
|------|---------|
| **Supported (GA)** | Documented, tested, appropriate for production apps that fit the scope |
| **Experimental** | Works in tests/ops demos; not a reliability SLA target |
| **Not supported** | Out of scope; may fail or corrupt assumptions |

## Support matrix

| Area | GA (v1.2.0) | Experimental / later |
|------|-------------|----------------------|
| Single-node SQL + LSM storage | **Supported** | — |
| Schema persistence (tables, indexes) | **Supported** | — |
| FTS / HNSW / graphs across restart | **Supported** | — |
| Auth + JWT (when configured) | **Supported** | — |
| Backup / restore (offline, all-databases) | **Supported** | — |
| Multi-database (non-Raft) | **Supported** | — |
| Raft 3-node election + SQL/DDL | **Experimental** | InstallSnapshot SM payload, membership |
| Raft multi-database | **Not supported** | only `default` |
| Leader write forwarding | **Experimental** | needs `BARADB_RAFT_CLIENT_PEERS` |
| Follower linearizable reads | **Not supported** | best-effort after apply |
| ORC multi-threaded shared LSM | **Not supported** | default is ARC (`nim.cfg`) |
| Zero-downtime rolling upgrade | **Not supported** | stop → backup → upgrade |
| Postgres wire protocol | **Not supported** | Bara wire + HTTP |

## Single-node GA (what you can rely on)

- Process crash + WAL recovery for the default durability settings
- CREATE TABLE / indexes that survive restart (see engine-persistence work)
- HTTP `/health` and `/metrics` for process liveness
- Offline backup of `data/databases` and restore onto an empty data root

## Raft (experimental ops)

Documented in [distributed.md](distributed.md). Suitable for learning and careful staging; **not** the v1.2.0 HA product tier.

- SQL DML/DDL on **`default` only**
- Safe log prefix compact (not full InstallSnapshot)
- Failover proven in process e2e tests

## Operational requirements

- Set a strong `BARADB_JWT_SECRET` and `BARADB_AUTH_ENABLED=true` in production (see prod compose)
- Test restores regularly (`scripts/backup-restore-drill.sh`)
- Do not share one data directory between two running processes

## See also

- [Deployment / runbook](deployment.md)
- [Backup](backup.md)
- [Raft cluster status](../superpowers/specs/2026-07-30-raft-cluster-status.md)
- [Production GA plan](../superpowers/plans/2026-07-30-production-ga.md)
