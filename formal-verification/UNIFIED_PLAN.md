# БарaDB — Обединен план за подобрение (верификация + софтуер)

**Версия:** 2.0  
**Дата:** 2026-05-07  
**Контекст:** 7 TLA+ спека (11.6M състояния), 51 Nim модула (16K реда), 262 теста

---

## Принцип

Формалната верификация е безползна ако не води до подобряване на кода. Всяка  
стъпка по-долу има две страни: какво трябва да се **докаже** (TLA+) и какво  
трябва да се **поправи/добави** в Nim кода. Когато TLA+ моделът открие  
несъответствие с кода — това е **бъг в кода или в модела**. И двете се оправят.

---

## Приоритет 1 — Критични разминавания между модел и код

### 1.1. Raft: Replicate без prevLogIndex проверка

**Състояние:**  
- Nim (`raft.nim:190-197`): `handleAppendEntries` проверява `prevLogIndex` и `prevLogTerm` — ако follower няма entry на този индекс с този term, заявката се отхвърля.  
- TLA+ (`raft.tla:104-114`): `Replicate` действието НЕ проверява това. LogMatching инвариантата беше премахната защото моделът я нарушава.

**Какво да се направи:**

| # | Задача | Файл | Тип |
|---|--------|------|-----|
| 1 | Добави `prevLogIndex`/`prevLogTerm` precondition към `Replicate` | `raft.tla` | TLA+ |
| 2 | Добави `RejectAppendEntries` действие (follower отхвърля при mismatch) | `raft.tla` | TLA+ |
| 3 | Върни `LogMatching` инвариантата | `raft.tla` | TLA+ |
| 4 | Добави тест "follower rejects append with wrong prevLogTerm" | `test_all.nim` | Nim |
| 5 | Поправи `handleAppendEntries` ако тестът покаже бъг | `raft.nim` | Nim |

**Критерий за успех:** `LogMatching` минава в TLC + Nim тестът минава.

### 1.2. Replication: writeLsn не изпраща данни

**Състояние:**  
- `PLAN.md` казва: "replication: writeLsn не изпраща данни към replicas"  
- TLA+ (`replication.tla`): `WriteLsn` действието увеличава `currentLsn` и създава `pendingAcks`, но не моделира реален data transfer.  
- Nim (`replication.nim`): `writeLsn` вероятно само increment-ва LSN без да праща data.

**Какво да се направи:**

| # | Задача | Файл | Тип |
|---|--------|------|-----|
| 6 | Добави `DataPayload` променлива в TLA+ модела (кой LSN има какви данни) | `replication.tla` | TLA+ |
| 7 | Инвариант: `DataConsistency` — ако replica ack-не LSN, данните са изпратени | `replication.tla` | TLA+ |
| 8 | Имплементирай реално data изпращане в `writeLsn` | `replication.nim` | Nim |
| 9 | Добави тест "replica receives data for acked LSN" | `test_all.nim` | Nim |

**Критерий за успех:** `DataConsistency` минава + Nim тестът потвърждава data transfer.

### 1.3. Sharding: rebalance не мигрира данни

**Състояние:**  
- `PLAN.md`: "sharding: rebalance не мигрира данни"  
- TLA+ (`sharding.tla`): `Rebalance` действието само променя `shardToNodes` mapping, не мигрира записи.  
- Nim (`sharding.nim:126-137`): `rebalance()` само пренарежда `nodeIds` в shard-овете.

**Какво да се направи:**

| # | Задача | Файл | Тип |
|---|--------|------|-----|
| 10 | Добави `DataKeys` променлива — множество ключове на всеки shard | `sharding.tla` | TLA+ |
| 11 | `Rebalance` да мигрира ключове: `DataKeys' = migrate(DataKeys, shardToNodes')` | `sharding.tla` | TLA+ |
| 12 | Инвариант: `NoDataLoss` — след rebalance, всички ключове са достъпни | `sharding.tla` | TLA+ |
| 13 | Имплементирай `migrateData()` в Nim — read от стар shard, write в нов | `sharding.nim` | Nim |
| 14 | Тест "rebalance preserves all data" | `test_all.nim` | Nim |

---

## Приоритет 2 — Непокрити критични модули

### 2.1. Backup/Restore

**Състояние:** `backup.nim` (498 реда) няма тестове нито в TLA+, нито в Nim.  
Това е **единственият** голям модул без никакво покритие.

| # | Задача | Файл | Тип |
|---|--------|------|-----|
| 15 | TLA+ спек `backup.tla` — модел на backup/restore/cleanup цикъл | `backup.tla` | TLA+ |
| 16 | Инвариант: `RestoreAtomicity` — restore или succeed-ва напълно, или rollback-ва | `backup.tla` | TLA+ |
| 17 | Инвариант: `CleanupPreservesNewest` — cleanup никога не трие последния backup | `backup.tla` | TLA+ |
| 18 | Nim тест suite: backup create, verify, restore, cleanup, history | `test_all.nim` | Nim |
| 19 | Nim тест: backup + restore round-trip с проверка на съдържанието | `test_all.nim` | Nim |

**Критерий за успех:** TLC минава + 5+ Nim теста за backup.

### 2.2. Cross-Modal Consistency

**Състояние:** `crossmodal.nim` (250 реда) има тест в `test_all.nim`, но TLA+  
моделът не проверява consistency между storage engines.

| # | Задача | Файл | Тип |
|---|--------|------|-----|
| 20 | TLA+ спек `crossmodal.tla` — обект индексиран в 4-те engine-а | `crossmodal.tla` | TLA+ |
| 21 | Инвариант: `IndexConsistency` — ако обект е в 3 индекса, е и в 4-тия | `crossmodal.tla` | TLA+ |
| 22 | Инвариант: `HybridScoreMonotonic` — повече индекси → по-добър score | `crossmodal.tla` | TLA+ |
| 23 | Nim тест: insert във всички engines → hybrid search намира обекта | `test_all.nim` | Nim |

### 2.3. WAL Recovery

**Състояние:** `recovery.nim` (177 реда) има REDO/UNDO логика. TLA+ не я  
моделира. Ако recovery е грешно — **загуба на данни при crash**.

| # | Задача | Файл | Тип |
|---|--------|------|-----|
| 24 | TLA+ спек `recovery.tla` — модел на WAL replay с committed/uncommitted | `recovery.tla` | TLA+ |
| 25 | Инвариант: `CommittedSurvives` — committed записи оцеляват след crash+recovery | `recovery.tla` | TLA+ |
| 26 | Инвариант: `UncommittedRolledBack` — uncommitted записи се undo-ват | `recovery.tla` | TLA+ |
| 27 | Nim тест: write → crash (без flush) → reopen → verify recovery | `test_all.nim` | Nim |
| 28 | Nim тест: write+commit → crash → reopen → committed данни са налице | `test_all.nim` | Nim |

---

## Приоритет 3 — Liveness и по-силни свойства

### 3.1. Liveness свойства (TLA+)

Без liveness, TLA+ проверява safety (лоши неща не се случват) но не  
прогрес (добри неща се случват).

| # | Спек | Liveness свойство | Защо |
|---|------|------------------|------|
| 29 | raft.tla | `LeaderElectedEventually` | Клъстерът в крайна сметка има лидер |
| 30 | twopc.tla | `Termination` | Всички транзакции в крайна сметка commit или abort |
| 31 | gossip.tla | `DeadDetectedEventually` | Мъртъв възел в крайна сметка е открит |
| 32 | replication.tla | `LsnProgresses` | appliedLsn в крайна сметка расте |

**Изисква:** `FAIRNESS WF_vars(Next)` в `.cfg` файловете.  
**Внимание:** TLC liveness проверката е 2-5x по-бавна от safety.

### 3.2. MVCC Write Skew Detection

**Състояние:** Snapshot isolation допуска write skew — класически проблем.  
Нито TLA+ моделът, нито Nim кодът го проверяват.

| # | Задача | Файл | Тип |
|---|--------|------|-----|
| 33 | Добави `readPredicate[t]` в `mvcc.tla` | `mvcc.tla` | TLA+ |
| 34 | Инвариант: `NoWriteSkew` — два committed txn не могат да имат overlapping predicates | `mvcc.tla` | TLA+ |
| 35 | Имплементирай predicate tracking в `mvcc.nim` | `mvcc.nim` | Nim |
| 36 | Тест "write skew is detected/prevented" | `test_all.nim` | Nim |

### 3.3. 2PC Coordinator Crash/Recovery

**Състояние:** `disttxn.nim` има 2PC но без coordinator failure handling.

| # | Задача | Файл | Тип |
|---|--------|------|-----|
| 37 | Добави `CrashCoordinator(t)` и `RecoverCoordinator(t)` в `twopc.tla` | `twopc.tla` | TLA+ |
| 38 | Инвариант: `RecoveryConsistency` — решението е същото след recovery | `twopc.tla` | TLA+ |
| 39 | Добави coordinator WAL в `disttxn.nim` — записва решението преди изпращане | `disttxn.nim` | Nim |
| 40 | Тест "coordinator recovery after crash" | `test_all.nim` | Nim |

---

## Приоритет 4 — Инфраструктурни подобрения

### 4.1. CI поправка

**Проблем:** `verify` job в CI използва `container:` което не работи с `actions/checkout`.

| # | Задача | Файл |
|---|--------|------|
| 41 | Замени `container: eclipse-temurin:21-jre` с `setup-java` action | `.github/workflows/ci.yml` |
| 42 | Добави `continue-on-error: true` за TLC стъпката | `.github/workflows/ci.yml` |
| 43 | Кеширай `tla2tools.jar` с `actions/cache` | `.github/workflows/ci.yml` |

### 4.2. Symmetry Reduction

**Проблем:** TLC проверява симетрични пермутации отделно. С 3 нода има 3!=6  
еквивалентни състояния за всяко реално състояние.

| # | Задача | Файл |
|---|--------|------|
| 44 | Добави `Symmetry` sets в raft.cfg, gossip.cfg, replication.cfg | `models/*.cfg` |
| 45 | Увеличи границите: raft 5 nodes, gossip 5 nodes | `models/*.cfg` |

### 4.3. Липсващи Nim тестове

**Проблем:** 4 модула нямат dedicated тест suite.

| # | Модул | Тестове за добавяне |
|---|-------|-------------------|
| 46 | `core/logging` | JSON формат, нива, файл output |
| 47 | `core/websocket` | Frame parsing, SUBSCRIBE/UNSUBSCRIBE |
| 48 | `core/config` | Env vars, JSON файл, defaults, validation |
| 49 | `core/backup` | Вж. 2.1 по-горе |

### 4.4. Inter-module интеграция

**Проблем:** `PLAN.md` казва "няма raft→disttxn, gossip→sharding, replication→disttxn връзки".

| # | Връзка | Какво липсва | Тип |
|---|--------|-------------|-----|
| 50 | Raft → DistTxn | 2PC решенията трябва да се replic-ват през Raft | Nim |
| 51 | Gossip → Sharding | При node failure, gossip нотифицира sharding за rebalance | Nim |
| 52 | Replication → DistTxn | Distributed txn commit изисква replication ack | Nim |
| 53 | TLA+ модел на интеграцията | Raft + 2PC + Replication в един спек | TLA+ (дългосрочно) |

---

## Хронограма

| Седмица | Задачи | Резултат |
|---------|--------|---------|
| **1** | #1-5 (Raft prevLogIndex + LogMatching) | Raft модел по-точен от кода, 1 нов тест |
| **2** | #6-14 (Replication data + Sharding migration) | 2 distributed gap-а затворени, 3 нови теста |
| **3** | #15-28 (Backup, CrossModal, Recovery спекове + тестове) | 3 нови TLA+ спека, 8+ нови теста |
| **4** | #29-32 (Liveness) | 4 темпорални свойства добавени |
| **5** | #33-40 (Write skew, 2PC crash) | 2 критични safety gap-а затворени |
| **6** | #41-53 (CI, Symmetry, тестове, интеграция) | Инфраструктурата стабилна |

---

## Метрики за успех

| Метрика | Сега | След плана |
|---------|------|-----------|
| TLA+ спекове | 7 | 10 (+backup, crossmodal, recovery) |
| TLA+ инварианти | 26 | 42 |
| TLA+ темпорални свойства | 1 | 5 |
| Проверени състояния | 11.6M | 50M+ (със symmetry) |
| Nim тестове | 262 | 285+ |
| Покрити модули (test) | 47/51 | 51/51 |
| Distributed gaps (PLAN.md) | 4 | 0 |
| Inter-module връзки | 0 | 3 |
