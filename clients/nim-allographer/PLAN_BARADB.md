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
| 3. Query Builder — execution | **ГОТОВО** | `baradb_exec.nim` (716 реда) — всички операции работят, `insertId` използва `RETURNING` |
| 4. Schema Builder | **ГОТОВО** | Пълен `RdbTypeKind` → SQL mapping, CREATE/ALTER/DROP table + column flow |
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

### 2. RETURNING id за INSERT — ✅ ИЗПРАВЕНО

**Статус:** `insertId` вече използва `INSERT ... RETURNING \`id\`` вместо `SELECT MAX`. BaraDB поддържа `RETURNING` — проверено в lexer/parser.

---

### 3. Schema Builder — Column Type Mapping ✅ ИЗПРАВЕНО

**Статус:** Пълен `RdbTypeKind` → SQL mapping е имплементиран в `create_column_query.nim` (~350 реда):
- `rdbIncrements` → `SERIAL PRIMARY KEY`
- `rdbInteger` → `INTEGER` (+ auto-increment → `SERIAL`)
- `rdbBigInteger` → `BIGINT` (+ auto-increment → `BIGSERIAL`)
- `rdbBoolean` → `BOOLEAN`
- `rdbString(n)` → `VARCHAR(n)` (default 255)
- `rdbText` → `TEXT`
- `rdbFloat` → `REAL`
- `rdbDouble` → `DOUBLE PRECISION`
- `rdbDecimal(p,s)` → `DECIMAL(p,s)`
- `rdbDate` → `DATE`
- `rdbDateTime` / `rdbTimestamp` → `TIMESTAMP`
- `rdbTime` → `TIME`
- `rdbBinary` → `BYTEA`
- `rdbUuid` → `UUID`
- `rdbJson` → `JSON`
- `rdbEnumField` → `VARCHAR(255)`
- `rdbForeign` → `INTEGER` + `REFERENCES ... ON DELETE ...`
- `rdbStrForeign` → `VARCHAR(255)` + `REFERENCES ... ON DELETE ...`
- `rdbTimestamps` → `created_at` + `updated_at`
- `rdbSoftDelete` → `deleted_at`

`create_table.nim`, `add_column.nim`, `change_column.nim` вече използват `createColumnString`.

---

### 4. SQL Quoting Inconsistency ✅ ИЗПРАВЕНО

**Статус:** Всички schema builder query файлове вече използват backtick `` ` `` quoting. `create_migration_table.nim` беше поправен.

---

### 5. rename_column / rename_table bug ✅ ИЗПРАВЕНО

**Статус:** `changeTo` → `previousName` в `rename_column.nim` и `rename_table.nim`.

---

### 6. whereNull Bug ✅ ИЗПРАВЕНО

**Статус:** `whereNull` вече добавя `"symbol": "is"` в JSON обекта.

---

### 7. Database URL Support — липсва

PostgreSQL/MySQL/MariaDB драйверите поддържат `databaseUrl = asDatabaseUrl("postgresql://...")`. BaraDB `dbOpen` приема само позиционни параметри.

```
Файл: baradb_open.nim
- [ ] Парсване на `baradb://user:pass@host:port/db` URL
- [ ] Интеграция с `libs/database_url.nim`
```

---

### 8. Paginate / fastPaginate — липсват

Налични в други драйвери, липсват в BaraDB query builder.

```
Файл: baradb_exec.nim
- [ ] paginate(page, perPage): seq[JsonNode] + metadata
- [ ] fastPaginate(key, perPage): cursor-based
```

---

### 9. Schema utils checksum

```
Файл: schema_utils.nim
- [ ] shouldRun() — checksum-based skip (вместо винаги true)
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
| 1 | Schema Builder column mapping | Средна | Без него migrations не работят | ✅ ГОТОВО |
| 2 | INSERT RETURNING id | Ниска | Премахва race condition | ✅ ГОТОВО |
| 3 | Prepared Statements | Висока | Security + performance | **СРЕДЕН** |
| 4 | Database URL support | Ниска | UX удобство | **НИСЪК** |
| 5 | Paginate / fastPaginate | Ниска | Feature parity | **НИСЪК** |
| 6 | whereNull fix | Ниска | Bug fix | ✅ ГОТОВО |
| 7 | SQL quoting консистентност | Ниска | Потенциален runtime error | ✅ ГОТОВО |
| 8 | rename_column / rename_table bug | Ниска | Bug fix | ✅ ГОТОВО |
| 9 | Schema utils checksum | Ниска | Migration skip optimization | **НИСЪК** |

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
│   │   ├── create_table.nim         # CREATE TABLE ✅
│   │   ├── add_column.nim           # ADD COLUMN ✅
│   │   ├── change_column.nim        # ALTER COLUMN ✅
│   │   ├── drop_column.nim          # DROP COLUMN (8 реда) ✅
│   │   ├── drop_table.nim           # DROP TABLE (7 реда) ✅
│   │   ├── rename_column.nim        # RENAME COLUMN ✅
│   │   ├── rename_table.nim         # RENAME TABLE ✅
│   │   ├── reset_table.nim          # DELETE FROM (7 реда) ✅
│   │   ├── create_migration_table.nim ✅
│   │   ├── schema_utils.nim         # shouldRun (12 реда) ⚠️ always true
│   │   └── sub/
│   │       ├── create_column_query.nim  # ✅ пълен mapping
│   │       ├── add_column_query.nim     # ✅
│   │       └── change_column_query.nim  # ✅
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

### ✅ Седмица 1: Schema Builder + Bug fixes — ИЗПЪЛНЕНО
1. ~~`sub/create_column_query.nim` — пълен RdbTypeKind → SQL mapping~~ ✅
2. ~~`create_table.nim` — да използва column query вместо raw тип~~ ✅
3. ~~Fix `whereNull` bug в `baradb_query.nim`~~ ✅
4. ~~Fix quoting inconsistency в `create_migration_table.nim`~~ ✅
5. ~~Fix `rename_column.nim` / `rename_table.nim` ако `changeTo` не съществува~~ ✅

### ✅ Седмица 2: INSERT RETURNING — ИЗПЪЛНЕНО
1. ~~`insertId` — проучване дали BaraDB поддържа RETURNING, имплементация~~ ✅

### Седмица 3: Prepared Statements + Тестове
1. `prepare()` / `ensureStmt()` — prepared statement кеш
2. `preparedGet()` / `preparedExec()` — изпълнение през `mkQueryParams`
3. `test_prepared_statement.nim` — prepared statement тестове
4. `test_schema.nim` — schema builder тестове
5. `test_transaction.nim` — transaction тестове
6. `test_pool_wait.nim` — pool timeout тестове

### Седмица 4: Polish
1. Database URL support
2. Paginate / fastPaginate
3. Schema utils checksum
4. Документация в `documents/`
