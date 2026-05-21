# BaraDB Migration System — Ръководство

## Общ преглед

BaraDB има вградена миграционна система чрез BaraQL. Миграциите се управляват
изцяло от сървъра — checksums, locking, rollback, status tracking. Клиентът
(nim-allographer) изпраща BaraQL команди и не поддържа собствена миграционна
таблица.

## BaraQL миграционен синтаксис

```sql
-- Създаване на миграция с UP и DOWN скриптове
CREATE MIGRATION add_users_table {
  UP: CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    email VARCHAR(255) UNIQUE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
  );
  DOWN: DROP TABLE IF EXISTS users;
}

-- Прилагане на конкретна миграция
APPLY MIGRATION add_users_table

-- Прилагане на всички неприложени миграции
MIGRATION UP

-- Прилагане на следващите N миграции
MIGRATION UP 3

-- Отмяна на последната миграция (rollback)
MIGRATION DOWN

-- Отмяна на последните N миграции
MIGRATION DOWN 2

-- Преглед на статуса на всички миграции
MIGRATION STATUS

-- Dry run — проверка без изпълнение
MIGRATION DRY RUN add_users_table
```

## Nim API (nim-allographer)

### Свързване

```nim
import allographer/connection
import allographer/query_builder

# Стандартно свързване
let rdb = dbOpen(Baradb, "mydb", "admin", "", "127.0.0.1", 9472)

# Или чрез URL
let rdb = dbOpen(Baradb, asDatabaseUrl("baradb://admin@127.0.0.1:9472/mydb"))
```

### Управление на миграции

```nim
import allographer/query_builder/models/baradb/baradb_exec

# Създаване на миграция
let upSql = """
  CREATE TABLE products (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    price DECIMAL(10,2)
  )
"""
let downSql = "DROP TABLE IF EXISTS products"
let qr = waitFor rdb.createMigration("add_products", upSql, downSql)

# Прилагане на миграция
let qr = waitFor rdb.applyMigration("add_products")

# Прилагане на всички неприложени
let qr = waitFor rdb.migrateUp()

# Rollback
let qr = waitFor rdb.migrateDown(1)

# Проверка на статус
let status = waitFor rdb.migrationStatus()
for row in status:
  echo row["name"].getStr, " → ", row["status"].getStr

# Проверка дали миграция е приложена
if waitFor rdb.isMigrationApplied("add_products"):
  echo "Migration already applied"

# Dry run
let qr = waitFor rdb.migrationDryRun("add_products")
echo $qr
```

### Schema Builder (автоматични миграции)

```nim
import allographer/schema_builder
import allographer/query_builder

let rdb = dbOpen(Baradb, "mydb", "admin", "", "127.0.0.1", 9472)

# Дефиниране на таблица
let usersTable = table("users", [
  Column.increments("id"),
  Column.string("name"),
  Column.string("email").unique(),
  Column.integer("age").nullable(),
  Column.timestamps()
])

# Създаване (автоматично генерира CREATE MIGRATION)
rdb.create(usersTable)

# Промяна
let alteredTable = table("users", [
  Column.string("phone").nullable().add()  # добавяне на колона
])
rdb.alter(alteredTable)

# Изтриване
rdb.drop(usersTable)
```

### Prepared Statements

```nim
import allographer/query_builder/models/baradb/baradb_exec

# Подготовка на statement (кешира се)
let stmt = waitFor rdb.prepare(
  "SELECT * FROM users WHERE age > ? AND status = ?", nArgs = 2
)

# Изпълнение с параметри
let youngAdmins = waitFor stmt.preparedGet(@[
  WireValue(kind: fkInt32, int32Val: 18),
  WireValue(kind: fkString, strVal: "active")
])

# Execute (INSERT/UPDATE/DELETE)
let affected = waitFor stmt.preparedExec(@[
  WireValue(kind: fkInt32, int32Val: 21),
  WireValue(kind: fkString, strVal: "pending")
])

# Освобождаване
stmt.flushStmt()

# Изчистване на целия кеш
rdb.clearStmtCache()
```

### Pagination

```nim
# Offset-based
let page1 = waitFor rdb.table("users")
  .orderBy("id", Asc)
  .paginate(page = 1, perPage = 20)
echo page1.rows.len  # 20
echo page1.total     # 150
echo page1.hasMore   # true

# Cursor-based (по-бързо за големи таблици)
let batch = waitFor rdb.table("users")
  .fastPaginate("id", perPage = 100, afterId = "42")
echo batch.hasMore
```

---

## Cross-DB Migration Engine

Мигриране на данни от PostgreSQL, MySQL, MariaDB, SQLite или SurrealDB към BaraDB.

### Поддържани source бази

| База | Статус | Schema extraction |
|------|--------|-------------------|
| PostgreSQL | ✅ | `information_schema` |
| MySQL | ✅ | `information_schema` |
| MariaDB | ✅ | `information_schema` |
| SQLite | ✅ | `sqlite_master` + `PRAGMA` |
| SurrealDB | ✅ | `INFO FOR DB` / `INFO FOR TABLE` |

### API

```nim
import allographer/migrate_data

# Свързване към source и target
let pg = dbOpen(PostgreSQL, "sourcedb", "user", "pass", "localhost", 5432)
let bdb = dbOpen(Baradb, "targetdb", "admin", "", "127.0.0.1", 9472)

# Мигриране на всички таблици
let report = waitFor migrate(pg, bdb, batchSize = 5000)
echo report
# Migration: PostgreSQL → BaraDB
#   Tables: 12/12
#   Rows:   45230
#   Time:   3.2s

# Мигриране само на конкретни таблици
let report = waitFor migrate(pg, bdb, tables = @["users", "orders", "products"])
```

### Как работи

1. **Schema extraction** — чете структурата на таблиците от source базата
2. **Type mapping** — мапва типовете към BaraDB еквиваленти:
   - `SERIAL` → `SERIAL`
   - `VARCHAR(n)` → `VARCHAR(n)`
   - `TEXT` → `TEXT`
   - `JSONB` → `JSON`
   - `BOOLEAN` → `BOOLEAN`
   - и още 50+ типа
3. **DDL генерация** — създава `CREATE MIGRATION` с UP/DOWN скриптове
4. **Data transfer** — чете данни на batch-ове и ги вмъква в BaraDB
5. **Progress tracking** — връща `MigrationReport` с детайли

---

## IMPORT FROM / EXPORT TO (BaraQL)

```sql
-- Импорт от CSV
IMPORT FROM '/data/users.csv' INTO users
  FORMAT CSV
  DELIMITER ','
  HEADER true
  BATCH 1000

-- Импорт от JSON
IMPORT FROM '/data/users.json' INTO users
  FORMAT JSON

-- Импорт от NDJSON (newline-delimited JSON)
IMPORT FROM '/data/users.ndjson' INTO users
  FORMAT NDJSON

-- Експорт към CSV
EXPORT TO '/backup/users.csv' FROM users
  FORMAT CSV
  DELIMITER ','
  HEADER true

-- Експорт към JSON
EXPORT TO '/backup/users.json' FROM users
  FORMAT JSON
```

### Поддържани формати

| Формат | Import | Export | Опции |
|--------|--------|--------|-------|
| CSV | ✅ | ✅ | DELIMITER, HEADER, BATCH |
| JSON | ✅ | ✅ | — |
| NDJSON | ✅ | ✅ | — |

---

## Често задавани въпроси

### Мога ли да мигрирам от SQLite директно към BaraDB?

Да. Свържете се към SQLite файла и използвайте `migrate()`:

```nim
let sqlite = dbOpen(SQLite3, "mydb.sqlite")
let bdb = dbOpen(Baradb, "mydb", "admin", "", "127.0.0.1", 9472)
let report = waitFor migrate(sqlite, bdb)
```

### Какво става ако миграцията се прекъсне?

BaraDB сървърът поддържа transaction safety. Всяка миграция се изпълнява в
рамките на една транзакция. При грешка:
- DDL промените се отменят автоматично
- `MIGRATION STATUS` показва кои миграции са applied и кои не
- Може да продължите от последната успешна миграция

### Как да проверя какви миграции са приложени?

```nim
let status = waitFor rdb.migrationStatus()
for row in status:
  echo &"{row[\"name\"]} → {row[\"status\"]} ({row[\"applied_at\"]})"
```

Или чрез BaraQL:
```sql
MIGRATION STATUS
```

### Поддържат ли се foreign key зависимости при cross-DB миграция?

Да. `migrate_data.nim` запазва foreign key дефинициите в генерирания DDL.
Препоръчва се таблиците без foreign key зависимости да се мигрират първи.

### Как се прави backup преди миграция?

```sql
-- Експортирайте данните преди миграция
EXPORT TO '/backup/before_migration.csv' FROM users FORMAT CSV

-- Или използвайте backup manager-а
-- (backup restore list verify cleanup)
```
