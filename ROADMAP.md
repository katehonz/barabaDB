# BaraDB — Мултимодална база данни на Nim

> По-добра от GEL (EdgeDB) — нативна мултимодалност, без Python, без PostgreSQL зависимост

## Защо BaraDB > GEL?

| Критерий | GEL (EdgeDB) | BaraDB |
|---|---|---|
| Език на ядрото | Python + Cython + Rust | **100% Nim** |
| Storage backend | Само PostgreSQL | **Нативен multi-engine** |
| Векторно търсене | pgvector (разширение) | **Нативен HNSW/IVF-PQ** |
| Graph алгоритми | Няма | **Нативни (BFS, PageRank, ...)** |
| Full-Text Search | pg FTS (разширение) | **Нативен инвертиран индекс** |
| Embedded режим | Не | **Да (като SQLite)** |
| Кompилация към WASM | Не | **Да** |
| Транзакции cross-modal | Чрез PG | **Нативен 2PC** |
| Протокол | Binary + PG wire + HTTP | **Binary + HTTP/WS + gRPC** |
| Schema миграции | Декларативни (тежки) | **Автоматични + версия** |

---

## Архитектура

```
┌─────────────────────────────────────────────────────────────┐
│                     КЛИЕНТСКИ СЛОЙ                          │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌─────────────┐ │
│  │ Binary   │  │ HTTP/REST│  │WebSocket │  │  Embedded   │ │
│  │ Protocol │  │ JSON API │  │  Stream  │  │  (in-proc)  │ │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └──────┬──────┘ │
├───────┼──────────────┼────────────┼────────────────┼────────┤
│                ЗАПИТЕН СЛОЙ (BaraQL)                         │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌─────────────┐ │
│  │ Лексер   │──│ Парсер   │──│ Анализ   │──│ Оптимизатор │ │
│  │          │  │ (AST)    │  │ (IR)     │  │ (Plan)      │ │
│  └──────────┘  └──────────┘  └──────────┘  └─────────────┘ │
├─────────────────────────────────────────────────────────────┤
│                ИЗПЪЛНИТЕЛЕН ДВИГАТЕЛ                         │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌─────────────┐ │
│  │ Document │  │  Graph   │  │  Vector  │  │  Columnar   │ │
│  │ Engine   │  │  Engine  │  │  Engine  │  │  Engine     │ │
│  │ (JSON/B) │  │ (AdjList)│  │ (HNSW)  │  │ (Arrow)     │ │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └──────┬──────┘ │
├───────┼──────────────┼────────────┼────────────────┼────────┤
│                STORAGE СЛОЙ                                 │
│  ┌─────────────────────────────────────────────────────────┐│
│  │  LSM-Tree Storage Engine                                ││
│  │  ┌────────┐  ┌────────┐  ┌────────┐  ┌──────────────┐ ││
│  │  │MemTable│  │WAL     │  │SSTable │  │Bloom Filter  │ ││
│  │  └────────┘  └────────┘  └────────┘  └──────────────┘ ││
│  └─────────────────────────────────────────────────────────┘│
│  ┌─────────────────────────────────────────────────────────┐│
│  │  Транзакции: MVCC + 2PC + Deadlock Detection            ││
│  └─────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────┘
```

---

## Пътна карта (Roadmap)

### Фаза 1: Ядро на базата данни ✅
- [x] LSM-Tree storage engine (MemTable, WAL, SSTable)
- [x] Bloom filter за бързо отхвърляне
- [x] Типова система (int, float, string, bool, bytes, uuid, datetime, json, vector)
- [x] Сериялизация на записите
- [x] B-Tree индекс за точкови заявки
- [x] Компактиране на SSTable (compaction strategies)
- [x] Page cache и buffer pool (LRU)

### Фаза 2: Език за заявки — BaraQL 🟡
- [x] Лексер с Unicode поддръжка
- [x] Рекурсивен парсер → AST
- [x] SELECT, INSERT, UPDATE, DELETE
- [x] WHERE, ORDER BY, LIMIT, OFFSET
- [x] Бинарни оператори (+, -, *, /, =, !=, <, >, AND, OR, NOT)
- [x] Подзаявки и EXISTS
- [x] Array литерали
- [x] Типов анализатор (type checker)
- [x] IR (Intermediate Representation)
- [x] Оптимизатор на заявки (predicate pushdown, projection pushdown)
- [x] GROUP BY, HAVING
- [x] JOIN (inner, left, right, full, cross)
- [x] CTE (WITH)
- [x] Агрегатни функции (count, sum, avg, min, max)
- [x] Codegen — IR → storage операции (predicate pushdown, cost estimation)
- [x] Потребителски функции (UDF) — stdlib + custom

### Фаза 3: Мултимодален storage 🟡
- [x] Документен engine — вложени JSON документи, масиви, вложени обекти
- [x] Граф engine — adjacency list, edge properties, incident index
- [x] Векторен engine — float32 arrays, distance metrics
- [x] Колонен engine — column-oriented storage за analytics (RLE, dict encoding, GroupBy)
- [x] Унифициран query interface през BaraQL (CrossModalEngine)
- [x] Cross-modal заявки (document + vector + graph в една заявка) — hybridSearch

### Фаза 4: Транзакции и ACID ✅
- [x] WAL (Write-Ahead Log) за durability
- [x] MVCC (Multi-Version Concurrency Control)
- [x] Snapshot isolation
- [x] Deadlock detection (wait-for graph)
- [x] Savepoints и вложени транзакции
- [x] 2PC за cross-modal транзакции (TPCTransaction)
- [ ] Recovery при crash (REDO/UNDO)

### Фаза 5: Мрежов протокол ✅
- [x] TCP сървър с async I/O
- [x] Binary протокол (BaraDB Wire Protocol)
- [x] HTTP/REST API (JSON)
- [x] Connection pooling
- [x] Authentication (JWT, SCRAM-SHA-256)
- [x] WebSocket за streaming
- [x] Rate limiting (token bucket, sliding window)
- [ ] TLS/SSL

### Фаза 6: Schema система ✅
- [x] Декларативна schema (SDL)
- [x] Object types с properties
- [x] Links между типове (1:1, 1:N, N:M)
- [x] Наследоване и mixins
- [x] Constraints (unique, check, required)
- [x] Computed properties
- [x] Автоматични миграции (schema diff)
- [x] Версиониране на schema

### Фаза 7: Векторен engine ✅
- [x] HNSW индекс (Hierarchical Navigable Small World)
- [x] IVF-PQ индекс (Inverted File + Product Quantization)
- [x] Дистанционни метрики (cosine, euclidean, dot product, Manhattan)
- [x] Квантизация (scalar 8-bit/4-bit, product, binary)
- [x] Metadata filtering при vector search
- [x] Batch insert/update (batchInsert, batchSearch)
- [x] Автоматичен index rebuild при threshold (IndexWatcher)

### Фаза 8: Graph engine ✅
- [x] Adjacency list storage
- [x] Edge properties и weights
- [x] BFS (Breadth-First Search)
- [x] DFS (Depth-First Search)
- [x] Най-къс път (Dijkstra)
- [x] PageRank
- [x] Community detection (Louvain)
- [x] Pattern matching (subgraph isomorphism)
- [x] Cypher-подобен query syntax (parseCypher, executeCypher)

### Фаза 9: Full-Text Search ✅
- [x] Инвертиран индекс
- [x] Токенизация (Unicode, stemming, stop words)
- [x] BM25 ранкиране
- [x] Highlight на резултати
- [x] TF-IDF ранкиране
- [x] Fuzzy matching (Levenshtein)
- [x] Regex търсене (wildcard patterns)
- [x] Многоезикова поддръжка (EN, BG, DE, FR, RU)

### Фаза 10: Клиентски библиотеки и CLI 🟡
- [x] CLI tool (bara shell) — интерактивен shell
- [x] Nim client library (client.nim — async/sync, query builder)
- [x] Import/Export (JSON, CSV, NDJSON)
- [ ] Python client library
- [ ] JavaScript/TypeScript client library
- [ ] Go client library
- [ ] Rust client library
- [ ] Interactive query editor с autocomplete

### Фаза 11: Кластеризация и разпределение 🟡
- [x] Raft консенсус протокол (leader election + log replication)
- [x] Sharding (hash-based, range-based, consistent hashing)
- [x] Replication (sync, async, semi-sync)
- [x] Gossip protocol за membership (GossipProtocol)
- [x] Distributed transactions (DistTxnManager + Saga pattern)
- [x] Auto-rebalancing (ClusterMembership — onNodeJoin/Leave/Fail)
- [ ] Leader election за multi-node (timer loop)

### Фаза 12: Оптимизации, бенчмаркове, документация 🟡
- [x] SIMD оптимизации за vector operations (unrolled loops, batch distance)
- [x] Memory-mapped I/O (mmap + madvise hints)
- [x] Zero-copy serialization (ZeroBuf + ZcSchema)
- [x] Adaptive query execution (AdaptivePlanner + ExecutionContext)
- [ ] Бенчмаркове vs GEL, PostgreSQL, MongoDB, Redis
- [ ] API документация (extended reference)
- [ ] Архитектурна документация
- [x] Tutorial и примери (examples/tutorial.nim)
- [ ] Tutorial и примери

---

## Статус

| Фаза | Статус | Напредък |
|------|--------|----------|
| 1. Ядро | ✅ Завършена | 95% |
| 2. BaraQL | ✅ Завършена | 100% |
| 3. Мултимодален storage | ✅ Завършена | 95% |
| 4. Транзакции | ✅ Завършена | 90% |
| 5. Протокол | ✅ Завършена | 95% |
| 6. Schema | ✅ Завършена | 100% |
| 7. Векторен engine | ✅ Завършена | 100% |
| 8. Graph engine | ✅ Завършена | 100% |
| 9. FTS | ✅ Завършена | 100% |
| 10. Клиенти и CLI | 🟡 В процес | 60% |
| 11. Кластер | ✅ Основно завършена | 90% |
| 12. Оптимизации | ✅ Основно завършена | 80% |

**Легенда:** ⬜ Не стартирана | 🟡 В процес | ✅ Завършена
