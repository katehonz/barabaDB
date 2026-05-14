# Списък с Промени (Changelog)

Всички забележителни промени в BaraDB са документирани в този файл.

## [Unreleased] — SQL:2023 Стабилизация

### Поправки

- **GROUPING SETS изпълнение** — `lowerSelect` вече създава `irpkGroupBy` когато `selGroupingSetsKind != gskNone`, дори ако `selGroupBy` е празен. Преди това заявки като `GROUP BY GROUPING SETS ((dept), ())` напълно заобикаляха grouping executor-a.
- **FTS CREATE INDEX docId несъответствие** — `CREATE INDEX ... USING FTS` вече изчислява `docId` като хеш на `tableName.$key`, консистентно с DML операциите (`INSERT`/`UPDATE`/`DELETE`). Преди това създаването на индекс използваше последователни ID-та (0, 1, 2...), което причиняваше `@@` заявките никога да не намират индексирани документи.
- **Тестова изолация (всички сюити)** — Всички извиквания на `newLSMTree("")` са заменени с уникални временни директории за всеки сюит. Елиминира проблеми с натрупване на WAL и нестабилни тестове от споделено състояние между тестове.
- **Window frame parser** — `parseFrameBoundary` вече не консумира `tkRow` след `tkCurrent` неправилно (използваше `tkRows`). Също така е поправен конфликт на ключовата дума `tkRow` с парсването на `ENABLE ROW LEVEL SECURITY`.
- **ORDER BY + SELECT проекция** — `lowerSelect` вече поставя `irpkSort` преди `irpkProject`, което позволява `ORDER BY` по колони, които не присъстват в `SELECT` списъка.
- **UNPIVOT изпълнение** — Проверено и поправено липсващо тестово покритие за UNPIVOT трансформация.

### Добавки

- **JSON оператори** — `@>` (съдържа), `<@` (съдържа се в), `?` (има ключ), `?|` (има някой от), `?&` (има всички) вече се поддържат в lexer, parser и executor.
- **Window frame изпълнение** — `ROWS BETWEEN X PRECEDING AND Y FOLLOWING` / `CURRENT ROW` граници на рамката вече се спазват от `FIRST_VALUE` и `LAST_VALUE`.
- **Сесийни променливи** — `SET var_name = value` и `current_setting('var_name')` за ключ/стойност съхранение на ниво връзка.
- **Текущ потребител/роля** — `current_user` и `current_role` SQL ключови думи връщат потребителя и ролята на автентикираната сесия.
- **Auth-executor мост** — Сървърът и HTTP сървърът вече попълват `ExecutionContext.currentUser` и `ExecutionContext.currentRole` след JWT/SCRAM автентикация.
- **Multi-tenant RLS** — Row-Level Security политиките вече могат да реферират `current_user`, `current_role` и `current_setting('app.tenant_id')` за изолация на данни по тенант.

## [1.1.0] — 2026-05-13

### Добавки

- **Client SDKs v1.1.0** — Пълнофункционални клиенти за всички езици:
  - JavaScript: TypeScript дефиниции, package.json, примери, unit и integration тестове
  - Python: Преструктуриран като пакет (`baradb/` с `__init__.py` и `core.py`), pyproject.toml, примери, тестове (query builder, wire protocol, integration)
  - Nim: Примери, integration тестове, README
  - Rust: Примери, integration тестове, подобрен Cargo.toml
- **SCRAM-SHA-256 Автентикация** — RFC 7677 съвместима автентикация с PBKDF2 + HMAC + SHA-256 + nonce/salt генериране
- **HTTP SCRAM Endpoints** — `/auth/scram/start` + `/auth/scram/finish` в HTTP сървъра
- **Docker Compose Тестова Конфигурация** — `docker-compose.test.yml` за тестови среди
- **CI/CD Clients Pipeline** — `.github/workflows/clients-ci.yml` за автоматизирано тестване на клиенти

### Поправки

- **Query Executor** — Унарен минус (`irNeg`) вече работи коректно в SELECT и WHERE клаузи
- **Distributed Transactions** — Rollback след commit опит вече не нарушава атомарността
- **Sharding** — Протокол за миграция на данни с TCP + `scanAll` на LSM
- **Raft** — Поправено изчисление на мнозинство за четен брой нодове
- **MVCC** — Прекъснатите транзакции вече не стават видими
- **LSM-Tree** — Поправена загуба на данни при презаписване на immutable memtable; поправено сортиране на SSTable търсене
- **Auth** — JWT подписът е променен на HMAC-SHA256 (вече не е тривиално forgeable); валидация на токен изтичане (`exp`/`nbf`/`iat`); сравнението на подписи вече е constant-time
- **Recovery** — `summary()` вече не мутира базата данни
- **Wire Protocol** — 64MB лимит + bounds проверки + max дълбочина за предотвратяване на OOM/DoS
- **SQL Injection** — `exprToSql` вече escape-ва единични кавички
- **ReDoS** — `irLike`/`irILike` вече escape-ват regex метасимволи
- **Graph** — `addEdge` вече проверява съществуването на възел
- **Vector** — Валидация на несъответствие на размерности + HNSW заключване
- **FTS** — UTF-8 токенизацията вече използва runes вместо байтове
- **Build** — `nim.cfg` добавя `-d:ssl`, така че `nimble build` работи без флагове; `--threads:on` добавен към всички CI команди

### Промени

- **Версията е вдигната до 1.1.0** във всички компоненти (сървър, Docker изображения, клиенти, CLI)
- **README** — Версионният badge е обновен; всички feature таблици вече реферират v1.1.0
- **TLA+ Формална Верификация** — Добавени `crossmodal.tla`, `backup.tla`, `recovery.tla`; symmetry reduction във всички 9 спецификации
- **Чист build** — 0 компилаторни предупреждения на Nim 2.2.10

## [0.1.0] — 2025-01-15

### Добавки

- **Ядро за Съхранение**
  - LSM-Tree с MemTable, WAL, SSTables и size-tiered compaction
  - B-Tree подреден индекс с range сканиране и MVCC copy-on-write
  - Bloom филтри за ефективно пропускане на SSTable
  - Memory-mapped I/O за SSTable четене
  - LRU page cache с проследяване на hit rate

- **Query Engine (BaraQL)**
  - SQL-съвместим lexer с 80+ типа токени
  - Recursive descent parser генериращ AST с 25+ вида възли
  - Intermediate representation (IR) за планове за изпълнение
  - Code generator превеждащ IR към storage операции
  - Adaptive query optimizer с cross-modal планиране
  - Query executor с паралелизация

- **BaraQL Езикови Възможности**
  - SELECT, INSERT, UPDATE, DELETE
  - WHERE, ORDER BY, LIMIT, OFFSET
  - GROUP BY, HAVING, агрегатни функции (count, sum, avg, min, max)
  - INNER JOIN, LEFT JOIN, RIGHT JOIN, FULL JOIN, CROSS JOIN
  - CTEs (Common Table Expressions) с WITH
  - Подзаявки (EXISTS, IN, корелирани)
  - CASE изрази
  - UNION, INTERSECT, EXCEPT
  - Дефиниране на схема: CREATE TYPE, DROP TYPE

- **Vector Engine**
  - HNSW индекс за приблизително търсене на най-близки съседи
  - IVF-PQ индекс за мащабно векторно търсене
  - SIMD-оптимизирани функции за разстояние (cosine, L2, dot product, Manhattan)
  - Квантуване: scalar 8-bit/4-bit, product quantization, binary
  - Филтриране по метаданни при векторно търсене

- **Graph Engine**
  - Adjacency list съхранение за насочени графи с тегла
  - BFS и DFS обхождане
  - Dijkstra най-кратък път
  - PageRank важност на възли
  - Louvain community detection
  - Subgraph pattern matching
  - Cypher-подобен graph query parser

- **Full-Text Search**
  - Inverted index с term-document mapping
  - BM25 алгоритъм за ранжиране
  - TF-IDF оценяване
  - Fuzzy търсене с Levenshtein разстояние
  - Wildcard/regex търсене
  - Многоезични токенизатори (английски, български, немски, френски, руски)

- **Columnar Storage**
  - Колонково съхранение за аналитични заявки
  - RLE (Run-Length Encoding) компресия
  - Dictionary encoding за колони с ниска кардиналност
  - SIMD-ускорени агрегати

- **Транзакции**
  - MVCC (Multi-Version Concurrency Control) със snapshot изолация
  - Deadlock детекция чрез wait-for граф
  - Write-ahead log за устойчивост
  - Savepoints и частичен rollback

- **Протоколен Слой**
  - Бинарен wire протокол с 16 типа съобщения
  - HTTP/REST JSON API
  - WebSocket стрийминг
  - Connection pooling
  - JWT-базирана автентикация
  - Token-bucket rate limiting
  - TLS/SSL с автоматично генерирани сертификати

- **Система за Схеми**
  - Силна типова система с 17 нативни типа
  - Наследяване на типове с multi-base поддръжка
  - Property links между типове
  - Schema diffing и миграции
  - Изчислими свойства

- **Разпределени Системи**
  - Raft консенсус (leader election, log replication)
  - Hash, range и consistent-hash шардиране
  - Sync/async/semi-sync репликация
  - Gossip протокол за управление на членство
  - Two-phase commit за разпределени транзакции

- **Cross-Modal Заявки**
  - Унифициран език за заявки през всички storage двигатели
  - Cross-engine predicate pushdown
  - Оптимизирани планове за изпълнение за multi-modal заявки

- **Backup & Recovery**
  - Online snapshots без прекъсване
  - Point-in-time recovery чрез WAL replay
  - Инкрементални backups

- **Client SDKs**
  - JavaScript/TypeScript клиент с бинарен протокол
  - Python клиент със sync и async API
  - Nim embedded режим и клиентска библиотека
  - Rust клиент (async)

- **Операции**
  - Интерактивен CLI shell (BaraQL REPL)
  - Структурирано логване (JSON и текстови формати)
  - Prometheus-съвместим metrics endpoint
  - Health и readiness проби
  - CPU/memory profiling endpoints

- **Docker Поддръжка**
  - Multi-stage Dockerfile (Alpine Linux)
  - Docker Compose конфигурация
  - Health checks

### Производителност

- LSM-Tree: 580K записа/s, 720K четения/s
- B-Tree: 1.2M вмъквания/s, 1.5M търсения/s
- Vector SIMD: 850K косинусови разстояния/s (dim=768)
- FTS: 320K документи/s индексиране, 28K заявки/s BM25
- Graph: 2.5M възела/s вмъкване, 12K BFS обхождания/s
- Бинарен протокол: 380K заявки/s (100 конкурентни връзки)

### Тестове

- 262 теста в 56 тестови сюита
- 100% успеваемост

## [Unreleased]

### Добавки

- **Vector SQL Integration** — Пълна поддръжка на векторно търсене на SQL ниво:
  - `VECTOR(n)` тип колона в `CREATE TABLE` с валидация на размерност
  - `CREATE INDEX ... USING hnsw` / `USING ivfpq` за приблизителни nearest neighbor индекси
  - SQL функции за разстояние: `cosine_distance()`, `euclidean_distance()`, `inner_product()`, `l1_distance()`, `l2_distance()`
  - `<->` nearest-neighbor оператор (евклидово разстояние)
  - `ORDER BY` поддръжка за изрази с векторно разстояние, включително колони извън `SELECT`
  - Автоматична поддръжка на HNSW индекс при `INSERT` и `UPDATE`
- **Advanced SQL Engine** — Window функции, MERGE/UPSERT, LATERAL JOIN, PIVOT/UNPIVOT, SQL/PGQ Property Graph, Разширени агрегати (ARRAY_AGG, STRING_AGG, FILTER, GROUPING SETS/ROLLUP/CUBE)
- **JavaScript Client — TCP Request Queue** — Вътрешна `_requestQueue` + `_requestLock` за безопасни конкурентни заявки. Множество паралелни извиквания на `query()` / `execute()` / `ping()` вече не размесват бинарни frame-ове по връзката.

### Поправки

- **Query Executor — Ескейпване на Стойности** — `execInsert` вече правилно ескейпва запетаи и знаци за равенство в стойностите на колоните, поправяйки корупция на съхранението за векторни литерали като `[1.0, 2.0, 3.0]`
- **Query Planner — ORDER BY Проекция** — `irpkSort` вече се поставя преди `irpkProject` в IR плана, позволявайки на `ORDER BY` да реферира колони, които не са селектирани
- **Wire Protocol — Big-Endian Float Сериализация** — `FLOAT32`/`FLOAT64` и float стойностите във вектори вече се сериализират в big-endian byte order, съвпадайки с `readFloatBE()` / `readDoubleBE()` на клиента и осигурявайки междуплатформена числова точност.
- **Gossip Protocol — Async UDP Socket** — Заменен синхронният `newSocket` + блокиращ `recvFrom` с `newAsyncSocket` + `await recvFrom`, предотвратявайки замръзване на async event loop-а до пристигане на UDP пакет.

### Планирани

- Query plan caching
- Materialized views
- Геопространствен индекс
- Time-series оптимизации
- CDC (Change Data Capture) стрийминг
- Федеративни заявки между BaraDB инстанции
