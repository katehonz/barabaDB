# حزم العملاء

توفر BaraDB مكتبات العملاء الرسمية لـ JavaScript/TypeScript و Python و Nim و Rust.

## JavaScript / TypeScript

### التثبيت

```bash
npm install baradb
```

### الاستخدام الأساسي

```typescript
import { Client } from 'baradb';

const client = new Client('localhost', 9472);
await client.connect();

const result = await client.query('SELECT name, age FROM users WHERE age > 18');
```

## Python

### التثبيت

```bash
pip install baradb
```

### الاستخدام الأساسي

```python
from baradb import Client

client = Client("localhost", 9472)
client.connect()
result = client.query("SELECT name, age FROM users WHERE age > 18")
```

## Nim (الوضع المدمج)

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