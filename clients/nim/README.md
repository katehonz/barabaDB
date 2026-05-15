# BaraDB Nim Client

Official Nim client for **BaraDB** — a multimodal database engine.

## Features

- **Binary wire protocol** — fast TCP communication via `asyncnet`
- **Async/await API** — non-blocking by default
- **Sync wrapper** — `SyncClient` for blocking code
- **Query builder** — fluent SQL construction
- **Zero server dependencies** — self-contained, uses only Nim stdlib

## Installation

Add to your `.nimble` file:

```nim
requires "baradb >= 1.1.0"
```

Or clone locally:

```bash
git clone https://codeberg.org/baraba/baradb
cd clients/nim
nimble develop
```

## Quick Start

### Async API

```nim
import asyncdispatch
import baradb/client

proc main() {.async.} =
  let client = newClient()
  await client.connect()
  let result = await client.query("SELECT name, age FROM users WHERE age > 18")
  echo result
  client.close()

waitFor main()
```

### Sync API

```nim
import baradb/client

let client = newSyncClient()
client.connect()
let result = client.query("SELECT name, age FROM users WHERE age > 18")
echo result
client.close()
```

### Parameterized Queries

```nim
import baradb/client

proc main() {.async.} =
  let client = newClient()
  await client.connect()
  let result = await client.query(
    "SELECT * FROM users WHERE age > $1",
    @[WireValue(kind: fkInt64, int64Val: 18)]
  )
  echo result
  client.close()

waitFor main()
```

### Query Builder

```nim
import baradb/client

proc main() {.async.} =
  let client = newClient()
  await client.connect()
  let result = await newQueryBuilder(client)
    .select("name", "email")
    .from("users")
    .where("active = true")
    .orderBy("name", "ASC")
    .limit(10)
    .exec()
  echo result
  client.close()

waitFor main()
```

## Running Tests

Unit tests (no server):

```bash
nimble test
```

Integration tests (requires server on `localhost:9472`):

```bash
# Start server
docker run -d -p 9472:9472 baradb:latest

# Run integration tests
nim c -r tests/test_integration.nim
```

## API Reference

### `ClientConfig`

| Field        | Default     | Description            |
|--------------|-------------|------------------------|
| `host`       | `127.0.0.1` | Server hostname        |
| `port`       | `9472`      | TCP port               |
| `database`   | `default`   | Default database       |
| `username`   | `admin`     | Username               |
| `password`   | `""`        | Password               |
| `timeoutMs`  | `30000`     | Timeout in ms          |
| `maxRetries` | `3`         | Max reconnect retries  |

### Methods (Async)

- `connect()` — open TCP connection
- `close()` — close connection
- `query(sql)` — execute SELECT-like query
- `query(sql, params)` — parameterized query
- `exec(sql)` — execute DDL/DML, returns affected rows
- `auth(token)` — JWT authentication
- `ping()` — health check

### Methods (Sync)

Same as async but blocking. Available on `SyncClient`.

## License

Apache-2.0
