# Клиентские SDK

BaraDB предоставляет официальные клиентские библиотеки для JavaScript/TypeScript, Python, Nim и Rust.

## JavaScript / TypeScript

### Установка

```bash
npm install baradb
```

### Основное использование

```typescript
import { Client } from 'baradb';

const client = new Client('localhost', 9472);
await client.connect();

const result = await client.query('SELECT name, age FROM users WHERE age > 18');
console.log(result.rows);
```

## Python

### Установка

```bash
pip install baradb
```

### Основное использование

```python
from baradb import Client

client = Client("localhost", 9472)
client.connect()

result = client.query("SELECT name, age FROM users WHERE age > 18")
for row in result:
    print(row["name"], row["age"])
```

## Nim (Встраиваемый режим)

```nim
import barabadb/storage/lsm

var db = newLSMTree("./data")
db.put("user:1", cast[seq[byte]]("Alice"))
let (found, value) = db.get("user:1")
db.close()
```

## Rust

```rust
use baradb::Client;

let mut client = Client::connect("localhost:9472").await?;
let result = client.query("SELECT name, age FROM users").await?;
```

## HTTP/REST (для любого языка)

```bash
curl -X POST http://localhost:9470/api/query \
  -H "Content-Type: application/json" \
  -d '{"query": "SELECT * FROM users"}'
```

## Сопоставление типов данных

| BaraDB | JavaScript | Python | Nim | Rust |
|--------|------------|--------|-----|------|
| `null` | `null` | `None` | `nil` | `Option::None` |
| `bool` | `boolean` | `bool` | `bool` | `bool` |
| `int32` | `number` | `int` | `int` | `i32` |
| `float64` | `number` | `float` | `float64` | `f64` |
| `str` | `string` | `str` | `string` | `String` |