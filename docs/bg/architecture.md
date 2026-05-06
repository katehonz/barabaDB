# BaraDB Архитектура

## Преглед

BaraDB е **мултимодална база данни** написана на Nim, която комбинира документно (KV), графично, векторно, колонно и пълнотекстово търсене в един двигател с обединен език за заявки наречен **BaraQL**.

## Слоеста Архитектура

```
┌─────────────────────────────────────────────────────────┐
│ 1. СЛОЙ ЗА КЛИЕНТИ                                       │
│    Binary Protocol │ HTTP/REST │ WebSocket │ Embedded    │
├─────────────────────────────────────────────────────────┤
│ 2. ЗАЯВКИ СЛОЙ (BaraQL)                                  │
│    Lexer → Parser → AST → IR → Optimizer → Codegen      │
├─────────────────────────────────────────────────────────┤
│ 3. ИЗПЪЛНИТЕЛЕН ДВИГАТЕЛ                                  │
│    Document │ Graph │ Vector │ Columnar │ FTS            │
├─────────────────────────────────────────────────────────┤
│ 4. СЪХРАНЕНИЕ                                             │
│    LSM-Tree │ B-Tree │ WAL │ Bloom │ Compaction │ Cache  │
├─────────────────────────────────────────────────────────┤
│ 5. РАЗПРЕДЕЛЕНО                                           │
│    Raft Consensus │ Sharding │ Replication │ Gossip      │
└─────────────────────────────────────────────────────────┘
```

## Слой 1: Клиентски Слой

Множество протоколи за комуникация:

- **Binary Protocol** (`protocol/wire.nim`): Ефективен big-endian бинарен протокол с 16 типа съобщения
- **HTTP/REST** (`core/httpserver.nim`): JSON REST API с мулти-трединг
- **WebSocket** (`core/websocket.nim`): Пълен дуплекс стрийминг
- **Embedded** (`storage/lsm.nim`): Директен in-process достъп

### Управление на Връзките

- **Connection Pool** (`protocol/pool.nim`): Мин/макс лимити на връзки
- **Rate Limiting** (`protocol/ratelimit.nim`): Token-bucket лимитиране
- **Authentication** (`protocol/auth.nim`): JWT с HMAC-SHA256
- **TLS/SSL** (`protocol/ssl.nim`): TLS 1.3 с авто-генерирани сертификати

## Слой 2: Заявки (BaraQL)

Pipeline-а на BaraQL:

1. **Lexer** (`query/lexer.nim`): Токенизира входа в 80+ типа токени
2. **Parser** (`query/parser.nim`): Рекурсивен descent парсър произвеждащ AST
3. **AST** (`query/ast.nim`): 300+ реда покриващи 25+ вида възли
4. **IR** (`query/ir.nim`): Междинно представяне за планове за изпълнение
5. **Optimizer** (`query/adaptive.nim`): Адаптивен крос-модален оптимизатор
6. **Codegen** (`query/codegen.nim`): Транслира IR към операции върху съхранение
7. **Executor** (`query/executor.nim`): Изпълнява планове с паралелизация

### Крос-Модално Планиране

Оптимизаторът определя реда на изпълнение между двигателите:

```
1. Оценка на селективност за всеки предикат
2. Най-селективният предикат се изпълнява първи
3. Bloom филтри за KV търсения
4. Паралелизация на независими клонове
```

## Слой 3: Изпълнителен Двигател

### Document/KV Двигател
- **LSM-Tree** (`storage/lsm.nim`): Оптимизиран за запис с MemTable, WAL, SSTables
- **B-Tree Index** (`storage/btree.nim`): Подреден индекс за диапазони с COW

### Vector Engine
- **HNSW** (`vector/engine.nim`): Иерархичен навигируем малък свят
- **IVF-PQ** (`vector/engine.nim`): Инвертиран файл с продуктово квантуване
- **SIMD** (`vector/simd.nim`): AVX2-оптимизирани изчисления на разстояния
- **Quantization** (`vector/quant.nim`): Скаларно, продуктово и бинарно квантуване

### Graph Engine
- **Списък със съседи** (`graph/engine.nim`): Насочен граф с тегла
- **Алгоритми** (`graph/engine.nim`): BFS, DFS, Dijkstra, PageRank
- **Community Detection** (`graph/community.nim`): Louvain алгоритъм
- **Pattern Matching** (`graph/community.nim`): Subgraph isomorphism
- **Cypher Parser** (`graph/cypher.nim`): Cypher-подобни заявки

### FTS
- **Инвертиран индекс** (`fts/engine.nim`): Термин-документ индекс
- **Ранжиране** (`fts/engine.nim`): BM25 и TF-IDF
- **Fuzzy Search** (`fts/engine.nim`): Levenshtein разстояние
- **Многоезичен** (`fts/multilang.nim`): Токенизация за EN, BG, DE, FR, RU

### Columnar Engine
- **Колонно съхранение** (`core/columnar.nim`): Аналитични заявки
- **Компресия**: RLE и dictionary encoding
- **SIMD агрегати**: Ускорени агрегатни функции

## Слой 4: Съхранение

- **LSM-Tree** (`storage/lsm.nim`): MemTable, WAL, SSTable, Bloom Filter, Compaction
- **Page Cache** (`storage/compaction.nim`): LRU кеш
- **Memory-mapped I/O** (`storage/mmap.nim`): mmap-базиран достъп
- **Recovery** (`storage/recovery.nim`): WAL replay и възстановяване

### Път на Запис

```
Client → Protocol → Auth → Parser → AST → IR → Codegen
  → StorageOp → MVCC Txn → WAL Write → MemTable → Commit
```

### Път на Четене

```
Client → Protocol → Auth → Parser → AST → IR → Codegen
  → StorageOp → MVCC Snapshot → MemTable → SSTable → Result
```

## Слой 5: Разпределено

- **Raft Consensus** (`core/raft.nim`): Лидерско избиране, репликация на логове
- **Sharding** (`core/sharding.nim`): Hash, range и консистентно хеширане
- **Replication** (`core/replication.nim`): Sync, async, semi-sync режими
- **Gossip Protocol** (`core/gossip.nim`): SWIM-подобно управление на членство
- **Distributed Transactions** (`core/disttxn.nim`): Two-phase commit

## Статистика на Модулите

| Категория | Модули | Редове Код | Предназначение |
|-----------|--------|------------|----------------|
| Core | 16 | ~4,200 | Сървър, протоколи, транзакции, разпределено |
| Storage | 7 | ~3,100 | LSM, B-Tree, WAL, bloom, compaction, mmap |
| Query | 7 | ~2,800 | Lexer, parser, AST, IR, оптимизатор, codegen, executor |
| Vector | 3 | ~1,200 | HNSW, IVF-PQ, квантуване, SIMD |
| Graph | 3 | ~1,000 | Списък със съседи, алгоритми, community detection |
| FTS | 2 | ~900 | Инвертиран индекс, BM25, fuzzy, многоезичен |
| Protocol | 7 | ~2,400 | Wire, HTTP, WebSocket, pool, auth, rate limit, SSL |
| Schema | 1 | ~600 | Типове, връзки, наследяване, миграции |
| Client | 2 | ~800 | Nim binary client, file helpers |
| CLI | 1 | ~400 | Интерактивна BaraQL конзола |
| **Общо** | **49** | **~14,100** | |
