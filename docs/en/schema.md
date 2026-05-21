# Schema System

BaraDB uses a schema-first design with type inheritance and automatic migrations.

## Defining Types

```nim
import barabadb/schema/schema

var s = newSchema()

let person = newType("Person")
person.addProperty("name", "str", required = true)
person.addProperty("age", "int32")
s.addType("default", person)
```

## Type Inheritance

```nim
let employee = newType("Employee")
employee.setBases(@["Person"])
employee.addProperty("department", "str")
s.addType("default", employee)

# Resolve inheritance — Employee gets name, age, department
let resolved = s.resolveInheritance(employee)
```

## Schema Operations

### Diff

Compare two schemas:

```nim
let diff = s.diff(oldSchema, newSchema)
```

### Migrations

Schema changes are tracked and can generate migration scripts.

## SQL Migrations

BaraDB supports SQL-level migrations executed through BaraQL:

```sql
-- Create a migration table
CREATE MIGRATION TABLE my_migration;

-- Apply pending migrations
MIGRATION UP;

-- Rollback last migration
MIGRATION DOWN;

-- Apply all pending migrations in batch
MIGRATION UP BATCH;

-- Dry-run to preview changes
MIGRATION DRYRUN;

-- Check migration status
MIGRATION STATUS;
```

Migration scripts are stored inside each database's LSMTree and are isolated per database. When using multiple databases, run `USE DATABASE <name>` before executing migration commands.

## Property Types

| Type | Description |
|------|-------------|
| `str` | String |
| `int32` | 32-bit integer |
| `int64` | 64-bit integer |
| `float32` | 32-bit float |
| `float64` | 64-bit float |
| `bool` | Boolean |
| `datetime` | Date/time value |
| `bytes` | Binary data |