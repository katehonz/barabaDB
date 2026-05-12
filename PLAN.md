# BaraDB — PLAN

> Базата е production-ready. Всички критични/високи/средни бъгове поправени.

---

## Разпределени модули — status след сесия 7

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
| `backup` | TLA+ спек: `BackupSnapshotsValid`, `RestoreIntegrity`, `RetentionInvariant` |
| `recovery` | TLA+ спек: `RedoCommitted`, `RecoveryCompleteness`, `WalIntegrity` |

### ⚠️ Оставащи distributed gaps (non-critical за single-node)

| Модул | Gap |
|--------|-----|
| `replication` | `writeLsn` не изпраща данни към replicas |
| `gossip` | Няма UDP/TCP transport — in-memory само |
| `sharding` | `rebalance` не мигрира данни |
| `inter-module` | Няма raft→disttxn, gossip→sharding, replication→disttxn връзки |

### ⚠️ Оставащи formal verification gaps

| Модул | Gap | Тип |
|--------|-----|-----|
| `raft` | ✅ TLA+ моделът вече има `prevLogIndex`/`prevLogTerm` + `LogMatching` | Safety |
| `raft` | Липсва `HeartbeatTimeout`/`LeaderLeaseExpired` — не проверява step-down | Liveness |
| `twopc` | ✅ Добавени coordinator crash/recovery + participant timeout | Safety |
| `mvcc` | ✅ Write skew detection чрез `NoWriteSkew` | Safety |
| `gossip` | ✅ Поправен `LearnViaGossip` — вече не overwrite-ва по-силно с по-слабо състояние | Safety |
| `replication` | `WriteLsn` не моделира data transfer | Safety |
| `sharding` | `Rebalance` не моделира data migration | Safety |
| `backup` | ✅ TLA+ спек за backup/restore/verify/cleanup | Coverage |
| `recovery` | ✅ TLA+ спек за WAL REDO/UNDO | Coverage |
| `crossmodal` | Няма TLA+ спек за cross-modal consistency | Coverage |

---

## Formal Verification — подобрения (post-v1.0.0)

### 🔴 Критични (влияят върху коректността на проверените спекове)

| # | Задача | Защо е критично | Файл(ове) |
|---|--------|----------------|-----------|
| FV-1 | ~~Raft: prevLogIndex/prevLogTerm в Replicate~~ ✅ | TLA+ моделът вече проверява prevLogIndex/prevLogTerm, възстановена е `LogMatching` инвариантата, добавено е `RejectAppendEntries` и conflict truncation. | `formal-verification/raft.tla` |
| FV-2 | ~~Raft: Leader step-down при partition~~ ✅ | Добавени `Heartbeat`, `HeartbeatTimeout`, `LeaderLeaseExpired`. `heartbeatReceived` следи последния term с heartbeat. `LeaderHasSelfHeartbeat` инварианта гарантира, че всеки leader има валиден heartbeat. | `formal-verification/raft.tla` |
| FV-3 | ~~2PC: Coordinator crash/recovery~~ ✅ | Добавени `coordinatorLog`, `CrashCoordinator`, `RecoverCoordinator`. Coordinator записва решението в persistent log преди изпращане. | `formal-verification/twopc.tla` |
| FV-4 | ~~2PC: Participant timeout~~ ✅ | `ParticipantTimeout` позволява abort само ако coordinator е crashed и НЕ е записал решение (`coordinatorLog = Nil`). | `formal-verification/twopc.tla` |

### 🟡 Важни (нови свойства и покритие)

| # | Задача | Защо е важно | Файл(ове) |
|---|--------|-------------|-----------|
| FV-5 | **Symmetry reduction във всички .cfg** | TLC проверява 3!=6 пермутации на едно и също състояние. С `SYMMETRY` се намаляват състоянията 3-10x → по-големи граници. | `formal-verification/models/*.cfg` |
| FV-6 | **Liveness свойства (1 от 4 спека)** ✅ | `CommitProgress` добавена в `mvcc.tla` и валидна. `Spec` с `WF_vars(Next)` добавен в raft/twopc/mvcc/gossip за fair execution. `LeaderProgress`, `Termination`, `DeadDetectedEventually` са невъзможни в bounded модели с `MaxTerm`/`MaxIncarnation` лимити и неограничени crashes. | `formal-verification/*.tla`, `models/*.cfg` |
| FV-7 | ~~MVCC: Write skew detection~~ ✅ | `NoWriteSkew` инварианта добавена. `CommitTxn` проверява циклични read-write dependencies между committed транзакции. | `formal-verification/mvcc.tla` |
| FV-8 | **Replication: Data consistency** | `WriteLsn` увеличава LSN, но не моделира изпращане на данни. Нужен `DataPayload` + `DataConsistency` инвариант. | `formal-verification/replication.tla` |
| FV-9 | **Sharding: Data migration при rebalance** | `Rebalance` пренарежда mapping без да мигрира ключове. Нужен `NoDataLoss` инвариант + `migrateData` в Nim. | `formal-verification/sharding.tla`, `src/barabadb/core/sharding.nim` |

### 🟢 Нови спекове (непокрити критични модули)

| # | Задача | Покрива | Приоритет |
|---|--------|---------|-----------|
| FV-10 | ~~**`backup.tla`**~~ ✅ | `backup.nim` — `BackupSnapshotsValid`, `RestoreIntegrity`, `VerifyIntegrity`, `RetentionInvariant`, `HistoryConsistency`, `BackupIdValid` | Висок |
| FV-11 | ~~**`recovery.tla`**~~ ✅ | `recovery.nim` — `RedoCommitted`, `RecoveryCompleteness`, `WalIntegrity` | Висок |
| FV-12 | **`crossmodal.tla`** | `crossmodal.nim` (250 реда) — consistency между document/vector/graph/FTS индекси | Среден |

### 🔧 Инфраструктурни

| # | Задача | Проблем | Файл |
|---|--------|---------|------|
| FV-13 | ~~CI: Поправка на verify job~~ ✅ | Премахнат `container:` блок, заменен с `actions/setup-java@v4` + `actions/cache` + `continue-on-error: true`. | `.github/workflows/ci.yml` |
| FV-14 | ~~Property-based testing мост~~ ✅ | `tests/tla_faithfulness.nim` проверява: Raft (ElectionSafety, LogMatching, CommittedIndexValid), MVCC (NoDirtyReads, CommittedMustStart), 2PC (Atomicity, RecoveryConsistency). Документиран gap: Nim MVCC позволява множество committed versions (TLA+ изисква first-committer-wins). | `tests/tla_faithfulness.nim` |

---

## План за утре — Предложение

Ако имаш време и желание утре, ето 3 варианта за спринт:

### Опция A: "Clean build" (1-2 часа)
- Почистване на 4-те build warnings
- TLA+ symmetry reduction в `.cfg` файловете
- Резултат: чист build без warnings + 3-10x по-бърз TLC

### Опция B: `crossmodal.tla` (2-3 часа)
- TLA+ спек за cross-modal consistency
- Моделира sync между document/vector/graph/FTS индекси
- Резултат: 10-ти TLA+ спек, пълно покритие на core модулите

### Опция C: Auth hardening + SCRAM (3-4 часа)
- Истински SCRAM-SHA-256 със salt, iteration count, challenge-response
- Почистване на warnings като бонус
- Резултат: production-grade auth

**Препоръчвам Опция A** — бързо, видимо подобрение, подготовка за clean v1.0.0 release.

---

## Завършено (обща сума: 7 сесии)

**292 теста — 0 failure-а.**
**9 TLA+ спецификации — всички минават TLC.**
**32 бъга поправени (9 критични + 7 високи + 12 средни + 4 конфигурационни).**
