# План за интеграция на BaraDB в nim-allographer

## Цел
**BaraDB** е пълноценен драйвер в `nim-allographer`. Използва се чист Nim клиент (`BaraClient` / `SyncClient`) без C зависимости. Compile-time switch: `DB_BARADB`.

---

## Актуално състояние (2026-05-21)

### Статус по фази

| Фаза | Състояние | Бележки |
|------|-----------|---------|
| 1. Инфраструктура и типове | **ГОТОВО** | `env.nim`, `connection.nim`, `query_builder.nim`, `schema_builder.nim` — всичко е интегрирано |
| 2. Query Builder — SQL генерация | **ГОТОВО** | `baradb_generator.nim` (397 реда), `baradb_builder.nim` (237 реда) — всички CRUD + агрегати |
| 3. Query Builder — execution | **ГОТОВО** (с бележки) | `baradb_exec.nim` (716 реда) — всички операции работят, но `insertId` използва `SELECT MAX` вместо `RETURNING` |
| 4. Schema Builder | **СКЕЛЕТ** | Flow-ът е налице, но column type mapping е 24 реда вместо 466 (PostgreSQL) |
| 5. Тестове и документация | **МИНИМАЛНО** | Само `test_open.nim` и `test_query.nim` |

---

## Какво е ГОТОВО (не пипай)

### Wire Protocol клиент — `query_builder/libs/baradb/baradb_client.nim` (706 реда)
- Pure Nim, async + sync, без C FFI
- Binary serialization (big-endian) на всички `WireValue` типове (13 типа: fkNull..fkJson)
- `mkQuery`, `mkQueryParams`, `mkAuth`, `mkPing` съобщения
- `readQueryResponse` — парсва `mkData`, `mkComplete`, `mkError`, `mkReady`
- Вграден `QueryBuilder` (fluent) за standalone употреба

### Connection Pool — `baradb_open.nim` + `baradb_exec.nim`
- `dbOpen(Baradb, database, user, pass, host, port, maxConnections, timeout)`
- `getFreeConn()` — async с deque-based waiters и timeout
- `returnConn()` — освобождава и буди чакащи
- Connection aging: `maxConnectionLifetime`, `maxConnectionIdleTime`
- `refreshConn()`, `hasConnExpired()`, `openBaradbConn()`

### Query Builder — `baradb_query.nim` (386 реда)
- Всички fluent методи: `select`, `table`, `distinct`, `join`, `leftJoin`
- `where` / `orWhere` (string|int|float, bool, nil overloads)
- `whereBetween`, `whereNotBetween`, `whereIn`, `whereNotIn`, `whereNull`
- `groupBy`, `having`, `orderBy`, `limit`, `offset`
- `raw(sql, args)` — суров SQL с параметри

### SQL Generator — `baradb_generator.nim` (397 реда)
- Всички SQL конструкции: SELECT, INSERT, UPDATE, DELETE, агрегати
- Quoting с backtick `` ` `` (MySQL/SQLite стил, **не** PostgreSQL `"`)
- Placeholder: `?` (не `$1`)

### Execution — `baradb_exec.nim` (716 реда)
- `get()`, `first()`, `find()` → `seq[JsonNode]` / `Option[JsonNode]`
- `getPlain()`, `firstPlain()`, `findPlain()` → `seq[seq[string]]`
- `insert(JsonNode)`, `insert(seq[JsonNode])`, `insertId(...)`
- `update(JsonNode)`, `delete()`, `delete(id)`
- `count()`, `min()`, `max()`, `avg()`, `sum()`
- `begin()`, `commit()`, `rollback()` + `transaction` макро
- Raw query варианти за всички операции
- `seeder` шаблони

### ORM — споделен модул
- `orm()` template работи с BaraDB

### Schema Code Generation — `usecases/baradb/create_schema.nim`
- Четене от `information_schema` и генериране на Nim типове

---

## Какво трябва да се ДОИЗПИПА

### 1. Prepared Statements — САМО типове, НЯМА имплементация

**Текущо състояние:** Типовете са дефинирани в `baradb_types.nim`:
- `BaradbPreparedEntry` — `sql`, `nArgs`, `refCount`, `lastUsedAt`
- `BaradbPreparedContext` — `owner`, `connI`
- `BaradbPreparedStatement` — `owner`, `entry`, `sql`, `nArgs`, `isClosed`
- `preparedCache` е инициализиран в `baradb_open.nim`

**Липсващо:**
- `prepare()` proc — да създава `BaradbPreparedStatement`
- `ensureStmt()` — да кешира и преизползва statement-и
- `get*()` / `exec*()` procs върху `BaradbPreparedStatement`
- `withConn()` proc за context-based изпълнение
- `flushStmt()` / `clearStmtCache()`

**Wire protocol поддръжка:** `baradb_client.nim` вече има `mkQueryParams` — параметризираните заявки са вградени на ниво протокол. Трябва само да се свърже от allographer слоя.

**Проблем:** В момента `baradb_exec.nim` използва **client-side string interpolation** (`formatSql` + `escapeSqlValue`) вместо server-side параметри. Това е по-малко сигурно и по-малко ефективно.

**Референция:** PostgreSQL драйверът има ~300 реда prepared statement код (`postgres_exec.nim` — `ensureStmt`, `preparedQuery`, `preparedExec`, `deallocate`, `flush`, `clearCache`, context API).

**План:**
```
Файл: baradb_exec.nim
- [ ] prepare(sql: string): BaradbPreparedStatement
- [ ] ensureStmt(conn, sql, nArgs): BaradbPreparedEntry — кеширане в preparedCache
- [ ] preparedGet(stmt, args): seq[JsonNode] — използва mkQueryParams
- [ ] preparedExec(stmt, args): void
- [ ] withConn(pool, callback): auto — context-based
- [ ] flushStmt(stmt): void — deallocate
- [ ] clearStmtCache(): void
```

---

### 2. RETURNING id за INSERT — използва SELECT MAX (race condition)

**Текущо състояние в `baradb_exec.nim`:**
```nim
discard await self.pools.conns[connI].client.exec(sql)
let idSql = &"SELECT MAX(\"{key}\") FROM \"{table}\""
let qr = await self.pools.conns[connI].client.query(idSql)
```

**Проблем:** Race condition при конкурентни INSERT-и — друг INSERT може да мине между двете заявки.

**Варианти:**
1. **`INSERT ... RETURNING id`** — ако BaraDB го поддържа (за предпочитане, атомарно)
2. **`last_insert_rowid()`** — ако BaraDB има такава функция (както SQLite)
3. **`SELECT LAST_INSERT_ID()`** — MySQL-стил
4. **CTE с `INSERT ... RETURNING`** — `WITH inserted AS (INSERT ...) SELECT id FROM inserted`

**План:**
```
Файл: baradb_exec.nim — insertId proc
- [ ] Проверка дали BaraDB поддържа RETURNING
- [ ] Ако да: INSERT ... RETURNING "id" (като PostgreSQL)
- [ ] Ако не: използване на заявката за последно вмъкнат ID от wire protocol-а
- [ ] Премахване на SELECT MAX workaround
```

---

### 3. Schema Builder — Column Type Mapping е СКЕЛЕТ

**Текущо състояние в `queries/baradb/sub/create_column_query.nim` (24 реда):**
```nim
query.add(&"`{column.name}` {column.typ}")
# Само: NOT NULL, UNIQUE, DEFAULT
```

**Проблем:** Изкарва raw `RdbTypeKind` enum стойности (`rdbIncrements`, `rdbString`) вместо SQL типове (`SERIAL`, `VARCHAR(256)`).

**Референция:** PostgreSQL `sub/create_column_query.nim` — **466 реда**, обработва всички `RdbTypeKind`:
- `rdbIncrements` → `SERIAL PRIMARY KEY`
- `rdbBigIncrements` → `BIGSERIAL PRIMARY KEY`
- `rdbInteger` → `INTEGER`
- `rdbBigInteger` → `BIGINT`
- `rdbBoolean` → `BOOLEAN`
- `rdbString(n)` → `VARCHAR(n)` (default 255)
- `rdbText` → `TEXT`
- `rdbFloat` → `DOUBLE PRECISION`
- `rdbDecimal(p,s)` → `DECIMAL(p,s)`
- `rdbDate` → `DATE`
- `rdbDateTime` / `rdbTimestamp` → `TIMESTAMP`
- `rdbTimestampz` → `TIMESTAMPTZ`
- `rdbTime` → `TIME`
- `rdbBinary` → `BYTEA`
- `rdbUuid` → `UUID`
- `rdbJson` / `rdbJsonb` → `JSON` / `JSONB`
- `rdbEnum` → `VARCHAR(255)` + CHECK constraint
- Foreign keys: `REFERENCES "table"("column") ON DELETE/UPDATE CASCADE/SET NULL/...`
- Indexes, comments, unsigned

**План:**
```
Файл: queries/baradb/sub/create_column_query.nim
- [ ] Пълен mapping на RdbTypeKind → SQL тип (по PostgreSQL референцията)
- [ ] Auto-increment: SERIAL / BIGSERIAL PRIMARY KEY
- [ ] String/Text: VARCHAR(n), TEXT с default 255
- [ ] Числови: INTEGER, BIGINT, SMALLINT, DOUBLE PRECISION, DECIMAL(p,s)
- [ ] Дати: DATE, TIME, TIMESTAMP, TIMESTAMPTZ
- [ ] Бинарни: BYTEA
- [ ] Специални: UUID, JSON, JSONB, BOOLEAN, ENUM
- [ ] Foreign key constraints: REFERENCES ... ON DELETE/UPDATE
- [ ] Index генерация
- [ ] Column comments

Файл: queries/baradb/create_table.nim
- [ ] Да използва create_column_query вместо raw {column.typ}

Файлове: rename_column.nim, rename_table.nim
- [ ] Fix: `changeTo` → `previousName` (ако е bug)

Файл: create_migration_table.nim
- [ ] Консистентност: backtick quoting вместо double-quote

Файл: schema_utils.nim
- [ ] shouldRun() — checksum-based skip (вместо винаги true)
```

---

### 4. SQL Quoting Inconsistency

**Проблем:** `baradb_generator.nim` използва backtick `` ` ``, но `create_migration_table.nim` използва double-quote `"`. Трябва да е консистентно.

**Въпрос:** Какво използва BaraDB сървърът? Ако поддържа и двете — изберем едно. Ако само едно — коригираме навсякъде.

---

### 5. Database URL Support — липсва

PostgreSQL/MySQL/MariaDB драйверите поддържат `databaseUrl = asDatabaseUrl("postgresql://...")`. BaraDB `dbOpen` приема само позиционни параметри.

```
Файл: baradb_open.nim
- [ ] Парсване на `baradb://user:pass@host:port/db` URL
- [ ] Интеграция с `libs/database_url.nim`
```

---

### 6. Paginate / fastPaginate — липсват

Налични в други драйвери, липсват в BaraDB query builder.

```
Файл: baradb_exec.nim
- [ ] paginate(page, perPage): seq[JsonNode] + metadata
- [ ] fastPaginate(key, perPage): cursor-based
```

---

### 7. whereNull Bug

**Проблем:** `baradb_generator.nim:205` — `whereNullSql` референцира `row["symbol"]`, но `baradb_query.nim` `whereNull` не задава `"symbol"` ключ. Ще даде runtime crash.

```
Файл: baradb_query.nim — whereNull proc
- [ ] Добавяне на "symbol": "IS" или "IS NOT" в JSON а
```

---

## Тестове — какво липсва

| Тестов файл | Съществува за | Липсва за BaraDB |
|-------------|--------------|------------------|
| `test_open.nim` | postgres, sqlite, mysql, mariadb, surreal, **baradb** | — |
| `test_query.nim` | postgres, sqlite, mysql, mariadb, surreal, **baradb** | — |
| `test_prepared_statement.nim` | postgres, sqlite, mysql, mariadb, surreal | **baradb** |
| `test_schema.nim` | postgres, sqlite, mysql, mariadb, surreal | **baradb** |
| `test_create_schema.nim` | postgres, sqlite, mysql, mariadb, surreal | **baradb** |
| `test_pool_wait.nim` | postgres | **baradb** |
| `test_transaction.nim` | postgres, sqlite, mysql, mariadb, surreal | **baradb** |

---

## Приоритети

| # | Подобрение | Сложност | Ефект | Приоритет |
|---|-----------|----------|-------|-----------|
| 1 | Schema Builder column mapping | Средна | Без него migrations не работят | **ВИСОК** |
| 2 | INSERT RETURNING id | Ниска | Премахва race condition | **ВИСОК** |
| 3 | Prepared Statements | Висока | Security + performance | **СРЕДЕН** |
| 4 | Database URL support | Ниска | UX удобство | **НИСЪК** |
| 5 | Paginate / fastPaginate | Ниска | Feature parity | **НИСЪК** |
| 6 | whereNull fix | Ниска | Bug fix | **ВИСОК** |
| 7 | SQL quoting консистентност | Ниска | Потенциален runtime error | **СРЕДЕН** |
| 8 | Schema utils checksum | Ниска | Migration skip optimization | **НИСЪК** |

---

## Архитектура — файлова карта

```
src/allographer/
├── env.nim                          # DB_BARADB compile switch ✅
├── connection.nim                   # Import/export Baradb типове ✅
├── query_builder.nim                # Import/export baradb модули ✅
├── schema_builder.nim               # Import/export baradb schema ✅
│
├── query_builder/
│   ├── libs/baradb/
│   │   └── baradb_client.nim        # Wire protocol (706 реда) ✅
│   │
│   └── models/baradb/
│       ├── baradb_types.nim         # Типове (90 реда) ✅
│       ├── baradb_open.nim          # dbOpen + pool (52 реда) ✅
│       ├── baradb_query.nim         # Fluent API (386 реда) ✅
│       ├── baradb_exec.nim          # Execution (716 реда) ✅⚠️
│       ├── baradb_transaction.nim   # Transaction макро (42 реда) ✅
│       └── query/
│           ├── baradb_builder.nim   # SQL builder (237 реда) ✅
│           └── baradb_generator.nim # SQL generator (397 реда) ✅
│
├── schema_builder/
│   ├── queries/baradb/
│   │   ├── baradb_query_type.nim    # Типове (14 реда) ✅
│   │   ├── create_table.nim         # CREATE TABLE (16 реда) ⚠️ skeletal
│   │   ├── add_column.nim           # ADD COLUMN (8 реда) ⚠️ minimal
│   │   ├── change_column.nim        # ALTER COLUMN (8 реда) ⚠️ minimal
│   │   ├── drop_column.nim          # DROP COLUMN (8 реда) ✅
│   │   ├── drop_table.nim           # DROP TABLE (7 реда) ✅
│   │   ├── rename_column.nim        # RENAME COLUMN (8 реда) ⚠️ possible bug
│   │   ├── rename_table.nim         # RENAME TABLE (7 реда) ⚠️ possible bug
│   │   ├── reset_table.nim          # DELETE FROM (7 реда) ✅
│   │   ├── create_migration_table.nim (12 реда) ⚠️ quoting inconsistency
│   │   ├── schema_utils.nim         # shouldRun (12 реда) ⚠️ always true
│   │   └── sub/
│   │       ├── create_column_query.nim  # (24 реда) ❌ skeletal
│   │       ├── add_column_query.nim     # (8 реда) ⚠️ minimal
│   │       └── change_column_query.nim  # (6 реда) ⚠️ minimal
│   │
│   └── usecases/baradb/
│       ├── create.nim               # Table creation flow (24 реда) ✅
│       ├── alter.nim                # Alter flow (45 реда) ✅
│       ├── drop.nim                 # Drop flow (18 реда) ✅
│       ├── create_schema.nim        # Code gen from DB (60 реда) ✅
│       └── create_query_def.nim     # Factory (10 реда) ✅

tests/baradb/
├── config.nims                      # DB_BARADB=true ✅
├── connections.nim                  # Connection setup ✅
├── test_open.nim                    # Basic connection test ✅
├── test_query.nim                   # Integration tests ✅
├── test_prepared_statement.nim      # ❌ липсва
├── test_schema.nim                  # ❌ липсва
├── test_create_schema.nim           # ❌ липсва
├── test_pool_wait.nim               # ❌ липсва
└── test_transaction.nim             # ❌ липсва
```

**Легенда:** ✅ готово | ⚠️ partial/needs work | ❌ липсва | ✅⚠️ работи но с workaround

---

## Краткосрочен план (следващи стъпки)

### Седмица 1: Schema Builder + Bug fixes
1. `sub/create_column_query.nim` — пълен RdbTypeKind → SQL mapping (по PostgreSQL референция)
2. `create_table.nim` — да използва column query вместо raw тип
3. Fix `whereNull` bug в `baradb_query.nim`
4. Fix quoting inconsistency в `create_migration_table.nim`
5. Fix `rename_column.nim` / `rename_table.nim` ако `changeTo` не съществува

### Седмица 2: INSERT RETURNING + Prepared Statements (част 1)
1. `insertId` — проучване дали BaraDB поддържа RETURNING, имплементация
2. `prepare()` / `ensureStmt()` — prepared statement кеш
3. `preparedGet()` / `preparedExec()` — изпълнение през `mkQueryParams`

### Седмица 3: Тестове + Prepared Statements (част 2)
1. `test_schema.nim` — schema builder тестове
2. `test_prepared_statement.nim` — prepared statement тестове
3. `test_transaction.nim` — transaction тестове
4. `test_pool_wait.nim` — pool timeout тестове

### Седмица 4: Polish
1. Database URL support
2. Paginate / fastPaginate
3. Schema utils checksum
4. Документация в `documents/`
