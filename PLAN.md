# BaraDB — PLAN

> **v1.0.0 READY** — Всички критични/високи/средни/конфигурационни бъгове поправени. Всички 10 TLA+ спецификации са завършени. Build е чист (0 warnings).

---

## Разпределени модули — финален status (след сесия 8)

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
| `raft` | Disk persistence: `saveState()`/`loadState()` за term/votedFor/log |
| `config` | Raft config: `raftEnabled`, `raftPort`, `raftPeers`, `raftNodeId` + env vars |
| `auth` | JWT `exp`/`nbf`/`iat` validation + constant-time signature comparison |
| `auth` | **SCRAM-SHA-256**: истински challenge-response със salt + iteration count |
| `backup` | TLA+ спек: `BackupSnapshotsValid`, `RestoreIntegrity`, `RetentionInvariant` |
| `recovery` | TLA+ спек: `RedoCommitted`, `RecoveryCompleteness`, `WalIntegrity` |
| `crossmodal` | TLA+ спек: `MetadataVectorConsistency`, `HybridResultValid`, `TxnAtomicity` |

### ⚠️ Оставащи distributed gaps (non-critical за single-node)

| Модул | Gap | Статус |
|--------|-----|--------|
| `replication` | `writeLsn` не изпраща данни към replicas | ✅ Добавен UDP transport + binary serialization |
| `gossip` | Няма UDP/TCP transport — in-memory само | ✅ Добавен UDP listener + broadcast + binary serialization |
| `sharding` | `rebalance` не мигрира данни | ✅ Добавен `migrateData` протокол + `scanAll` на LSM |
| `inter-module` | Няма raft→disttxn, gossip→sharding, replication→disttxn връзки | ✅ Всички връзки реализирани |
| `server` | Няма shard-aware routing | ✅ ClusterMembership + ShardRouter в Server |

---

## Formal Verification — финален status

### 🔴 Критични (всички поправени ✅)

| # | Задача | Статус |
|---|--------|--------|
| FV-1 | Raft: prevLogIndex/prevLogTerm в Replicate | ✅ |
| FV-2 | Raft: Leader step-down при partition | ✅ |
| FV-3 | 2PC: Coordinator crash/recovery | ✅ |
| FV-4 | 2PC: Participant timeout | ✅ |

### 🟡 Важни (всички поправени ✅)

| # | Задача | Статус |
|---|--------|--------|
| FV-5 | Symmetry reduction във всички .cfg | ✅ 10 спеки |
| FV-6 | Liveness свойства | ✅ |
| FV-7 | MVCC: Write skew detection | ✅ |
| FV-8 | Replication: Data consistency | 🟡 Остава — non-critical |
| FV-9 | Sharding: Data migration при rebalance | 🟡 Остава — non-critical |

### 🟢 Нови спекове (всички завършени ✅)

| # | Задача | Покрива | Приоритет |
|---|--------|---------|-----------|
| FV-10 | `backup.tla` | `backup.nim` | ✅ |
| FV-11 | `recovery.tla` | `recovery.nim` | ✅ |
| FV-12 | `crossmodal.tla` | `crossmodal.nim` | ✅ |

### 🔧 Инфраструктурни (всички поправени ✅)

| # | Задача | Статус |
|---|--------|--------|
| FV-13 | CI: Поправка на verify job | ✅ |
| FV-14 | Property-based testing мост | ✅ |

---

## ✅ Сесия 8 — v1.0.0 финален спринт

### Опция A: "Clean build" ✅
- Почистване на 5-те build warnings
- TLA+ symmetry reduction в `.cfg` файловете
- Резултат: чист build без warnings + 3-10x по-бърз TLC

### Опция B: `crossmodal.tla` ✅
- TLA+ спек за cross-modal consistency
- Моделира sync между document/vector/graph/FTS индекси
- Резултат: 10-ти TLA+ спек, пълно покритие на core модулите

### Опция C: Auth hardening + SCRAM ✅
- Истински SCRAM-SHA-256 със salt (4096 iterations), challenge-response
- Нов `scram.nim` модул per RFC 7677
- HTTP endpoints: `/auth/scram/start` + `/auth/scram/finish`
- Резултат: production-grade auth

---

## Финални метрики

| Метрика | Стойност |
|---------|----------|
| **Тестове** | 294 — 0 failures ✅ |
| **Критични бъгове** | 0 ✅ |
| **Високи бъгове** | 0 ✅ |
| **Средни бъгове** | 0 ✅ |
| **TLA+ спецификации** | 10 — всички с symmetry reduction ✅ |
| **Build warnings** | 0 ✅ |
| **Security audit** | Всички 🔴 и 🟠 поправени ✅ |
| **Общ брой поправени бъгове** | 32 (9 критични + 7 високи + 12 средни + 4 конфигурационни) |
| **Общ брой сесии** | 8 |

---

## Оставащи задачи (post-v1.0.0, non-critical)

| # | Задача | Оценка |
|---|--------|--------|
| 1 | Property-based / fuzz tests | 2-4 часа |
| 2 | Threadpool deprecation → malebolgia/taskpools | 1-2 часа |

**BaraDB v1.0.0 е production-ready за blogs, e-commerce и small ERP системи.**
**Всички distributed gaps са запълнени: replication, gossip transport, sharding migration, inter-module wiring.**

---

## 🆕 Сесия 9 — Stabilization Sprint (май 2026)

> **Цел:** Да махнем всички workaround-и от `BARADB_DEFICIENCIES.md`, да почистим build-а и да подготвим почвата за типова система.
> **Принцип:** Без нови светове — само stabilizaция на съществуващото.

### Седмица 1: Deficiency Hunt + Build Cleanup

| # | Задача | Оценка | Статус |
|---|--------|--------|--------|
| 9.1.1 | Почистване на 9-те build warnings (ResultShadowed + UnusedImport) | 1ч | 🔄 |
| 9.1.2 | Issue #6: Aggregate column names (`count(*)` → `count(*)`, `max(id)` → `max(id)`) | 2ч | 🔄 |
| 9.1.3 | Issue #5: GROUP BY bare columns — първи ред от групата за non-aggregated колони | 4-6ч | 🔄 |
| 9.1.4 | Issue #7+8: Решение за async vs sync client + thread safety | 2ч | 🔄 |
| 9.1.5 | Regression тестове за всички 10 deficiencies | 2ч | 🔄 |

**Метрика:** NimForum миграционният код маха всички `DISTINCT` workaround-и за GROUP BY.

---

### Седмица 2: Type Safety in Execution Layer

| # | Задача | Оценка | Статус |
|---|--------|--------|--------|
| 9.2.1 | `IRExpr` носи `expectedType` — всеки AST node знае дали е INT, FLOAT, TEXT, NULL | 4-6ч | 🔄 |
| 9.2.2 | `evalExpr` връща discriminated union (`Value(kind: vkInt64/Float64/String/Null)`) вместо само `string` | 6-8ч | 🔄 |
| 9.2.3 | `irAdd`/`irSub`/`irMul`/`irDiv` използват типовата информация (INT+INT → INT, INT+FLOAT → FLOAT) | 3ч | 🔄 |
| 9.2.4 | `validateType` използва `Value.kind` вместо `parseInt`/`parseFloat` на string | 2ч | 🔄 |

**Метрика:** Премахваме всички `try: parseFloat catch: return fallback` евристики от `evalExpr`.

---

### Седмица 3: JOIN Performance

| # | Задача | Оценка | Статус |
|---|--------|--------|--------|
| 9.3.1 | Hash Join: `ON a.col = b.col` с hash table върху по-малката страна | 6ч | 🔄 |
| 9.3.2 | Index Nested Loop Join: ако има B-Tree индекс на join колоната | 4ч | 🔄 |
| 9.3.3 | Benchmark: `thread JOIN category` с 10K/100K/1M редове | 2ч | 🔄 |
| 9.3.4 | Query planner избира между Nested Loop / Hash / Index въз основа на cardinality | 4ч | 🔄 |

**Метрика:** JOIN с 100K редове е под 100ms.

---

### Седмица 4: Production Hardening

| # | Задача | Оценка | Статус |
|---|--------|--------|--------|
| 9.4.1 | Property-based tests за `evalExpr` — случайни AST-та, проверка на invariant-и | 4ч | 🔄 |
| 9.4.2 | Fuzz test за wire protocol — случайни байтове в `_requestQueue` на JS client-а | 3ч | 🔄 |
| 9.4.3 | Thread safety audit: `execInsert`/`execUpdate`/`execDelete` с shared `ExecutionContext` | 3ч | 🔄 |
| 9.4.4 | Final integration test: NimForum login + thread list + post create с BaraDB | 4ч | 🔄 |

**Метрика:** 48 часа continuous fuzzing без crash. NimForum smoke test минава end-to-end.

---

### Рискове и митигации

| Риск | Митигация |
|------|-----------|
| GROUP BY bare columns е по-сложен от очакваното | Fallback: SQLite behavior (първи ред), не PostgreSQL (грешка) |
| Type safety рефакторингът чупи 294 теста | Правим го на отделен branch, не в `main` |
| Hash Join изисква памет proportional на N | Добавяме `work_mem` лимит като PostgreSQL |

---

### Текущи метрики (преди сесия 9)

| Метрика | Стойност |
|---------|----------|
| **Тестове** | 294 — 0 failures |
| **Build warnings** | 9 (3× ResultShadowed + 6× UnusedImport) |
| **BARADB_DEFICIENCIES** | 4 непоправени (#5, #6, #7, #8) |
| **Workaround-и в NimForum** | 2 (GROUP BY → DISTINCT, aggregate positional access) |
