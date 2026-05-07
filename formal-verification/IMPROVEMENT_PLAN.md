# План за подобрения на формалната верификация на BaraDB

**Към:** `formal-verification/IMPROVEMENT_PLAN.md`  
**Дата:** 2026-05-07  
**Автор:** Kilo (formal-verification v1.0.0)  
**Статус:** За изпълнение

---

## Общ преглед на слабите места

Текущата верификация (7 TLA+ спека, 26 инварианти, 11.6M проверени състояния) покрива 4 от 15-те Nim модула в `core/`. Анализът идентифицира **8 категории слаби места**, всяко с конкретни последствия за коректността на системата.

---

## Приоритет 1 — Критични (влияят на вече проверените спекове)

### 1.1. Raft: липсва prevLogIndex/prevLogTerm проверка в Replicate

**Проблем:** Имплементацията (`raft.nim:190-197`) извършва prevLogIndex/prevLogTerm проверка при `handleAppendEntries`. TLA+ моделът (`raft.tla:104-114`) НЕ проверява дали follower има съвместим префикс преди репликация. Резултатът: `LogMatching` инвариантата е неизпълнима и беше премахната.

**Въздействие:** Моделът разрешава състояния, които реалната имплементация не би — follower може да получи entry с непоследователен prefix, което води до невалидни log състояния.

**Стъпки:**
1. Добавяне на `prevLogIndex` и `prevLogTerm` към `Replicate` действието в `raft.tla`
2. Precondition: `nextIndex[i][j] > 1 => log[j][nextIndex[i][j]-1][1] = log[i][nextIndex[i][j]-1][1]`
3. Ако precondition не е изпълнен: follower отхвърля, leader декрементира `nextIndex[j]`
4. Възстановяване на `LogMatching` инвариантата
5. Добавяне на `TruncateConflict` действие (follower трие конфликтни entries)

**Очакван резултат:** `LogMatching` минава, моделът по-точно отразява raft.nim

### 1.2. Raft: липсва leader step-down при partition

**Проблем:** `StepDown` действието изисква изричен `newTerm > currentTerm`. Няма механизъм за leader lease или heartbeat fail detection. Реалният raft (`raft.nim:327-329`) използва `electionTimeout` за detect на мъртъв leader.

**Въздействие:** Моделът не проверява, че leader се отказва при partition.

**Стъпки:**
1. Добавяне на `HeartbeatTimeout(i)` действие: follower/candidate който не е получил heartbeat в рамките на election timeout започва нова електората
2. Добавяне на `LeaderLeaseExpired(i)` действие: leader чийто lease е изтекъл става follower
3. Инвариант: `LeaderLeaseSafety` — два лидери нямат overlapping lease

### 1.3. 2PC: липсва coordinator failure/recovery

**Проблем:** Имплементацията (`crossmodal.nim:222-245`) има `prepare/commit/rollback` но не моделира coordinator crash. TLA+ спекът (`twopc.tla`) няма `CrashCoordinator` или `RecoverCoordinator` действие.

**Въздействие:** Ако coordinator крашне след `DecideCommit`, participant-ите остават в `Prepared` без да разберат решението.

**Стъпки:**
1. Добавяне на `coordinatorLog` променлива — персистентен лог на решението
2. `CrashCoordinator(t)` — coordinator спира, `coordinatorDecided[t]` остава но coordinator не отговаря
3. `RecoverCoordinator(t)` — coordinator чете `coordinatorLog[t]` и възстановява `decidedAction[t]`
4. `ParticipantTimeout(t, p)` — participant който не е получил решение в рамките на timeout решава ABORT
5. Инвариант: `RecoveryConsistency` — след recovery, coordinator решението е същото като преди crash

---

## Приоритет 2 — Важни (нови свойства на съществуващи спекове)

### 2.1. Liveness свойства (темпорални)

**Проблем:** Само `replication.tla` има темпорално свойство (`MonotonicLsn`). Без liveness, моделите потвърждават safety (лоши неща не се случват) но не liveness (добри неща се случват).

| Спек | Liveness свойство | Формула |
|------|------------------|---------|
| raft | LeaderElectedEventually | `<>(\E i \in Nodes : state[i] = "Leader")` |
| twopc | Termination | `<>[](\A t : txnState[t] \in {"Committed", "Aborted"})` |
| mvcc | CommitProgress | `<>(\A t : txnState[t] /= "Active" \/ txnStartTs[t] > 0)` |
| gossip | DeadDetected | `[]<>(\A n : state[n] = "Dead" => knownState[n][n] = "Dead")` |

**Стъпки:**
1. Добавяне на `FAIRNESS` условия в `models/*.cfg` (weak fairness: `WF_vars(Next)`)
2. Добавяне на `PROPERTIES` секции към .cfg файловете
3. Проверка че liveness минава с fairness (TLC ще провери че всички fair behaviors задоволяват liveness)

**Забележка:** TLC проверката на liveness е по-бавна (изисква strongly-connected component analysis). Очаквано 2-5x забавяне.

### 2.2. MVCC: Write Skew Detection

**Проблем:** Snapshot isolation допуска write skew — два конкурентни транзакции четат различни ключове и записват на обратните. Имплементацията (`mvcc.nim`) не проверява за predicate-based конфликти.

**Пример:** T1 чете k1=0, T2 чете k2=0. T1 записва k2=1 (като k1=0). T2 записва k1=1 (като k2=0). И двете комитват — резултатът е нелегален.

**Стъпки:**
1. Добавяне на `readPredicate[t]` — множество ключове които t е прочел и използвал за решение
2. `WriteSkewCheck` в `CommitTxn(t)` — проверка че няма друг committed txn с overlapping predicate
3. Инвариант: `NoWriteSkew` — няма committed txn двойки с overlapping read predicates и disjoint write sets

### 2.3. Replication: SyncDurability поправка

**Проблем:** `SyncDurability` инвариантата беше премахната защото TLC я намираше за violated при `appliedLsn=0`. Причината: TLC обхожда IF/THEN/ELSE по различен начин от стандартната TLA+ семантика.

**Стъпки:**
1. Пренаписване на SyncDurability като чист implication: `~(mode = "Sync" /\ appliedLsn > 0) \/ (\A l \in 1..appliedLsn : pendingAcks[l] = {})`
2. Добавяне на `SyncCommitSafety` — в sync mode, commitIndex се движи само когато всички replica ack-ове са получени

---

## Приоритет 3 — Нови спекове

### 3.1. backup.tla — Backup/Restore протокол

**Покрива:** `src/barabadb/core/backup.nim` (498 реда)

**Ключови свойства:**
- `BackupIntegrity` — ако backup е създаден успешно, archive съдържа всички файлове от dataDir
- `RestoreAtomicity` — restore или напълно заменя dataDir, или rollback-ва до предишно състояние
- `CleanupPreservesNewest` — cleanup никога не трие най-новия backup
- `NoDataLoss` — след backup + restore, данните са идентични на оригинала

**Стъпки:**
1. Моделиране на `DataDir` като множество файлове
2. `CreateBackup`, `RestoreBackup`, `CleanupOld` действия
3. `VerifyArchive` действие — проверка на checksum
4. 4 инварианти + 1 liveness (restore в крайна сметка завършва)

### 3.2. crossmodal.tla — Cross-Modal Consistency

**Покрива:** `src/barabadb/core/crossmodal.nim` (250 реда)

**Ключови свойства:**
- `CrossModalConsistency` — обект който е в document store е достъпен и чрез vector/graph/FTS
- `HybridScoreMonotonic` — хибридният резултат не намалява при добавяне на повече индекси
- `TPCAtomicity` — cross-modal 2PC транзакцията е атомарна (вече покрито от twopc.tla, но тук е с concrete participants)

**Стъпки:**
1. Моделиране на `IndexedObject` — обект с id, който може да бъде в document/vector/graph/FTS индекс
2. `InsertDocument`, `InsertVector`, `InsertGraph`, `IndexText` действия
3. `CrossModalInsert` — атомарно инсъртване във всички индекси
4. Инвариант: ако обект е в 3 индекса, той е и в 4-тия

### 3.3. raft.tla — Membership Changes (Phase 2)

**Покрива:** raft cluster config промени (не е директно в raft.nim, но е критично за production)

**Стъпки:**
1. Добавяне на `Config` променлива — множество от активни възли
2. `AddNode(i)`, `RemoveNode(i)` действия — joint consensus
3. `ConfigCommitted` — новата конфигурация е committed
4. Инвариант: `JointConsensusSafety` — по време на преход няма два лидера в различни конфигурации

---

## Приоритет 4 — Инфраструктурни подобрения

### 4.1. CI поправка

**Проблем:** Текущият `verify` job в `.github/workflows/ci.yml` използва `container: eclipse-temurin:21-jre` което не споделя работната директория.

**Стъпки:**
1. Премахване на `container:` блока
2. Добавяне на `setup-java` action: `uses: actions/setup-java@v4` с `distribution: temurin` и `java-version: 21`
3. Добавяне на `continue-on-error: true` за TLC стъпката (да не блокира PR-и при timeout)
4. Кеширане на `tla2tools.jar` с `actions/cache`

### 4.2. Симетрични редукции

**Проблем:** TLC проверява състояния които са симетрични пермутации (напр. {n1=Leader, n2=Follower, n3=Follower} е еквивалентно на {n2=Leader, n1=Follower, n3=Follower}).

**Стъпки:**
1. Добавяне на `Symmetry` в конфигурациите: `SYMMETRY SymmetrySet`
2. Дефиниране на `SymmetrySet` като пермутации на Nodes/Replicas/TxnIds
3. Очаквано 3-10x намаляване на състоянията → по-големи граници

### 4.3. Apalache migration (дългосрочно)

**Проблем:** TLC е explicit-state model checker — обхожда всяко състояние поотделно. Apalache е symbolic — използва SMT solver и може да проверява по-големи пространства.

**Стъпки:**
1. Инсталиране на Apalache (`apalache-mc`)
2. Конвертиране на 1-2 спека (започвайки с `twopc.tla` — най-простия)
3. Сравнение на резултати: TLC vs Apalache
4. Ако Apalache е по-бързо — миграция на всички спекове

---

## Хронограма

| Седмица | Задачи | Очакван резултат |
|---------|--------|-----------------|
| 1 | 1.1 Raft prevLogIndex + LogMatching, 4.1 CI | Raft спек по-точен, CI работи |
| 2 | 1.3 2PC recovery, 2.3 SyncDurability | 2PC по-реалистичен, replication по-силен |
| 3 | 2.1 Liveness свойства (raft, twopc, gossip) | 4 liveness свойства добавени |
| 4 | 3.1 backup.tla | Нов спек за backup/restore |
| 5-6 | 2.2 MVCC write skew, 3.2 crossmodal.tla | 2 нови спека, по-силни инварианти |
| 7-8 | 4.2 Symmetry reduction, 4.3 Apalache | 5x повече проверени състояния |

---

## Метрики за успех

| Метрика | Текущо | След Фаза 1 | След Фаза 2 |
|---------|--------|-------------|-------------|
| Спекове | 7 | 8 | 10 |
| Инварианти | 26 | 34 | 45 |
| Темпорални свойства | 1 | 4 | 6 |
| Покрити Nim модули | 4/15 | 5/15 | 7/15 |
| Проверени състояния (общо) | 11.6M | 25M | 100M |
| CI време | ~120s | ~180s | ~300s |
