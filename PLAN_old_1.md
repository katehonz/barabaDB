# План за подобряване на BaraDB

## Цел
Превърне BaraDB от добър proof-of-concept в солиден, изпълним проект с реална дълбочина на критичните компоненти.

---

## Фаза 1: Честност и стабилна основа (1–2 седмици) ✅ ЗАВЪРШЕНА

### 1.1 Поправи `README.md` да отразява реалното състояние
- ✅ Добавена секция **"Current Status / Limitations"** с конкретни бележки:
  - LSM-Tree SSTable четене е placeholder
  - HNSW search е линейно сканиране (O(N))
  - TCP сървърът връща само "OK", без execution
  - Raft няма мрежов транспорт
  - Graph/FTS/Columnar са in-memory само
- ✅ Променена сравнителната таблица с EdgeDB — маркиран като "в разработка / експериментален"

### 1.2 Поправи компилацията на benchmark-ите
- ✅ В `benchmarks/bench_all.nim`: заменено `(getMonoTime() - start).ticks` с `(getMonoTime() - start).inNanoseconds`
- ✅ Добавен `import std/times`
- ✅ Benchmark-ът се компилира и изпълнява успешно

### 1.3 Имплементирай реално SSTable четене в `storage/lsm.nim`
**Беше:** `db.get()` намираше ключа в `sst.index`, но връщаше `(true, @[])` — празен масив.

**Сега:**
- ✅ Дефиниран бинарен SSTable формат (Header → Data Block → Index Block → Bloom Filter Block)
- ✅ Имплементиран `writeSSTable()` — сериализира MemTable към `.sst` файл
- ✅ Имплементиран `loadSSTable()` — зарежда съществуващ `.sst` файл чрез `mmap`
- ✅ Имплементиран `readSSTableEntry()` — чете конкретен ключ от mmap-нат файл
- ✅ `flush()` вече наистина пише SSTable файл
- ✅ `newLSMTree()` вече зарежда съществуващи SSTables при стартиране
- ✅ Добавени `serialize`/`deserialize` на `BloomFilter` за персистентност
- ✅ Поправен `mmap.nim` да използва `posix.open` вместо грешния `system.open`
- ✅ Всички 214 теста минават
- ✅ Persistence тест: write → flush → close → reopen → read работи коректно

---

## Фаза 2: Дълбочина на core engine-ите (2–4 седмици)

### 2.1 Реализирай истински HNSW search в `vector/engine.nim` ✅ ЗАВЪРШЕНА
**Беше:** `search()` правеше линейно сканиране на всички нодове.

**Резултат:**
- ✅ Имплементиран `randomLevel()` с геометрично разпределение
- ✅ Имплементиран `searchLayer()` — жадно разширяване на кандидати с `ef` лъч
- ✅ Имплементиран `selectNeighbors()` + `addBidirectionalLink()` с degree pruning
- ✅ `insert()` изгражда йерархичен граф ниво по ниво
- ✅ `search()` слиза от `maxLevel` до 0, рефинирайки entry point
- ✅ `searchWithFilter()` с пост-филтриране на метаданни
- ✅ Тестовете за HNSW (insert/search/filter) минават; benchmark-ът с 10K вектора работи

### 2.2 Интегрирай wire protocol в TCP сървъра ✅ ЗАВЪРШЕНА
**Беше:** `core/server.nim` връщаше `"OK\n"` за всяка заявка.

**Резултат:**
- ✅ Сървърът чете 12-byte бинарен header (`kind`, `length`, `requestId`) и payload
- ✅ Имплементиран `recvExact` за надеждно message framing
- ✅ SELECT: point read (WHERE key = '...') и full memTable scan
- ✅ INSERT: парсва EdgeDB-style синтаксис и записва в LSM-Tree
- ✅ DELETE: извлича ключ от WHERE и извиква `db.delete()`
- ✅ Отговори чрез `mkData`, `mkComplete`, `mkError`, `mkPong`
- ✅ Добавен `scanMemTable()` в LSM-Tree за пълни сканирания
- ✅ Всички тестове минават (214+)

### 2.3 Добави персистентност на поне един от Graph/FTS/Columnar ✅ ЗАВЪРШЕНА
**Изпълнено за Graph engine.**

**Резултат:**
- ✅ Дефиниран бинарен формат с magic bytes (`BGRF`) и version
- ✅ `saveToFile(path)` сериализира nodes, edges, properties, weights, next IDs
- ✅ `loadFromFile(path)` реконструира графа и adjacency lists от edges
- ✅ Тест "Save and load graph": 3 nodes, 2 edges, properties, shortest path — round-trip успешен
- ✅ Всички тестове минават (215+)

---

## Фаза 3: Production hardening (2–3 седмици)

### 3.1 Thread-safety и concurrency ✅ ЗАВЪРШЕНА
- ✅ LSM-Tree: конвертиран от `object` на `ref object`, добавен `std/locks.Lock`
  - Всички публични операции (`put`, `delete`, `get`, `contains`, `flush`, `close`, `scanMemTable`) са опаковани с `acquire`/`release`
  - Премахнато неизползваното `readLocks: int` поле
  - Поправени сигнатури в `core/server.nim` от `var LSMTree` на `LSMTree`
- ✅ Graph: добавен `std/locks.Lock` в `Graph` (вече беше `ref object`)
  - Всички публични операции (`addNode`, `addEdge`, `removeNode`, `getNode`, `getEdge`, `neighbors`, `inNeighbors`, `bfs`, `dfs`, `shortestPath`, `dijkstra`, `pageRank`, `nodeCount`, `edgeCount`, `saveToFile`) са опаковани с `acquire`/`release`
  - Поправени вътрешни deadlock-ове (напр. `bfs`/`dfs`/`shortestPath` вече не извикват `neighbors`, а директен достъп до `adjacency`)
- ✅ Stress тестът (`tests/stress_test.nim`) вече използва `std/threadpool` с `spawn` за паралелни worker-и
  - 10 worker-а × 1000 ops, 0 грешки, ~833K ops/sec

### 3.2 Raft мрежов транспорт ✅ ЗАВЪРШЕНА
- ✅ Добавен `RaftNetwork` тип в `core/raft.nim` с `asyncdispatch` + `asyncnet`:
  - `run()` — слуша за входящи Raft RPC връзки на `raftPort`
  - `send(peerId, msg)` — изпраща сериализирано съобщение към пиър с persistent TCP socket
  - `broadcast(msgs)` — изпраща на всички пиъри
  - `receiveLoop(client)` — framed read (4-byte big-endian length + payload), диспатчва към `handleRequestVote`/`handleAppendEntries`
  - `heartbeatLoop()` — лидер изпраща `AppendEntries` heartbeat на всеки `heartbeatTimeout`
  - `stop()` — graceful shutdown
- ✅ Бинарна сериализация на `RaftMessage` с magic bytes (`RAFT`) + version
  - `serialize()` / `deserializeRaftMessage()` чрез `std/streams`
  - Поддържа `LogEntry`, `seq[LogEntry]`, всички reply полета
- ✅ Peer addressing: `RaftNode.peerAddrs: Table[string, (host, port)]` + `raftPort`
- ✅ Интеграция с `ElectionTimer`:
  - `tick(timer, net)` приема optional `RaftNetwork`
  - При follower/candidate timeout се изпращат реални `RequestVote` съобщения по TCP
- ✅ Тест "3-node election over TCP" — 3 нода на портове 19001/19002/19003, проверява че точно 1 става лидер

### 3.3 CI/CD и качество ✅ ЗАВЪРШЕНА
- ✅ Създаден `.github/workflows/ci.yml`:
  - Пуска `nim c --path:src -r tests/test_all.nim` на всеки push/PR
  - Компилира `benchmarks/bench_all.nim` в release режим
  - Компилира и пуска `tests/stress_test.nim`
  - Проверява за `XDeclaredButNotUsed` и `UnusedImport` като GitHub Actions annotations
- ✅ Създаден `tests/stress_test.nim`:
  - 10 worker-а, всеки прави 1000 произволни put/get/delete операции
  - Всеки worker използва собствена LSMTree инстанция (до Phase 3.1 за thread-safety)
  - Проверка за data corruption — 0 грешки при 10 000 ops (~143K ops/sec)

### 3.4 Изчисти проекта ✅ ЗАВЪРШЕНА
- ✅ Изтрити broken/unused файлове:
  - `src/barabadb/protocol/http.nim` (unused, 5 compile errors)
  - `src/barabadb/protocol/tls.nim` (unused, 25 errors, overlaps with `ssl.nim`)
  - `src/barabadb/protocol/websocket.nim` (unused, 14 errors)
  - `src/barabadb.nim` (6-line dead re-export stub)
- ✅ Премахнати ~20 unused imports от `src/` модулите
- ✅ Добавени build artifacts в `.gitignore` (`*.out`, тест/бенчмарк бинарни файлове)

---

## Приоритетна матрица

| Задача | Влияние | Трудност | Приоритет |
|--------|---------|----------|-----------|
| SSTable реално четене | Критично | Средна | P0 ✅ |
| README честност | Високо | Ниска | P0 ✅ |
| HNSW истински search | Високо | Висока | P1 ✅ |
| Wire protocol в сървъра | Високо | Средна | P1 ✅ |
| Benchmark fix | Ниско | Ниска | P2 ✅ |
| Graph персистентност | Средно | Ниска | P2 ✅ |
| Raft мрежа | Средно | Висока | P2 ✅ |
| Thread-safety | Средно | Средна | P2 ✅ |
| CI/CD | Средно | Ниска | P3 ✅ |
| Изчистване на проекта | Ниско | Ниска | P3 ✅ |

---

## Очакван резултат след изпълнение

- **Фаза 1:** Проектът е честен, стабилен и benchmark-ите работят. LSM-Tree е валиден key-value store. ✅
- **Фаза 2:** HNSW работи с реален approximate search. Сървърът изпълнява заявки. Има персистентност. ✅
- **Фаза 3:** Многонишкова безопасност, CI, по-чист код. ✅

**Крайна оценка след плана:** от 6.5/10 към 8.5/10.
