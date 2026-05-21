# План: Миграционна система + Data Migration Engine

## Архитектурен проблем

BaraDB сървърът има пълна BaraQL миграционна система:
```sql
CREATE MIGRATION name { UP: ...; DOWN: ...; }
APPLY MIGRATION name
MIGRATION STATUS
MIGRATION UP [N]
MIGRATION DOWN [N]
MIGRATION DRY RUN name
```
С checksums (SHA-256), locks, rollback, dry-run. Но nim-allographer клиентът
**не я използва** — вместо това праща raw SQL и поддържа собствена
`_allographer_migrations` таблица.

## Решение

Унифициране: клиентът да изпраща BaraQL миграционни команди към сървъра,
вместо да емулира миграции с raw SQL. Сървърът вече знае как да валидира,
lock-ва, и track-ва миграциите.

---

## Фаза 1: Свързване на клиента със сървърната BaraQL миграционна система [В ПРОГРЕС]

### 1.1 `baradb_client.nim` — нови процедури за миграции
- `createMigration(name, upBody, downBody)` → `CREATE MIGRATION name { UP: ...; DOWN: ...; }`
- `applyMigration(name)` → `APPLY MIGRATION name`
- `migrateUp(count)` → `MIGRATION UP [N]`
- `migrateDown(count)` → `MIGRATION DOWN [N]`
- `migrationStatus()` → `MIGRATION STATUS` (връща QueryResult)
- `migrationDryRun(name)` → `MIGRATION DRY RUN name`

Имплементация: конструират BaraQL стринг и го пращат през съществуващия `query()`.

### 1.2 `baradb_exec.nim` — high-level migration API + prepared statements
- `createMigration(rdb, name, upBody, downBody)` — convenience wrapper
- `applyMigration(rdb, name)` — с връщане на резултат
- `migrateUp(rdb, count=0)` — batch apply
- `migrateDown(rdb, count=1)` — rollback
- `migrationStatus(rdb)` → `seq[JsonNode]`
- **Prepared Statements:** `prepare()`, `ensureStmt()`, `preparedGet()`, `preparedExec()`, `withConn()`

### 1.3 `schema_utils.nim` — checksum-based shouldRun
- `shouldRun()` → изпраща `MIGRATION STATUS` и проверява дали миграцията е applied
- `execThenSaveHistory()` → използва `CREATE MIGRATION` + `MIGRATION UP`

### 1.4 `create_migration_table.nim` — опростяване
- Сървърът поддържа migration state в LSM-Tree (`_schema:migration:*`)
- Клиентската `_allographer_migrations` таблица вече не е нужна за BaraDB

---

## Фаза 2: Prepared Statements (от стар план, Седмица 3)

### 2.1 `baradb_exec.nim` — prepared statement API
- `prepare(sql)` → `BaradbPreparedStatement`
- `ensureStmt(conn, sql, nArgs)` → кеширане в preparedCache
- `preparedGet(stmt, args)` → използва mkQueryParams
- `preparedExec(stmt, args)` → execute през mkQueryParams
- `withConn(pool, callback)` → context-based connection
- `flushStmt(stmt)`, `clearStmtCache()`

### 2.2 Сигурност
- Премахване на client-side string interpolation за параметризирани заявки
- Всички параметризирани заявки да минават през `mkQueryParams`

---

## Фаза 3: Cross-DB Migration Engine — нов модул `migrate_data.nim`

### 3.1 Schema extraction от source база
- `extractSchema(rdb)` → `TableDef[]` за PostgreSQL/MySQL/SQLite/MariaDB/SurrealDB
- Четене от `information_schema` (или еквивалент)

### 3.2 Type mapping
- Source тип → BaraDB тип
- Мапване на constraints (PK, FK, UNIQUE, NOT NULL, DEFAULT)

### 3.3 DDL генератор
- Генерира `CREATE MIGRATION` скриптове с UP/DOWN за всяка таблица
- Запазва foreign key зависимости (order на таблиците)

### 3.4 Batch data transfer
- `transferTable(source, target, tableName, batchSize=1000)`
- Четене на batch от source → bulk insert в BaraDB
- Progress reporting, resume от последния успешен batch

### 3.5 CLI команда
```
allographer migrate \
  --from postgres://user:pass@host:5432/db \
  --to baradb://user:pass@host:9876/db \
  [--tables users,orders,products] \
  [--batch-size 5000] \
  [--dry-run]
```

---

## Фаза 4: BaraDB сървър — подобрения за миграция

### 4.1 `IMPORT FROM` синтаксис в BaraQL
### 4.2 `EXPORT TO` синтаксис в BaraQL
### 4.3 Bulk Insert оптимизация

---

## Фаза 5: Database URL + Paginate + Polish (от стар план)

### 5.1 Database URL support — `baradb://user:pass@host:port/db`
### 5.2 Paginate / fastPaginate

---

## Фаза 6: Тестове и документация

### 6.1 Липсващи тестове за BaraDB (от стар план)
- `test_prepared_statement.nim`, `test_schema.nim`, `test_create_schema.nim`
- `test_pool_wait.nim`, `test_transaction.nim`

### 6.2 Нови тестове за миграция
- `test_migration_create.nim`, `test_migration_up_down.nim`
- `test_cross_db_migration.nim`

### 6.3 Документация
- `documents/migration.md`

---

## Прогрес

| Фаза | Статус | Дата |
|------|--------|------|
| 1. Унификация | ✅ ГОТОВО | 2026-05-21 |
| 2. Prepared Statements | ✅ ГОТОВО | 2026-05-21 |
| 3. Cross-DB Engine | ✅ ГОТОВО | 2026-05-21 |
| 4. IMPORT/EXPORT | ✅ ГОТОВО | 2026-05-21 |
| 5. DB URL + Paginate | ✅ ГОТОВО | 2026-05-21 |
| 6. Тестове + Докум. | ✅ ГОТОВО | 2026-05-21 |
