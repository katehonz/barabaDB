# Ormin + BaraDB

This is a fork of [Ormin](https://github.com/Araq/ormin) (prepared SQL statement generator for Nim) with added support for **BaraDB** — a multimodal database engine with a binary wire protocol.

## What changed?

- Added `DbBackend.baradb` to the backend enum.
- Added `ImportTarget.baradb` for schema import.
- New backend file `ormin/ormin_baradb.nim` that bridges Ormin's compile-time query DSL to the BaraDB Nim client (`baradb/client`).

## Installation

Install both the BaraDB client and this Ormin fork:

```bash
# Install BaraDB client (from barabadb/clients/nim)
cd clients/nim
nimble install

# Install Ormin with BaraDB support
cd ormin
nimble install
```

## Quick Start

### 1. Write your schema

Create a file named `model.sql`:

```sql
CREATE TABLE users (
  id SERIAL PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  email VARCHAR(255),
  age INT
);
```

### 2. Use Ormin DSL in Nim

```nim
import json
import ormin

importModel(DbBackend.baradb, "model")

let db {.global.} = open("127.0.0.1:9472", "admin", "", "default")

# Select tuples
proc listUsers() =
  let rows = query:
    select users(id, name, email)
    orderby id
  for r in rows:
    echo "User #", r.id, ": ", r.name

# Parameterized query
proc findUser(name: string) =
  let row = query:
    select users(id, name, email)
    where name == ?name
    limit 1
  echo row

# Insert
proc addUser(name, email: string; age: int) =
  query:
    insert users(name = ?name, email = ?email, age = ?age)

# JSON output
proc usersAsJson(): seq[JsonNode] =
  result = query:
    select users(id, name)
    produce json

when isMainModule:
  listUsers()
```

Compile with:

```bash
nim c -r myapp.nim
```

## Connection string format

`open(host:port, username, password, database)`

```nim
let db = open("127.0.0.1:9472", "admin", "", "default")
```

If you omit the port, the default `9472` is used.

## Supported Ormin features

| Feature             | Status |
|---------------------|--------|
| `select`            | ✅     |
| `where`             | ✅     |
| `join` / `leftjoin` | ✅     |
| `insert`            | ✅     |
| `update`            | ✅     |
| `delete`            | ✅     |
| `orderby`           | ✅     |
| `limit` / `offset`  | ✅     |
| `?` placeholders    | ✅     |
| `%` JSON params     | ✅     |
| `produce json`      | ✅     |
| `query(T)` typed    | ✅     |
| `createProc`        | ✅     |
| `createIter`        | ✅     |
| `transaction`       | ⚠️ (relies on server support) |
| `returning`         | ⚠️ (single-row limit works) |

## Limitations

- **Wire protocol strings**: BaraDB returns all column values as strings over the wire. The backend parses them at runtime. This is slightly less efficient than native SQLite/PostgreSQL bindings but keeps the implementation simple and portable.
- **`getLastId`**: Currently returns `0`. If BaraDB supports `RETURNING id`, use `limit 1` queries instead.
- **Async**: Ormin's DSL is synchronous by design. This backend uses `SyncClient` under the hood. If you need async, use the raw `baradb/client` async API directly.

## Running the example

```bash
cd clients/nim/ormin/examples
nim c -r baradb_basic.nim
```

*(Requires a BaraDB server on `localhost:9472`.)*

## License

Same as upstream Ormin — MIT.
