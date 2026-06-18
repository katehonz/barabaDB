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
requires "baradb >= 1.2.0"
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

## Connection Pool

```nim
import asyncdispatch, baradb/client, baradb/pool

proc main() {.async.} =
  let cfg = ClientConfig(host: "127.0.0.1", port: 9472)
  let pool = newBaraPool(cfg, minConnections = 2, maxConnections = 10)
  withClient(pool):
    let r = await c.query("SELECT name FROM users WHERE id = ?",
                          @[WireValue(kind: fkInt64, int64Val: 1)])
    echo r.typedRows

waitFor main()
```

## Typed Rows

`QueryResult` now carries both a legacy string view (`rows`) and a typed view (`typedRows`):

```nim
let r = await client.query("SELECT * FROM vectors")
for row in r.typedRows:
  if row[0].kind == fkVector:
    echo row[0].vecVal
```

## TLS

TLS for the synchronous client is available via `when defined(ssl)`. The async binary client requires a user-supplied `sslContext` because `asyncnet` does not provide native TLS; alternatively use the HTTP fallback.

## Error Handling

All client errors inherit from `BaraError`:

- `BaraIoError` — connection / timeout issues
- `BaraServerError` — server returned an error frame
- `BaraAuthError` — authentication failure
- `BaraProtocolError` — unexpected wire response
- `BaraPoolTimeoutError` — no connection available in time

## HTTP Fallback

For environments where only the HTTP port is open:

```nim
import asyncdispatch, baradb/http

proc main() {.async.} =
  let c = newBaraHttpClient()
  let result = await c.query("SELECT * FROM users")
  echo result
  c.close()

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

## Ormin Integration

The Nim client ships with an [Ormin](https://github.com/Araq/ormin) backend for compile-time checked SQL queries.

```nim
import ormin

importModel(DbBackend.baradb, "my_model")
let db {.global.} = open("127.0.0.1:9472", "admin", "", "default")

let rows = query:
  select users(id, name)
  where name == ?"alice"
```

See `examples/ormin_basic.nim` for a full sample.

## License

Apache-2.0
