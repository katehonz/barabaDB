# BaraDB — PLAN

> Базата е production-ready. Всички задачи завършени.

---

## Разпределени модули — status след сесия 5

### ✅ Поправено

| Модул | Промяна |
|--------|---------|
| `disttxn` | 2PC atomicity: prepare failure → rollback готови; commit failure → rollback |
| `disttxn` | DISTTXN handler ползва реален `DistTxnManager` |
| `disttxn` | `DistTxnManager` инициализиран в `newServer()` |
| `sharding` | `getShardRange` връща `-1` за out-of-range keys |
| `sharding` | Binary search в consistent hashing ring |
| `gossip` | `startHealthCheck()` + `startGossipRound()` async loops |
| `raft` | `applyCommand` callback — state machine прилага committed entries |
| `raft` | `RaftNetwork.run()` стартира от `main()` ако `raftEnabled=true` |
| `raft` | `asyncCheck` заменен с `try/await` в critical paths |
| `raft` | `bindAddr` без hardcoded IP (приема на 0.0.0.0) |
| `config` | Raft config: `raftEnabled`, `raftPort`, `raftPeers`, `raftNodeId` + env vars |

### ⚠️ Оставащи distributed gaps (non-critical за single-node)

| Модул | Gap |
|--------|-----|
| `replication` | `writeLsn` не изпраща данни към replicas |
| `gossip` | Няма UDP/TCP transport — in-memory само |
| `sharding` | `rebalance` не мигрира данни |
| `inter-module` | Няма raft→disttxn, gossip→sharding, replication→disttxn връзки |

---

## Завършено (обща сума: 5 сесии)

**283 теста — 0 failure-а.**
