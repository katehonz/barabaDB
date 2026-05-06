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

### 2.1 Реализирай истински HNSW search в `vector/engine.nim`
**Проблем:** `search()` прави линейно сканиране на всички нодове.

**Стъпки:**
1. При `insert(id, vector, metadata)`:
   - Изчисли `level` чрез `randomLevel()`
   - Свържи нода с `m` най-близки съседи на всяко ниво
   - Ако `level > maxLevel`, обнови `entryPoint`
2. Имплементирай `searchLayer(entryPoint, query, ef, level)` — жадно разширяване на кандидати
3. Имплементирай `search(query, k)`:
   - Започни от `entryPoint` на най-високо ниво
   - Слизай ниво по ниво, рефинирайки entry point
   - На ниво 0, върни top-k от `ef` кандидати
4. Тествай с 10K вектора dim=128, сравни recall@10 с brute-force
5. Очакван резултат: recall > 0.9 при `efConstruction=200, m=16`

### 2.2 Интегрирай wire protocol в TCP сървъра
**Проблем:** `core/server.nim` връща `"OK\n"` за всяка заявка.

**Стъпки:**
1. В `handleClient` замени `recvLine()` с четене на бинарни съобщения от `protocol/wire.nim`
2. За `QueryMessage`: извикай `tokenize` → `parse` → `codegen` → изпълни срещу LSM-Tree
3. Върни `ResultMessage` с реални данни или `ErrorMessage` при грешка
4. Тествай с клиент от `clients/nim/`

### 2.3 Добави персистентност на поне един от Graph/FTS/Columnar
**Предложение:** Започни с Graph engine, защото е най-прост за сериализация.
- Добави `saveToFile(path)` и `loadFromFile(path)` в `graph/engine.nim`
- Формат: NDJSON редове за нодове и edges, или прост бинарен формат
- Тествай: рестарт на процеса, зареждане, проверка на целостта

---

## Фаза 3: Production hardening (2–3 седмици)

### 3.1 Thread-safety и concurrency
- LSM-Tree: добави `lock` при `put/delete/flush`
- Graph: добави `lock` при `addNode/addEdge/removeNode`
- Или по-добре: използвай Nim's `atomic` типове и lock-free структури където е възможно
- Добави тестове с `parallel` блокове в Nim за stress testing

### 3.2 Raft мрежов транспорт
- В `core/raft.nim` добави `RaftNetwork` тип с async TCP комуникация
- `sendMessage(peerAddr, msg)` и `receiveLoop()`
- Интегрирай с `ElectionTimer` — при timeout, изпрати реални `RequestVote` съобщения по мрежата
- Тествай с 3 процеса на localhost на различни портове

### 3.3 CI/CD и качество
- Създай `.github/workflows/ci.yml`:
  - `nim c --path:src -r tests/test_all.nim`
  - `nim c -d:release benchmarks/bench_all.nim` (компилира, но не задължително пуска)
  - Проверка за `XDeclaredButNotUsed` hints като warnings
- Добави `tests/stress_test.nim`:
  - 10 паралелни задачи, всяка прави 1000 произволни put/get/delete
  - Проверка за data corruption

### 3.4 Изчисти проекта
- Премахни `GEL/` директорията (EdgeDB клон, ненужен)
- Провери дали всички `*.nim` файлове се използват — премахни dead code
- Унифицирай дублирани модули (напр. `protocol/ssl.nim` и `protocol/tls.nim` изглеждат припокриващи се)

---

## Приоритетна матрица

| Задача | Влияние | Трудност | Приоритет |
|--------|---------|----------|-----------|
| SSTable реално четене | Критично | Средна | P0 ✅ |
| README честност | Високо | Ниска | P0 ✅ |
| HNSW истински search | Високо | Висока | P1 |
| Wire protocol в сървъра | Високо | Средна | P1 |
| Benchmark fix | Ниско | Ниска | P2 ✅ |
| Graph персистентност | Средно | Ниска | P2 |
| Raft мрежа | Средно | Висока | P2 |
| Thread-safety | Средно | Средна | P2 |
| CI/CD | Средно | Ниска | P3 |
| Изчистване на проекта | Ниско | Ниска | P3 |

---

## Очакван резултат след изпълнение

- **Фаза 1:** Проектът е честен, стабилен и benchmark-ите работят. LSM-Tree е валиден key-value store. ✅
- **Фаза 2:** HNSW работи с реален approximate search. Сървърът изпълнява заявки. Има персистентност.
- **Фаза 3:** Многонишкова безопасност, CI, по-чист код.

**Крайна оценка след плана:** от 6.5/10 към 8.5/10.
