# Известни ограничения — v1.3.0

| Ниво | Значение |
|------|----------|
| **Supported (GA)** | Документирано, тествано, подходящо за prod в обхвата |
| **Experimental** | Работи в тестове/demo; не е HA SLA |
| **Not supported** | Извън обхват |

## Матрица

| Област | v1.3.0 | Experimental / по-късно |
|--------|--------|-------------------------|
| Single-node SQL + LSM | **Supported** | — |
| Schema / FTS / HNSW / graphs persist | **Supported** | — |
| Auth + JWT (когато е конфигуриран) | **Supported** | — |
| Backup / restore | **Supported** | — |
| Multi-DB (без Raft) | **Supported** | — |
| Raft 3-node (само `default` DB) | **Supported** | failover под товар, TLS, InstallSnapshot — e2e |
| Raft multi-DB | **Not supported** | само `default` |
| `CREATE`/`DROP DATABASE` репликация | **Not supported** | per node |
| Raft membership промени (join/leave) | **Not supported** | фиксиран `BARADB_RAFT_PEERS` |
| Follower linearizable reads | **Not supported** | best-effort след apply |
| Rolling upgrades | **Not supported** | рестарт на всички възли заедно — смесени v1.2/v1.3 binaries не трябва да работят в един клъстер |
| ORC multi-thread shared LSM | **Not supported** | ARC по подразбиране |

## GA (single-node)

Crash recovery с WAL, schema/index persist, `/health` + `/metrics`, offline backup/restore.

## Raft (supported)

Виж [distributed.md](distributed.md). Поддържан обхват: 3-node, DML/DDL само върху `default`, failover под товар (acked writes оцеляват; in-flight writes → грешка, retry), raft TLS, cold-node recovery чрез InstallSnapshot.

## Нови ограничения

- **Legacy REP replication (без raft)** — пътят още извежда delete от празна стойност; insert в PK-only таблица се прилага грешно по него (редът изчезва). Използвай raft.
- **Snapshot-restore ctx** — след InstallSnapshot restore HTTP endpoints със startup-captured ctx може да сервират стари данни до рестарт (`/query` е свеж per-request); съществуващите клиентски връзки виждат pre-restore състояние — reconnect след restore.
- **FK-cascade дивергенция под raft** — ефектите на `ON DELETE/UPDATE CASCADE` (и `SET NULL`) не се реплицират през raft: followers прилагат само KV промяната на родителския ред, така че каскадираните дъщерни редове остават на followers. Избягвай FK actions върху raft-реплицирани таблици или приеми периодичен snapshot resync.
- **Непотвърдени записи в snapshots** — leader прилага записите локално преди raft majority commit; snapshot, направен в този прозорец, може да включи записи, които никога не се commit-ват (фантомни редове след restore + смяна на leadership). Тесен прозорец; поправката е планирана за следващ release.
- **Блокиране на event loop при snapshot build/restore** — snapshot build/restore изпълнява блокиращ tar/gzip на event loop на възела; големи data dirs могат да забавят heartbeats и да предизвикат election по средата на трансфер.

## Виж също

- [Deployment](deployment.md) · [Backup](backup.md) · [en limitations](../en/known-limitations.md)
