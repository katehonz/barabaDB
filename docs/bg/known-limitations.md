# Известни ограничения — v1.2.0 Production GA

| Ниво | Значение |
|------|----------|
| **Supported (GA)** | Документирано, тествано, подходящо за prod в обхвата |
| **Experimental** | Работи в тестове/demo; не е HA SLA |
| **Not supported** | Извън обхват |

## Матрица

| Област | GA (v1.2.0) | Experimental / по-късно |
|--------|-------------|-------------------------|
| Single-node SQL + LSM | **Supported** | — |
| Schema / FTS / HNSW / graphs persist | **Supported** | — |
| Auth + JWT (когато е конфигуриран) | **Supported** | — |
| Backup / restore | **Supported** | — |
| Multi-DB (без Raft) | **Supported** | — |
| Raft 3-node + SQL/DDL | **Experimental** | InstallSnapshot, membership |
| Raft multi-DB | **Not supported** | само `default` |
| Follower linearizable reads | **Not supported** | best-effort след apply |
| ORC multi-thread shared LSM | **Not supported** | ARC по подразбиране |

## GA (single-node)

Crash recovery с WAL, schema/index persist, `/health` + `/metrics`, offline backup/restore.

## Raft

Виж [distributed.md](distributed.md). Staging/ops, **не** v1.2.0 HA продукт.

## Виж също

- [Deployment](deployment.md) · [Backup](backup.md) · [en limitations](../en/known-limitations.md)
