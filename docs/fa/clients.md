# SDK های کلاینت

BaraDB کتابخانه‌های کلاینت رسمی برای JavaScript/TypeScript، Python، Nim و Rust فراهم می‌کند.

## JavaScript / TypeScript

### نصب

```bash
npm install baradb
```

### استفاده پایه

```typescript
import { Client } from 'baradb';

const client = new Client('localhost', 9472);
await client.connect();

const result = await client.query('SELECT name, age FROM users WHERE age > 18');
```

## Python

### نصب

```bash
pip install baradb
```

### استفاده پایه

```python
from baradb import Client

client = Client("localhost", 9472)
client.connect()
result = client.query("SELECT name, age FROM users WHERE age > 18")
```

## Nim (حالت توکار)

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