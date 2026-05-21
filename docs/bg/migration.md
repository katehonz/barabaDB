# Миграции и Импорт/Експорт на Данни

BaraDB има вградена миграционна система чрез BaraQL. Миграциите се управляват
изцяло от сървъра — checksums, locking, rollback и проследяване на статуса.
Клиентът изпраща BaraQL команди и не поддържа собствена миграционна таблица.

## BaraQL Синтаксис за Миграции

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

-- Отмяна на последната миграция
MIGRATION DOWN

-- Отмяна на последните N миграции
MIGRATION DOWN 2

-- Преглед на статуса
MIGRATION STATUS

-- Dry run (валидация без изпълнение)
MIGRATION DRY RUN add_users_table
```

## Заключване при Миграция

BaraDB заключва глобално преди прилагане на миграция, което предотвратява
конкурентно изпълнение и осигурява:

- Само една миграция се изпълнява в даден момент
- Checksums се проверяват преди изпълнение
- Неуспешните миграции могат да се върнат безопасно
- `MIGRATION STATUS` показва точното състояние на всяка миграция

## Checksums

Тялото на всяка миграция се хешира с SHA-256. Сървърът съхранява checksum
при създаване и го проверява преди прилагане.

```
CREATE MIGRATION add_users → checksum: a3f2b8c1...
APPLY MIGRATION add_users → проверява checksum → изпълнява
```

## Връщане (Rollback)

Миграциите с `DOWN` скриптове поддържат връщане:

```sql
CREATE MIGRATION add_column {
  UP: ALTER TABLE users ADD COLUMN phone VARCHAR(20);
  DOWN: ALTER TABLE users DROP COLUMN phone;
}
```

`MIGRATION DOWN` изпълнява DOWN скрипта и маркира миграцията като върната.

## Dry Run

Валидирайте миграция преди прилагане:

```sql
MIGRATION DRY RUN add_users_table
-- Изход:
-- DRY RUN add_users_table:
--   Statements: 1
--   [1] nkCreateTable
--   DOWN script: yes
--   Checksum: a3f2b8c1d4e5f6a7b8c9d0e1f2a3b4c5
```

---

## IMPORT FROM / EXPORT TO

BaraDB поддържа импорт и експорт на данни директно чрез BaraQL.

### IMPORT FROM

```sql
-- Импорт от CSV
IMPORT FROM '/data/users.csv' INTO users
  FORMAT CSV
  DELIMITER ','
  HEADER true
  BATCH 1000

-- Импорт от JSON масив
IMPORT FROM '/data/users.json' INTO users
  FORMAT JSON

-- Импорт от NDJSON
IMPORT FROM '/data/users.ndjson' INTO users
  FORMAT NDJSON
```

Опции:
| Опция | Стойности | По подр. | Описание |
|--------|-----------|----------|----------|
| `FORMAT` | `CSV`, `JSON`, `NDJSON` | `CSV` | Формат на входния файл |
| `DELIMITER` | произволен знак | `,` | Разделител за CSV |
| `HEADER` | `true`/`false` | `true` | Първият ред на CSV е заглавен |
| `BATCH` | цяло число | `1000` | Редове на партида |

### EXPORT TO

```sql
-- Експорт към CSV
EXPORT TO '/backup/users.csv' FROM users
  FORMAT CSV
  DELIMITER ','
  HEADER true

-- Експорт към JSON
EXPORT TO '/backup/users.json' FROM users
  FORMAT JSON

-- Експорт към NDJSON
EXPORT TO '/backup/users.ndjson' FROM users
  FORMAT NDJSON
```

---

## Миграция между Бази Данни

Nim клиентът на BaraDB (nim-allographer) включва engine за миграция между
различни бази данни. Мигрирайте данни от PostgreSQL, MySQL, MariaDB, SQLite
или SurrealDB директно към BaraDB.

### Поддържани Източници

| База Данни | Извличане на Схема | Статус |
|------------|-------------------|--------|
| PostgreSQL | `information_schema` | ✅ |
| MySQL | `information_schema` | ✅ |
| MariaDB | `information_schema` | ✅ |
| SQLite | `sqlite_master` + `PRAGMA` | ✅ |
| SurrealDB | `INFO FOR DB` / `INFO FOR TABLE` | ✅ |

### Nim API

```nim
import allographer/migrate_data

# Свързване към източник и цел
let pg = dbOpen(PostgreSQL, "sourcedb", "user", "pass", "localhost", 5432)
let bdb = dbOpen(Baradb, "targetdb", "admin", "", "127.0.0.1", 9472)

# Мигриране на всички таблици
let report = waitFor migrate(pg, bdb, batchSize = 5000)
echo report
# Migration: PostgreSQL → BaraDB
#   Tables: 12/12
#   Rows:   45230
#   Time:   3.2s

# Мигриране на конкретни таблици
let report = waitFor migrate(pg, bdb,
  tables = @["users", "orders", "products"])
```

### Съответствие на Типове

Миграционният engine автоматично мапва типовете:

| PostgreSQL | MySQL | SQLite | BaraDB |
|------------|-------|--------|--------|
| `SERIAL` | `INT AUTO_INCREMENT` | `INTEGER PK` | `SERIAL` |
| `VARCHAR(n)` | `VARCHAR(n)` | `TEXT` | `VARCHAR(n)` |
| `TEXT` | `TEXT` | `TEXT` | `TEXT` |
| `BOOLEAN` | `TINYINT(1)` | `INTEGER` | `BOOLEAN` |
| `JSONB` | `JSON` | `TEXT` | `JSON` |
| `TIMESTAMP` | `DATETIME` | `TEXT` | `TIMESTAMP` |
| `UUID` | `CHAR(36)` | `TEXT` | `UUID` |

Пълна карта: 50+ поддържани типа.

---

## Nim allographer API

### Управление на Миграции

```nim
import allographer/query_builder/models/baradb/baradb_exec

# Създаване
let qr = waitFor rdb.createMigration("add_products",
  "CREATE TABLE products (id SERIAL PRIMARY KEY, name VARCHAR(255))",
  "DROP TABLE IF EXISTS products")

# Прилагане
let qr = waitFor rdb.applyMigration("add_products")
let qr = waitFor rdb.migrateUp()  # всички неприложени
let qr = waitFor rdb.migrateDown(1)  # връщане

# Статус
let status = waitFor rdb.migrationStatus()
if waitFor rdb.isMigrationApplied("add_products"):
  echo "Вече е приложена"
```

### Prepared Statements

```nim
let stmt = waitFor rdb.prepare(
  "SELECT * FROM users WHERE age > ? AND status = ?", nArgs = 2)

let results = waitFor stmt.preparedGet(@[
  WireValue(kind: fkInt32, int32Val: 18),
  WireValue(kind: fkString, strVal: "active")
])

stmt.flushStmt()
rdb.clearStmtCache()
```

### Pagination

```nim
# Offset-базирана
let page = waitFor rdb.table("users").paginate(page = 1, perPage = 20)

# Cursor-базирана (по-бърза за големи таблици)
let batch = waitFor rdb.table("users")
  .fastPaginate("id", perPage = 100, afterId = "42")
```

---

## Най-добри Практики

1. **Винаги включвайте DOWN скриптове** — позволява безопасно връщане
2. **Първо dry run** — валидирайте преди прилагане в production
3. **Партиден импорт** — използвайте `BATCH 1000` за CSV импорт
4. **Експортирайте преди миграция** — backup с `EXPORT TO`
5. **Проверка след миграция** — `MIGRATION STATUS`
6. **Първо таблици без foreign keys** — после тези с foreign keys
