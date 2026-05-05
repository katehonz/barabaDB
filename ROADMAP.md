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
- [ ] B-Tree индекс за точкови заявки
- [ ] Компактиране на SSTable (compaction strategies)
- [ ] Page cache и buffer pool

### Фаза 2: Език за заявки — BaraQL 🟡
- [x] Лексер с Unicode поддръжка
- [x] Рекурсивен парсер → AST
- [x] SELECT, INSERT, UPDATE, DELETE
- [x] WHERE, ORDER BY, LIMIT, OFFSET
- [x] Бинарни оператори (+, -, *, /, =, !=, <, >, AND, OR, NOT)
- [x] Подзаявки и EXISTS
- [x] Array литерали
- [ ] Типов анализатор (type checker)
- [ ] IR (Intermediate Representation)
- [ ] Оптимизатор на заявки (predicate pushdown, projection pushdown)
- [ ] Codegen → storage операции
- [ ] GROUP BY, HAVING
- [ ] JOIN (inner, left, right, full)
- [ ] CTE (WITH)
- [ ] Агрегатни функции (count, sum, avg, min, max)
- [ ] Потребителски функции (UDF)

### Фаза 3: Мултимодален storage ✅
- [x] Документен engine — вложени JSON документи, масиви, вложени обекти
- [x] Граф engine — adjacency list, edge properties, incident index
- [x] Векторен engine — float32 arrays, distance metrics
- [ ] Колонен engine — column-oriented storage за analytics
- [ ] Унифициран query interface през BaraQL
- [ ] Cross-modal заявки (document + vector + graph в една заявка)

### Фаза 4: Транзакции и ACID 🟡
- [x] WAL (Write-Ahead Log) за durability
- [ ] MVCC (Multi-Version Concurrency Control)
- [ ] Snapshot isolation
- [ ] Deadlock detection (wait-for graph)
- [ ] 2PC за cross-modal транзакции
- [ ] Savepoints и вложени транзакции
- [ ] Recovery при crash (REDO/UNDO)

### Фаза 5: Мрежов протокол ⬜
- [ ] TCP сървър с async I/O
- [ ] Binary протокол (BaraDB Wire Protocol)
- [ ] HTTP/REST API (JSON)
- [ ] WebSocket за streaming
- [ ] Connection pooling
- [ ] Authentication (SCRAM-SHA-256, token)
- [ ] TLS/SSL
- [ ] Rate limiting

### Фаза 6: Schema система ⬜
- [ ] Декларативна schema (SDL)
- [ ] Object types с properties
- [ ] Links между типове (1:1, 1:N, N:M)
- [ ] Наследоване и mixins
- [ ] Constraints (unique, check, required)
- [ ] Computed properties
- [ ] Автоматични миграции (schema diff)
- [ ] Версиониране на schema

### Фаза 7: Векторен engine ✅
- [x] HNSW индекс (Hierarchical Navigable Small World)
- [x] IVF-PQ индекс (Inverted File + Product Quantization)
- [x] Дистанционни метрики (cosine, euclidean, dot product, Manhattan)
- [ ] Квантизация (scalar, product, binary)
- [ ] Metadata filtering при vector search
- [ ] Batch insert/update
- [ ] Автоматичен index rebuild при threshold

### Фаза 8: Graph engine ✅
- [x] Adjacency list storage
- [x] Edge properties и weights
- [x] BFS (Breadth-First Search)
- [x] DFS (Depth-First Search)
- [x] Най-къс път (Dijkstra)
- [x] PageRank
- [ ] Community detection (Louvain)
- [ ] Pattern matching (subgraph isomorphism)
- [ ] Cypher-подобен query syntax (или BaraQL extension)

### Фаза 9: Full-Text Search ✅
- [x] Инвертиран индекс
- [x] Токенизация (Unicode, stemming, stop words)
- [x] BM25 ранкиране
- [x] Highlight на резултати
- [ ] TF-IDF ранкиране
- [ ] Fuzzy matching (Levenshtein)
- [ ] Regex търсене
- [ ] Многоезикова поддръжка

### Фаза 10: Клиентски библиотеки и CLI ⬜
- [ ] CLI tool (bara shell)
- [ ] Nim client library
- [ ] Python client library
- [ ] JavaScript/TypeScript client library
- [ ] Go client library
- [ ] Rust client library
- [ ] Interactive query editor с autocomplete
- [ ] Import/Export (JSON, CSV, Parquet)

### Фаза 11: Кластеризация и разпределение ⬜
- [ ] Raft консенсус протокол
- [ ] Sharding (hash-based, range-based)
- [ ] Replication (sync, async)
- [ ] Leader election
- [ ] Gossip protocol за membership
- [ ] Distributed transactions
- [ ] Auto-rebalancing

### Фаза 12: Оптимизации, бенчмаркове, документация ⬜
- [ ] SIMD оптимизации за vector operations
- [ ] Memory-mapped I/O
- [ ] Zero-copy serialization
- [ ] Adaptive query execution
- [ ] Бенчмаркове vs GEL, PostgreSQL, MongoDB, Redis
- [ ] API документация
- [ ] Архитектурна документация
- [ ] Tutorial и примери

---

## Статус

| Фаза | Статус | Напредък |
|------|--------|----------|
| 1. Ядро | ✅ Основно завършена | 70% |
| 2. BaraQL | 🟡 В процес | 50% |
| 3. Мултимодален storage | ✅ Основно завършена | 60% |
| 4. Транзакции | 🟡 В процес | 15% |
| 5. Протокол | ⬜ Не стартирана | 0% |
| 6. Schema | ⬜ Не стартирана | 0% |
| 7. Векторен engine | ✅ Завършена | 60% |
| 8. Graph engine | ✅ Завършена | 70% |
| 9. FTS | ✅ Завършена | 60% |
| 10. Клиенти и CLI | ⬜ Не стартирана | 0% |
| 11. Кластер | ⬜ Не стартирана | 0% |
| 12. Оптимизации | ⬜ Не стартирана | 0% |

**Легенда:** ⬜ Не стартирана | 🟡 В процес | ✅ Завършена
