# BaraDB — Ревизия за бъгове и план за подобрения

> Дата: 2026-05-12
> Статус: В процес на поправяне

## Обобщение

| Категория | Брой | Статус |
|-----------|------|--------|
| 🔴 Критични | 9 | Незабавно поправяне |
| 🟠 Високи | 7 | Поправяне преди production |
| 🟡 Средни | 12 | Планирано поправяне |
| 🟢 Конфигурационни | 4 | Лесни за поправяне |

**Общ брой тестове:** 283 — всички минават, но тестовото покритие не покрива критични edge cases.

---

## 🔴 Критични бъгове

### 1. MVCC — Aborted транзакции стават видими
**Файл:** `src/barabadb/core/mvcc.nim`  
**Проблем:** `abortTxn` изтрива транзакцията от `activeTxns`. В `isVisible` проверката е:
```nim
if creator in tm.activeTxns and tm.activeTxns[creator].state != tsCommitted:
  return false
```
Ако транзакцията е aborted, тя вече не е в `activeTxns`, затова `isVisible` връща `true` и нейните писания стават видими за всички бъдещи четения.

**Fix:** Добави `abortedTxns` множество или проверявай `globalVersions` за състоянието на създателя.

### 2. LSM-Tree — Загуба на данни при immutable memtable overwrite
**Файл:** `src/barabadb/storage/lsm.nim`  
**Проблем:** Когато `memTable` се напълни:
```nim
db.immutableMem = db.memTable
db.memTable = newMemTable(db.memMaxSize)
```
Ако втори `put` дойде преди `flush()` да е извикан, `immutableMem` се презаписва и данните от първия overflow се губят завинаги.

**Fix:** Проверявай `if db.immutableMem.len > 0: triggerFlush()` преди да присвояваш нова immutable memtable, или използвай опашка.

### 3. LSM-Tree — Счупена SSTable търсачка
**Файл:** `src/barabadb/storage/lsm.nim`  
**Проблем:** `newLSMTree` сортира SSTables по `minKey`. `getUnsafe` търси `countdown(high, low)`, приемайки че по-висок индекс = по-нова таблица. След сортиране по `minKey` това вече не е вярно — стара SSTable може да маскира нова.

**Fix:** Сортирай по `maxTimestamp` или `id`, не по `minKey`.

### 4. Auth — JWT подписът е тривиално forgeable
**Файл:** `src/barabadb/protocol/auth.nim`  
**Проблем:** `simpleHash()` е djb2-подобен hash, **не HMAC-SHA256**. Токените могат да бъдат фалшифицирани за под 1 секунда.

```nim
proc simpleHash(data: string, key: string): string =
  var h: uint64 = 5381
  for ch in prefix:
    h = ((h shl 5) + h) + uint64(ord(ch))
```

**Fix:** Замени с `std/sha256` или `hmac` от `checksums` пакета.

### 5. Auth — SCRAM-SHA-256 е фалшив
**Файл:** `src/barabadb/protocol/auth.nim`  
**Проблем:** Няма challenge-response, salt, iteration count. Сравнява директно `stored == clientHash`. Еквивалентно на plaintext съхранение.

**Fix:** Имплементирай истински SCRAM-SHA-256 или премахни го.

### 6. Recovery — `summary()` мутира базата данни
**Файл:** `src/barabadb/storage/recovery.nim`  
**Проблем:** `summary()` извиква `recover()`, който реплейва WAL entries в LSMTree. Простото извикване на `summary` променя данните и пише нови WAL entries.

**Fix:** Раздели `analyze()` (read-only) от `recover()` (mutating). `summary()` трябва да ползва само `analyze()`.

### 7. DistTxn — Rollback след commit attempt нарушава atomicity
**Файл:** `src/barabadb/core/disttxn.nim`  
**Проблем:** В `commit()`, ако някои participants не acknowledge, coordinator се опитва да rollback-не nodes, които вече са върнали `committed = true`. Веднъж commit-нато, не може да се rollback-ва.

**Fix:** След първия successful commit на participant, не опитвай rollback. Ползвай heuristic recovery или блокирай докато всички acknowledge-нат.

### 8. Raft — Majority calculation bug за четен брой нодове
**Файл:** `src/barabadb/core/raft.nim`  
**Проблем:** `handleAppendReply` използва `matchIndices.len div 2` за median. За 4 нода това дава индекс 2, т.е. искат се само 2 нода, но Raft изисква strict majority (3).

**Fix:** `matchIndices.len div 2 + 1` или `(matchIndices.len + 1) div 2`.

### 9. Query — `EXISTS` подзаявки винаги връщат false
**Файл:** `src/barabadb/query/executor.nim`  
**Проблем:** `evalExpr` за `irekExists` хардкодира `return "false"`.

**Fix:** Изпълни подзаявката и провери дали връща редове.

---

## 🟠 Високо приоритетни бъгове

| # | Модул | Проблем | Последствие |
|---|-------|---------|-------------|
| 10 | `storage/wal.nim` | `sync()` прави само `stream.flush()`, не `fsync` | Загуба на данни при power loss |
| 11 | `protocol/ssl.nim` | Command injection в `generateSelfSignedCert` — конкатенира пътища в shell | RCE ако `BARADB_CERT_FILE` е контролиран от attacker |
| 12 | `protocol/wire.nim` | `readString` заделя `newString(len)` от wire без лимит | OOM/DoS с `len = 0xFFFFFFFF` |
| 13 | `protocol/wire.nim` | Няма bounds checking при deserialization | Out-of-bounds reads от malformed messages |
| 14 | `query/executor.nim` | `exprToSql` не escape-ва quotes в string literals | SQL injection в views и schema DDL |
| 15 | `query/executor.nim` | `irLike`/`irILike` превръща `%`→`.*` без escaping на regex metachars | ReDoS / Catastrophic backtracking |
| 16 | `query/executor.nim` | Stale BTree indexes на UPDATE/DELETE — не изтрива стари индекси | Queries връщат изтрити/обновени редове |

---

## 🟡 Средно приоритетни бъгове

| # | Модул | Проблем |
|---|-------|---------|
| 17 | `query/lexer.nim` | `true`/`false` се tokenizewat като `tkTrue`/`tkFalse`, но parser очаква `tkBoolLit` → `SELECT true` става `nkNullLit` |
| 18 | `query/lexer.nim` | `1.2.3` се приема като валиден `tkFloatLit` |
| 19 | `query/lexer.nim` | Незатворени block comments (`/*` без `*/`) не raise-ват error |
| 20 | `query/executor.nim` | Aggregate + `*` на empty result access-ва `sourceRows[0]` без проверка → crash |
| 21 | `query/ir.nim` | Unary minus (`-5`) се map-ва към boolean NOT вместо arithmetic negation |
| 22 | `query/udf.nim` | Non-aggregate UDFs в expression се treat-ват като NULL literals |
| 23 | `vector/engine.nim` | Dimension mismatch ползва `min(a.len, b.len)` вместо error |
| 24 | `vector/engine.nim` | Няма locking — concurrent insert + search корумпират HNSW |
| 25 | `fts/engine.nim` | Tokenize мангира UTF-8 (iterates by byte, not grapheme) |
| 26 | `graph/engine.nim` | `addEdge` без проверка дали node съществува → `KeyError` |
| 27 | `core/raft.nim` | Няма disk persistence — `currentTerm`, `votedFor`, log са in-memory |
| 28 | `core/server.nim` | `DISTTXN`/`REP` handlers чакат `recv()` без timeout → hang от malicious peer |

---

## 🔧 Конфигурационни проблеми

| # | Проблем | Файл | Fix |
|---|---------|------|-----|
| 29 | `nimble build` fail-ва без `-d:ssl`, въпреки `switch("define", "ssl")` в `.nimble` | `baradadb.nimble` | Добави `switch("define", "ssl")` в `nim.cfg` или използвай `before build:` hook |
| 30 | `bench` task сочи към `benchmarks/bench_storage.nim` който не съществува | `baradadb.nimble` | Промени на `benchmarks/bench_all.nim` |
| 31 | CI build benchmarks без `-d:ssl`, но `bench_all.nim` може да изисква SSL | `.github/workflows/ci.yml` | Добави `-d:ssl` |
| 32 | `threadpool` е deprecated (Nim 2.2) | `src/baradadb.nim` | Мигрирай към `malebolgia`/`weave`/`taskpools` |

---

## 📋 План за подобрения

### Незабавни действия (Sprint 0 — 1-2 седмици)

- [ ] Поправи MVCC isVisible (aborted txns)
- [ ] Поправи LSM-Tree immutable memtable overwrite
- [ ] Поправи LSM-Tree SSTable search order
- [ ] Замени simpleHash с HMAC-SHA256 в auth
- [ ] Поправи recovery.summary() да не мутира
- [ ] Поправи Raft majority calculation
- [ ] Поправи WAL sync() да прави fsync
- [ ] Поправи nimble build (-d:ssl)

### Краткосрочни (Sprint 1-2 — 1 месец)

- [ ] Имплементирай истински SCRAM-SHA-256 или го премахни
- [ ] Добави bounds checking в wire protocol
- [ ] Escape-вай string literals в exprToSql
- [ ] Поправи EXISTS subqueries
- [ ] Поправи stale BTree indexes на UPDATE/DELETE
- [ ] Добави timeouts на всички network reads
- [ ] Поправи boolean literal parsing
- [ ] Добави locking в HNSW/vector engine

### Средносрочни (1-2 месеца)

- [ ] Raft disk persistence (write-ahead log за Raft state)
- [ ] Command injection fix в SSL модул
- [ ] ReDoS fix в LIKE (escape regex metachars или не използвай regex)
- [ ] UTF-8 tokenization в FTS
- [ ] Memory management: unbounded version chains в MVCC
- [ ] Rate limiter: enforce globalRate, fix memory leaks
- [ ] Property-based тестове за LSM-Tree edge cases

### Дългосрочни (Formal Verification)

| Задача | Приоритет |
|--------|-----------|
| `backup.tla` — restore atomicity | Висок |
| `recovery.tla` — WAL replay correctness | Висок |
| `crossmodal.tla` — cross-modal consistency | Среден |
| Symmetry reduction в `.cfg` файловете | Нисък (performance) |

---

## 🎯 Ключеви метрики за проследяване

| Метрика | Цел |
|---------|-----|
| Тестово покритие | > 80% (сега вероятно < 50% за edge cases) |
| Fuzz тестове | Поне 1 fuzz target per storage engine |
| Security audit | Поправи всички 🔴 и 🟠 issues |
| Benchmark consistency | `nimble bench` да работи out-of-the-box |

---

## Заключение

BaraDB има солидна архитектура и много функционалности, но има **критични бъгове в core storage, MVCC, auth и distributed транзакциите**, които я правят **неподходяща за production** в момента. Препоръчвам фокусиран sprint върху критичните issues преди добавяне на нови функции.
