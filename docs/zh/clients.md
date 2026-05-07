# 客户端 SDK

BaraDB 为 JavaScript/TypeScript、Python、Nim 和 Rust 提供官方客户端库。

## JavaScript / TypeScript

### 安装

```bash
npm install baradb
```

### 基本用法

```typescript
import { Client } from 'baradb';

const client = new Client('localhost', 9472);
await client.connect();

const result = await client.query('SELECT name, age FROM users WHERE age > 18');
```

## Python

### 安装

```bash
pip install baradb
```

### 基本用法

```python
from baradb import Client

client = Client("localhost", 9472)
client.connect()
result = client.query("SELECT name, age FROM users WHERE age > 18")
```

## Nim（嵌入式模式）

```nim
import barabadb/storage/lsm

var db = newLSMTree("./data")
db.put("key", cast[seq[byte]]("value"))
let (found, val) = db.get("key")
db.close()
```

## Rust

```rust
use baradb::Client;

let mut client = Client::connect("localhost:9472").await?;
```

## HTTP/REST

```bash
curl -X POST http://localhost:9470/api/query \
  -d '{"query": "SELECT * FROM users"}'
```