# Client SDKs

BaraDB provides official client libraries for JavaScript/TypeScript, Python, Nim, and Rust.

## JavaScript / TypeScript

### Installation

```bash
npm install baradb
# or
yarn add baradb
```

### Basic Usage

```typescript
import { Client } from 'baradb';

const client = new Client('localhost', 9472);
await client.connect();

// Simple query
const result = await client.query('SELECT name, age FROM users WHERE age > 18');
console.log(result.rows);

// Parameterized query
const result2 = await client.query(
  'SELECT * FROM users WHERE name = ?',
  ['Alice']
);

// Batch insert
await client.batch([
  "INSERT users { name := 'Alice', age := 30 }",
  "INSERT users { name := 'Bob', age := 25 }",
]);

// Transactions
await client.begin();
await client.query("INSERT orders { total := 100 }");
await client.query("UPDATE users SET balance = balance - 100 WHERE name = 'Alice'");
await client.commit();

await client.close();
```

### Concurrent Queries

The JavaScript client automatically serializes concurrent requests over a single TCP connection via an internal request queue. You can safely fire multiple parallel operations — their binary frames will not interleave on the wire:

```typescript
const [users, orders, stats] = await Promise.all([
  client.query('SELECT * FROM users'),
  client.query('SELECT * FROM orders'),
  client.query('SELECT count(*) FROM visits')
]);
```

### WebSocket Streaming

```typescript
import { WebSocketClient } from 'baradb/ws';

const ws = new WebSocketClient('ws://localhost:9471');
ws.onMessage = (data) => console.log(data);
await ws.connect();
await ws.send('SUBSCRIBE updates');
```

## Python

### Installation

```bash
pip install baradb
```

### Basic Usage

```python
from baradb import Client

client = Client("localhost", 9472)
client.connect()

# Simple query
result = client.query("SELECT name, age FROM users WHERE age > 18")
for row in result:
    print(row["name"], row["age"])

# Parameterized query
result = client.query(
    "SELECT * FROM users WHERE name = ?",
    ["Alice"]
)

# Batch operations
client.batch([
    "INSERT users { name := 'Alice', age := 30 }",
    "INSERT users { name := 'Bob', age := 25 }",
])

# Context manager (auto-close)
with Client("localhost", 9472) as c:
    result = c.query("SELECT count(*) FROM users")
    print(result[0]["count"])
```

### Async Client

```python
import asyncio
from baradb import AsyncClient

async def main():
    client = AsyncClient("localhost", 9472)
    await client.connect()
    result = await client.query("SELECT * FROM users")
    print(result.rows)
    await client.close()

asyncio.run(main())
```

## Nim

Install the official client:

```bash
nimble install baradb
```

### Async with connection pool

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

### Sync client

```nim
import baradb/client

let c = newSyncClient()
c.connect()
let r = c.query("SELECT * FROM users")
echo r.rows
c.close()
```

For Laravel-style query building, use `nim-allographer` with the `Baradb` driver.

## Rust

### Add Dependency

```toml
[dependencies]
baradb = "0.1"
tokio = { version = "1", features = ["full"] }
```

### Basic Usage

```rust
use baradb::Client;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut client = Client::connect("localhost:9472").await?;
    
    let result = client
        .query("SELECT name, age FROM users WHERE age > 18")
        .await?;
    
    for row in result.rows {
        println!("{} is {} years old", row["name"], row["age"]);
    }
    
    client.close().await?;
    Ok(())
}
```

## HTTP/REST (Language Agnostic)

All languages can use the HTTP/REST API directly:

```bash
# Query
curl -X POST http://localhost:9470/api/query \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"query": "SELECT * FROM users WHERE age > 18"}'

# Insert
curl -X POST http://localhost:9470/api/query \
  -H "Content-Type: application/json" \
  -d '{"query": "INSERT users { name := \"Alice\", age := 30 }"}'

# Schema
curl http://localhost:9470/api/schema

# Health
curl http://localhost:9470/health

# Metrics
curl http://localhost:9470/metrics
```

## Connection Pooling

All official clients support connection pooling:

### JavaScript
```typescript
import { Pool } from 'baradb';
const pool = new Pool({ host: 'localhost', port: 9472, min: 5, max: 50 });
```

### Python
```python
from baradb import Pool
pool = Pool("localhost", 9472, min_size=5, max_size=50)
```

## Cross-Database Migration (Nim)

The Nim allographer client includes a cross-database migration engine:

```nim
import allographer/migrate_data

let pg = dbOpen(PostgreSQL, "sourcedb", "user", "pass", "localhost", 5432)
let bdb = dbOpen(Baradb, "targetdb", "admin", "", "127.0.0.1", 9472)

let report = waitFor migrate(pg, bdb, batchSize = 5000)
echo report  # Tables: 12/12, Rows: 45230, Time: 3.2s
```

Supported sources: PostgreSQL, MySQL, MariaDB, SQLite, SurrealDB.
See [Migrations & Import/Export](migration.md) for details.

## Data Types Mapping

| BaraDB Type | JavaScript | Python | Nim | Rust |
|-------------|------------|--------|-----|------|
| `null` | `null` | `None` | `nil` | `Option::None` |
| `bool` | `boolean` | `bool` | `bool` | `bool` |
| `int8/16/32/64` | `number` | `int` | `int` | `i8/i16/i32/i64` |
| `float32/64` | `number` | `float` | `float32/float64` | `f32/f64` |
| `str` | `string` | `str` | `string` | `String` |
| `bytes` | `Uint8Array` | `bytes` | `seq[byte]` | `Vec<u8>` |
| `array` | `Array` | `list` | `seq` | `Vec` |
| `object` | `Object` | `dict` | `Table` | `HashMap` |
| `vector` | `Float32Array` | `list[float]` | `seq[float32]` | `Vec<f32>` |
