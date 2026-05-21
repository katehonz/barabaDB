# Migrations & Data Import/Export

BaraDB has a built-in migration system via BaraQL. Migrations are fully managed
by the server — checksums, locking, rollback, and status tracking. The client
sends BaraQL commands and does not maintain its own migration table.

## BaraQL Migration Syntax

```sql
-- Create a migration with UP and DOWN scripts
CREATE MIGRATION add_users_table {
  UP: CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    email VARCHAR(255) UNIQUE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
  );
  DOWN: DROP TABLE IF EXISTS users;
}

-- Apply a specific migration
APPLY MIGRATION add_users_table

-- Apply all pending migrations
MIGRATION UP

-- Apply next N migrations
MIGRATION UP 3

-- Rollback last migration
MIGRATION DOWN

-- Rollback last N migrations
MIGRATION DOWN 2

-- View migration status
MIGRATION STATUS

-- Dry run (validate without executing)
MIGRATION DRY RUN add_users_table
```

## Migration Locking

BaraDB acquires a global migration lock before applying any migration. This
prevents concurrent migration runs and ensures:

- Only one migration runs at a time
- Checksums are verified before execution
- Failed migrations can be rolled back safely
- `MIGRATION STATUS` shows exact state of each migration

## Checksums

Every migration body is SHA-256 hashed. The server stores the checksum at
creation time and verifies it before applying. This prevents accidental
modification of already-registered migrations.

```
CREATE MIGRATION add_users → checksum: a3f2b8c1...
APPLY MIGRATION add_users → verifies checksum matches → executes
```

## Rollback

Migrations with `DOWN` scripts support rollback:

```sql
CREATE MIGRATION add_column {
  UP: ALTER TABLE users ADD COLUMN phone VARCHAR(20);
  DOWN: ALTER TABLE users DROP COLUMN phone;
}
```

When you run `MIGRATION DOWN`, the server executes the DOWN script and marks
the migration as rolled back.

## Dry Run

Validate a migration before applying:

```sql
MIGRATION DRY RUN add_users_table
-- Output:
-- DRY RUN add_users_table:
--   Statements: 1
--   [1] nkCreateTable
--   DOWN script: yes
--   Checksum: a3f2b8c1d4e5f6a7b8c9d0e1f2a3b4c5
```

---

## IMPORT FROM / EXPORT TO

BaraDB supports importing and exporting data directly via BaraQL.

### IMPORT FROM

```sql
-- Import from CSV
IMPORT FROM '/data/users.csv' INTO users
  FORMAT CSV
  DELIMITER ','
  HEADER true
  BATCH 1000

-- Import from JSON array
IMPORT FROM '/data/users.json' INTO users
  FORMAT JSON

-- Import from NDJSON (newline-delimited JSON)
IMPORT FROM '/data/users.ndjson' INTO users
  FORMAT NDJSON
```

Options:
| Option | Values | Default | Description |
|--------|--------|---------|-------------|
| `FORMAT` | `CSV`, `JSON`, `NDJSON` | `CSV` | Input file format |
| `DELIMITER` | any char | `,` | CSV field delimiter |
| `HEADER` | `true`/`false` | `true` | CSV first row is header |
| `BATCH` | integer | `1000` | Rows per insert batch |

### EXPORT TO

```sql
-- Export to CSV
EXPORT TO '/backup/users.csv' FROM users
  FORMAT CSV
  DELIMITER ','
  HEADER true

-- Export to JSON
EXPORT TO '/backup/users.json' FROM users
  FORMAT JSON

-- Export to NDJSON
EXPORT TO '/backup/users.ndjson' FROM users
  FORMAT NDJSON
```

---

## Cross-Database Migration

BaraDB's Nim client (nim-allographer) includes a cross-database migration
engine. Migrate data from PostgreSQL, MySQL, MariaDB, SQLite, or SurrealDB
directly to BaraDB.

### Supported Sources

| Database | Schema Extraction | Status |
|----------|-------------------|--------|
| PostgreSQL | `information_schema` | ✅ |
| MySQL | `information_schema` | ✅ |
| MariaDB | `information_schema` | ✅ |
| SQLite | `sqlite_master` + `PRAGMA` | ✅ |
| SurrealDB | `INFO FOR DB` / `INFO FOR TABLE` | ✅ |

### Nim API

```nim
import allographer/migrate_data

# Connect to source and target
let pg = dbOpen(PostgreSQL, "sourcedb", "user", "pass", "localhost", 5432)
let bdb = dbOpen(Baradb, "targetdb", "admin", "", "127.0.0.1", 9472)

# Migrate all tables
let report = waitFor migrate(pg, bdb, batchSize = 5000)
echo report
# Migration: PostgreSQL → BaraDB
#   Tables: 12/12
#   Rows:   45230
#   Time:   3.2s

# Migrate specific tables
let report = waitFor migrate(pg, bdb,
  tables = @["users", "orders", "products"])
```

### Type Mapping

The migration engine automatically maps source types to BaraDB equivalents:

| PostgreSQL | MySQL | SQLite | BaraDB |
|------------|-------|--------|--------|
| `SERIAL` | `INT AUTO_INCREMENT` | `INTEGER PK` | `SERIAL` |
| `VARCHAR(n)` | `VARCHAR(n)` | `TEXT` | `VARCHAR(n)` |
| `TEXT` | `TEXT` | `TEXT` | `TEXT` |
| `BOOLEAN` | `TINYINT(1)` | `INTEGER` | `BOOLEAN` |
| `JSONB` | `JSON` | `TEXT` | `JSON` |
| `TIMESTAMP` | `DATETIME` | `TEXT` | `TIMESTAMP` |
| `UUID` | `CHAR(36)` | `TEXT` | `UUID` |

Full type map: 50+ types supported.

---

## Nim allographer Client API

### Migration Management

```nim
import allographer/query_builder/models/baradb/baradb_exec

# Create migration
let qr = waitFor rdb.createMigration("add_products",
  "CREATE TABLE products (id SERIAL PRIMARY KEY, name VARCHAR(255))",
  "DROP TABLE IF EXISTS products")

# Apply
let qr = waitFor rdb.applyMigration("add_products")

# Apply all pending
let qr = waitFor rdb.migrateUp()

# Rollback
let qr = waitFor rdb.migrateDown(1)

# Status
let status = waitFor rdb.migrationStatus()

# Check if applied
if waitFor rdb.isMigrationApplied("add_products"):
  echo "Already applied"

# Dry run
let qr = waitFor rdb.migrationDryRun("add_products")
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
# Offset-based
let page = waitFor rdb.table("users").paginate(page = 1, perPage = 20)

# Cursor-based (faster for large tables)
let batch = waitFor rdb.table("users")
  .fastPaginate("id", perPage = 100, afterId = "42")
```

---

## Best Practices

1. **Always include DOWN scripts** — enables safe rollback
2. **Use dry run first** — validate migrations before applying in production
3. **Batch large imports** — use `BATCH 1000` for CSV imports to avoid memory issues
4. **Export before migration** — backup data with `EXPORT TO` before cross-DB migration
5. **Check status after migration** — verify with `MIGRATION STATUS`
6. **Migrate tables without foreign keys first** — then tables with foreign keys
