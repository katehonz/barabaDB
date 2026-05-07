# BaraDB Formal Verification — Analysis & Improvement Plan

**Version:** 1.0.0  
**Date:** 2026-05-07  
**Status:** 7 specs, 11.6M states checked, 0 errors

---

## 1. Текущо състояние

| Спек | Покрит компонент | Инварианти | Състояния |
|------|-----------------|-----------|-----------|
| raft.tla | Raft Consensus | 4 | 475,972 |
| twopc.tla | Two-Phase Commit | 5 | 2,125,825 |
| mvcc.tla | MVCC / Snapshot Isolation | 5 | 177,849 |
| replication.tla | Async/Sync/Semi-sync Replication | 4 + 1 темпорално | 3,687,939 |
| gossip.tla | SWIM Gossip Protocol | 3 | 1,257,121 |
| deadlock.tla | Deadlock Detection | 2 | 3,767,361 |
| sharding.tla | Consistent Hashing | 3 | 186,305 |

---

## 2. Идентифицирани слаби места

### 2.1. Малки граници на моделите (Model Bounds)

Поради комбинаторния взрив на състоянията, всички проверки се извършват с изкуствено ограничени параметри:

| Спек | Текущи граници | Проблем |
|------|---------------|---------|
| raft | 3 nodes, MaxTerm=3, MaxLogLen=3 | Реални клъстери имат 5-7 възела и стотици записи |
| twopc | 3 participants, MaxTxnId=3 | Не покрива конкурентни транзакции |
| mvcc | 2 keys, 2 values, MaxTxnId=2 | Не валидира snapshot isolation за повече ключове |
| replication | 3 replicas, MaxLsn=3 | Не покрива реален replication log |
| gossip | 3 nodes, MaxIncarnation=3 | Не покрива сложни мрежови partition сценарии |
| deadlock | 5 txns, MaxEdges=8 | Циклите с повече транзакции не са проверени |
| sharding | 3 shards, 2 nodes, 5 vnodes | Реалният consistent hash ring има 100+ vnodes |

**Препоръка:** Добавяне на симетрични редукции (symmetry reduction) в конфигурациите и/или използване на TLC с `-fp` и `-dfid` параметри за по-голяма памет. Алтернативно — Apalache model checker за symbolic model checking.

### 2.2. Липса на liveness свойства

Само `replication.tla` има темпорално свойство (`MonotonicLsn`). Липсват:

| Спек | Липсващо liveness свойство | Защо е важно |
|------|--------------------------|-------------|
| raft | LeaderCompleteness, LeaderElectedEventually | Гарантира, че системата прогресира |
| twopc | Termination (всички транзакции терминират) | Без него 2PC може да виси безкрайно |
| mvcc | CommitLiveness (транзакция в крайна сметка комитва или абортва) | Предотвратява безкрайно активни транзакции |
| gossip | DeadNodeDetectedEventually | Fail detection изисква liveness |
| deadlock | DeadlockResolvedEventually | Victim selection без резолюция е безполезно |
| sharding | RebalanceEventuallyStable | Без него rebalance може да е безкраен |

**Препоръка:** Добавяне на `PROPERTIES` секции с `WF_vars`/`SF_vars` (weak/strong fairness) за всеки спек.

### 2.3. Липсващи компоненти без формална верификация

Следните Nim модули нямат TLA+ покритие:

| Модул (src/barabadb/core/) | Риск | Приоритет |
|---------------------------|------|-----------|
| backup.nim | Загуба на данни при неправилно backup/restore | Висок |
| columnar.nim | Неправилна агрегация на колонни данни | Среден |
| crossmodal.nim | Несъгласуваност между модалности (doc+graph+vector) | Висок |
| httpserver.nim | Race conditions в HTTP рутинг | Среден |
| websocket.nim | Message ordering, reconnection safety | Среден |
| types.nim | Type invariants (проверени имплицитно през TypeOk) | Нисък |

**Препоръка:** Приоритизиране на backup.tla и crossmodal.tla като следващи спекове.

### 2.4. Raft моделът е прекалено опростен

Спрямо реалната имплементация (`raft.nim`, 564 реда), моделът пропуска:

- **PrevLogIndex/PrevLogTerm проверка** — Replicate действието не валидира, че follower има съвместим префикс. Това прави `LogMatching` инварианта неизпълним (затова беше премахнат).
- **Log truncation/compaction** — Няма snapshot механизъм.
- **Membership changes** — Няма добавяне/премахване на възли.
- **Leader step-down при partition** — Няма leader lease или heartbeat fail.

**Препоръка:** Разширяване на Replicate с `prevLogIndex` и `prevLogTerm` параметри, добавяне на `InstallSnapshot` действие, и връщане на `LogMatching` инварианта.

### 2.5. 2PC без recovery модел

Спекът не моделира:

- Coordinator crash и recovery (read decision from WAL)
- Participant timeout (какво става ако participant не отговори)
- Heuristic decisions (участник взима самостоятелно решение при coordinator failure)
- Transaction log replay

**Препоръка:** Добавяне на `CrashCoordinator(t)` и `RecoverCoordinator(t)` действия с четене на `decidedAction[t]` от персистентен лог.

### 2.6. MVCC без garbage collection

Моделът не включва:

- Version cleanup (стари версии се трият при compaction)
- Long-running transaction handling (транзакции със стар snapshot)
- Write skew detection (класически проблем на snapshot isolation)

**Препоръка:** Добавяне на `CleanupOldVersions` действие и `NoWriteSkew` инвариант (изисква tracking на predicate-based read/write конфликти).

### 2.7. Няма интеграция с Nim тестовете

Формалната верификация е напълно отделена от кодовите тестове:

- Няма генериране на TLA+ от Nim код (code-to-spec pipeline)
- Няма автоматична проверка, че TLA+ моделът съответства на имплементацията
- Няма fuzzing на имплементацията със сценарии от TLC counterexamples

**Препоръка:** Скрипт за сравнение на TLA+ state machine с Nim state machine чрез property-based testing (например с Nim `faker`/`rapidcheck` библиотеки).

### 2.8. CI интеграцията е крехка

Текущият CI job използва `container: eclipse-temurin:21-jre` което:

- Не споделя работната директория със стъпките преди това
- Може да няма правилни permissions
- Няма кеширане на `tla2tools.jar`

**Препоръка:** Преместване на TLC проверката в основния `test` job с `setup-java` action или използване на `actions/cache` за JAR-а.

---

## 3. План за подобрения

### Фаза 1 — Краткосрочни (1-2 седмици)

1. **Поправка на CI интеграцията**
   - Преместване на TLC в основния job
   - Добавяне на `continue-on-error: true` за да не блокира PR-и

2. **Raft: prevLogIndex/prevLogTerm + LogMatching**
   - Рефакториране на Replicate действието
   - Възстановяване на LogMatching инварианта
   - Увеличаване на границите чрез symmetry reduction

3. **Добавяне на liveness свойства**
   - `raft.tla`: LeaderElectedEventually (с fairness)
   - `twopc.tla`: Termination
   - `mvcc.tla`: CommitProgress

4. **backup.tla** — Нов спек за backup/restore протокола
   - Инварианти: RestoreIntegrity (възстановените данни са точни), NoDataLoss, ChecksumConsistency

### Фаза 2 — Средносрочни (3-4 седмици)

5. **crossmodal.tla** — Нов спек за cross-modal заявки
   - Инварианти: CrossModalConsistency (резултатите от различни storage engines са съгласувани)

6. **2PC recovery модел**
   - Coordinator crash/recovery
   - Participant timeout handling
   - WAL replay correctness

7. **MVCC write skew detection**
   - Добавяне на `NoWriteSkew` инвариант
   - Моделиране на predicate-based конфликти

8. **Property-based testing мост**
   - Nim скрипт за генериране на тестови сценарии от TLC counterexamples
   - Верификация, че TLA+ моделът е faithful abstraction на Nim кода

### Фаза 3 — Дългосрочни (1-2 месеца)

9. **Apalache migration** за symbolic model checking
   - По-големи граници без state explosion
   - Индуктивни инварианти за безкрайни domain-и

10. **PlusCal пренаписване** на съществуващите спекове
    - По-лесна четимост и review
    - Автоматично генериране на TLA+ от PlusCal

11. **Performance properties**
    - Bounded latency: в рамките на K стъпки, leader се избира
    - Bounded replication lag: appliedLsn >= currentLsn - D

---

## 4. Рискове извън обхвата на формалната верификация

| Риск | Защо не е покрит |
|------|-----------------|
| Memory safety (Nim компилаторът не гарантира пълна memory safety) | TLA+ не моделира памет |
| Concurrency bugs в Nim (data races, deadlocks на ниво нишки) | TLA+ не моделира thread scheduling |
| I/O грешки (disk corruption, network partition) | Може да се моделира, но не е направено |
| Performance регресии | TLA+ не е performance tool |
| Byzantine faults | Всички модели предполагат crash-fault модел |

---

## 5. Метрики за проследяване

| Метрика | Текуща стойност | Цел (Фаза 1) | Цел (Фаза 2) |
|---------|----------------|-------------|-------------|
| Брой спекове | 7 | 8 | 9 |
| Брой инварианти (общо) | 26 | 32 | 40 |
| Брой темпорални свойства | 1 | 4 | 6 |
| Покрити Nim модули | 4/15 | 6/15 | 8/15 |
| Средни граници (nodes/txns) | 3.5 | 5 | 10 |
| CI време за верификация | ~120s | ~180s | ~300s |
