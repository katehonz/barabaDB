# BaraDB Архитектура

## Преглед

BaraDB е **мултимодален database engine**, написан на Nim, който комбинира документно (KV), графово, векторно, колонково и пълнотекстово съхранение в един engine с унифициран език за заявки наречен **BaraQL**.

## Слоеве на Архитектурата

```
┌─────────────────────────────────────────────────────────┐
│ 1. КЛИЕНТСКИ СЛОЙ                                        │
│    Бинарен Протокол │ HTTP/REST │ WebSocket │ Embedded   │
├─────────────────────────────────────────────────────────┤
│ 2. QUERY СЛОЙ (BaraQL)                                   │
│    Lexer → Parser → AST → IR → Optimizer → Codegen      │
├─────────────────────────────────────────────────────────┤
│ 3. ИЗПЪЛНИТЕЛЕН ENGINE                                   │
│    Документен │ Графов │ Векторен │ Колонков │ FTS       │
├─────────────────────────────────────────────────────────┤
│ 4. СЪХРАНЕНИЕ                                            │
│    LSM-Tree │ B-Tree │ WAL │ Bloom │ Compaction │ Cache  │
├─────────────────────────────────────────────────────────┤
│ 5. РАЗПРЕДЕЛЕНИ                                          │
│    Raft Консенсус │ Шардиране │ Репликация │ Gossip      │
└─────────────────────────────────────────────────────────┘
```

## Слой 1: Клиентски Слой

Множество комуникационни протоколи:

- **Бинарен Протокол** (`protocol/wire.nim`): Ефективен big-endian бинарен протокол с 16 типа съобщения
- **HTTP/REST** (`core/httpserver.nim`): JSON-базиран REST API с multi-threading
- **WebSocket** (`core/websocket.nim`): Full-duplex стрийминг
- **Embedded** (`storage/lsm.nim`): Директен in-process достъп

### Управление на Връзки

- **Connection Pool** (`protocol/pool.nim`): Min/max лимити на връзки с idle timeout
- **Rate Limiting** (`protocol/ratelimit.nim`): Token-bucket глобални и per-client лимити
- **Автентикация** (`protocol/auth.nim`): JWT с HMAC-SHA256 и достъп на база роли
- **TLS/SSL** (`protocol/ssl.nim`): TLS 1.3 с автоматично генерирани сертификати

## Слой 2: Query Слой (BaraQL)

BaraQL конвейрът:

1. **Lexer** (`query/lexer.nim`): Токенизира входа в 80+ типа токени
2. **Parser** (`query/parser.nim`): Recursive descent parser генериращ AST
3. **AST** (`query/ast.nim`): 300+ реда покриващи 25+ вида възли
4. **IR** (`query/ir.nim`): Intermediate representation за планове за изпълнение
5. **Optimizer** (`query/adaptive.nim`): Adaptive cross-modal оптимизация на заявки
6. **Codegen** (`query/codegen.nim`): Превежда IR към storage операции
7. **Executor** (`query/executor.nim`): Изпълнява планове с паралелизация

## Слой 3: Изпълнителен Engine

### Документен/KV Engine
- **LSM-Tree** (`storage/lsm.nim`): Write-оптимизирано съхранение с MemTable, WAL, SSTables
- **B-Tree Индекс** (`storage/btree.nim`): Подреден индекс за range сканиране с COW

### Vector Engine (`vector/`)
- **HNSW Индекс** (`vector/engine.nim`): Hierarchical Navigable Small World граф
- **IVF-PQ Индекс** (`vector/engine.nim`): Inverted File Index с Product Quantization
- **SIMD Операции** (`vector/simd.nim`): AVX2-оптимизирани изчисления на разстояние
- **Квантуване** (`vector/quant.nim`): Скаларно, продуктово и бинарно квантуване

### Graph Engine (`graph/`)
- **Adjacency List** (`graph/engine.nim`): Насочен граф с тегла на ребрата
- **Алгоритми** (`graph/engine.nim`): BFS, DFS, Dijkstra, PageRank
- **Community Detection** (`graph/community.nim`): Louvain алгоритъм
- **Pattern Matching** (`graph/community.nim`): Subgraph изоморфизъм
- **Cypher Parser** (`graph/cypher.nim`): Cypher-подобни графови заявки

### Full-Text Search (`fts/`)
- **Inverted Index** (`fts/engine.nim`): Термин-документен индекс
- **Ранжиране** (`fts/engine.nim`): BM25 и TF-IDF оценяване
- **Fuzzy Търсене** (`fts/engine.nim`): Съвпадение с Levenshtein разстояние
- **Многоезичност** (`fts/multilang.nim`): Токенизатори за EN, BG, DE, FR, RU

### Columnar Engine (`core/columnar.nim`)
- Колонково съхранение за аналитични заявки
- RLE и dictionary encoding
- SIMD-ускорени агрегати

## Слой 4: Съхранение

- **LSM-Tree** (`storage/lsm.nim`): MemTable, WAL, SSTable, Bloom Filter, Compaction
- **Page Cache** (`storage/compaction.nim`): LRU кеш с проследяване на hit rate
- **Memory-mapped I/O** (`storage/mmap.nim`): mmap-базиран достъп до файлове
- **Recovery** (`storage/recovery.nim`): WAL replay и crash recovery

## Слой 5: Разпределение

- **Raft Консенсус** (`core/raft.nim`): Leader election, log репликация
- **Шардиране** (`core/sharding.nim`): Hash, range и consistent hashing
- **Репликация** (`core/replication.nim`): Sync, async, semi-sync режими
- **Gossip Протокол** (`core/gossip.nim`): SWIM-подобно управление на членство
- **Разпределени Транзакции** (`core/disttxn.nim`): Two-phase commit

## Ключови Дизайнерски Решения

1. **Чист Nim**: Без Cython, Python или Rust зависимости
2. **Унифицирано Съхранение**: Един engine обработва KV, graph, vector, FTS и columnar
3. **Embedded Режим**: Може да работи като библиотека или сървър
4. **Бинарен Протокол**: Персонализиран ефективен wire протокол
5. **MVCC**: Multi-version concurrency control
6. **Schema-First**: Силно типизирана система от схеми с наследяване
7. **Cross-Modal**: Един език за заявки за всички модели на данни
8. **Формално Верифициран**: Основните разпределени алгоритми са специфицирани в TLA+ и проверени с TLC

## Статистика на Модулите

| Категория | Модули | Редове Код | Предназначение |
|-----------|--------|------------|----------------|
| Core | 16 | ~4,200 | Сървър, протоколи, транзакции, разпределени |
| Storage | 7 | ~3,100 | LSM, B-Tree, WAL, bloom, compaction, mmap |
| Query | 7 | ~2,800 | Lexer, parser, AST, IR, optimizer, codegen, executor |
| Vector | 3 | ~1,200 | HNSW, IVF-PQ, квантуване, SIMD |
| Graph | 3 | ~1,000 | Adjacency list, алгоритми, community detection |
| FTS | 2 | ~900 | Inverted index, BM25, fuzzy, многоезичност |
| Protocol | 7 | ~2,400 | Wire, HTTP, WebSocket, pool, auth, rate limit, SSL |
| Schema | 1 | ~600 | Типове, връзки, наследяване, миграции |
| Client | 2 | ~800 | Nim бинарен клиент, файлови помощници |
| CLI | 1 | ~400 | Интерактивна BaraQL обвивка |
| **Общо** | **49** | **~14,100** | |
