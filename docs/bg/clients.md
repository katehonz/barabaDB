# Client SDKs

BaraDB предоставя официални клиентски библиотеки за JavaScript/TypeScript, Python, Nim и Rust.

## JavaScript / TypeScript

### Инсталация

```bash
npm install baradb
# или
yarn add baradb
```

### Основна Употреба

```typescript
import { Client } from 'baradb';

const client = new Client('localhost', 9472);
await client.connect();

// Проста заявка
const result = await client.query('SELECT name, age FROM users WHERE age > 18');
console.log(result.rows);

// Параметризирана заявка
const result2 = await client.query(
  'SELECT * FROM users WHERE name = ?',
  ['Alice']
);

// Batch вмъкване
await client.batch([
  "INSERT users { name := 'Alice', age := 30 }",
  "INSERT users { name := 'Bob', age := 25 }",
]);

// Транзакции
await client.begin();
await client.query("INSERT orders { total := 100 }");
await client.query("UPDATE users SET balance = balance - 100 WHERE name = 'Alice'");
await client.commit();

await client.close();
```

### Конкурентни Заявки

JavaScript клиентът автоматично сериализира конкурентни заявки през една TCP връзка чрез вътрешна опашка. Можете безопасно да изпращате множество паралелни операции — техните бинарни frame-ове няма да се размесят:

```typescript
const [users, orders, stats] = await Promise.all([
  client.query('SELECT * FROM users'),
  client.query('SELECT * FROM orders'),
  client.query('SELECT count(*) FROM visits')
]);
```

### WebSocket Стрийминг

```typescript
import { WebSocketClient } from 'baradb/ws';

const ws = new WebSocketClient('ws://localhost:9471');
ws.onMessage = (data) => console.log(data);
await ws.connect();
await ws.send('SUBSCRIBE updates');
```

## Python

### Инсталация

```bash
pip install baradb
```

### Основна Употреба

```python
from baradb import Client

client = Client("localhost", 9472)
client.connect()

# Проста заявка
result = client.query("SELECT name, age FROM users WHERE age > 18")
for row in result:
    print(row["name"], row["age"])

# Параметризирана заявка
result = client.query(
    "SELECT * FROM users WHERE name = ?",
    ["Alice"]
)

# Batch операции
client.batch([
    "INSERT users { name := 'Alice', age := 30 }",
    "INSERT users { name := 'Bob', age := 25 }",
])

# Context manager (автоматично затваряне)
with Client("localhost", 9472) as c:
    result = c.query("SELECT count(*) FROM users")
    print(result[0]["count"])
```

### Async Клиент

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

## Nim (Вграден Режим)

### Добавяне на Зависимост

```nim
# Във вашия .nimble файл
requires "barabadb >= 1.1.0"
```

### Вградена Употреба

```nim
import barabadb/storage/lsm
import barabadb/storage/btree
import barabadb/vector/engine
import barabadb/graph/engine

# Key-Value store
var db = newLSMTree("./data")
db.put("user:1", cast[seq[byte]]("Alice"))
let (found, value) = db.get("user:1")
db.close()

# B-Tree индекс
var btree = newBTreeIndex[string, int]()
btree.insert("Alice", 30)
let ages = btree.get("Alice")

# Векторно търсене
var idx = newHNSWIndex(dimensions = 128)
idx.insert(1, @[0.1'f32, 0.2, 0.3], {"category": "A"}.toTable)
let results = idx.search(@[0.1'f32, 0.2, 0.3], k = 10)

# Графи
var g = newGraph()
let alice = g.addNode("Person", {"name": "Alice"}.toTable)
let bob = g.addNode("Person", {"name": "Bob"}.toTable)
discard g.addEdge(alice, bob, "knows")
let path = g.shortestPath(alice, bob)
```

### Клиентска Библиотека

```nim
import barabadb/client/client

var c = newBaraClient("localhost", 9472)
c.connect()
let result = c.query("SELECT name FROM users")
for row in result.rows:
  echo row["name"]
c.close()
```

## Rust

### Добавяне на Зависимост

```toml
[dependencies]
baradb = "0.1"
tokio = { version = "1", features = ["full"] }
```

### Основна Употреба

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

## HTTP/REST (Езиково Независим)

Всички езици могат да използват HTTP/REST API директно:

```bash
# Заявка
curl -X POST http://localhost:9470/api/query \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"query": "SELECT * FROM users WHERE age > 18"}'

# Вмъкване
curl -X POST http://localhost:9470/api/query \
  -H "Content-Type: application/json" \
  -d '{"query": "INSERT users { name := \"Alice\", age := 30 }"}'

# Схема
curl http://localhost:9470/api/schema

# Health
curl http://localhost:9470/health

# Метрики
curl http://localhost:9470/metrics
```

## Connection Pooling

Всички официални клиенти поддържат connection pooling:

### JavaScript

```typescript
import { Pool } from 'baradb';

const pool = new Pool({
  host: 'localhost',
  port: 9472,
  min: 5,
  max: 50,
  idleTimeout: 30000,
});

const client = await pool.acquire();
try {
  const result = await client.query('SELECT 1');
} finally {
  pool.release(client);
}
```

### Python

```python
from baradb import Pool

pool = Pool("localhost", 9472, min_size=5, max_size=50)
with pool.connection() as conn:
    result = conn.query("SELECT 1")
```

## Съответствие на Типове Данни

| BaraDB Тип | JavaScript | Python | Nim | Rust |
|------------|------------|--------|-----|------|
| `null` | `null` | `None` | `nil` | `Option::None` |
| `bool` | `boolean` | `bool` | `bool` | `bool` |
| `int8/16/32/64` | `number` | `int` | `int` | `i8/i16/i32/i64` |
| `float32/64` | `number` | `float` | `float32/float64` | `f32/f64` |
| `str` | `string` | `str` | `string` | `String` |
| `bytes` | `Uint8Array` | `bytes` | `seq[byte]` | `Vec<u8>` |
| `array` | `Array` | `list` | `seq` | `Vec` |
| `object` | `Object` | `dict` | `Table` | `HashMap` |
| `vector` | `Float32Array` | `list[float]` | `seq[float32]` | `Vec<f32>` |
