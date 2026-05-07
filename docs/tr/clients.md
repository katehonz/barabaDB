# İstemci SDK'ları

BaraDB JavaScript/TypeScript, Python, Nim ve Rust için resmi istemci kütüphaneleri sağlar.

## JavaScript / TypeScript

### Kurulum

```bash
npm install baradb
```

### Temel Kullanım

```typescript
import { Client } from 'baradb';

const client = new Client('localhost', 9472);
await client.connect();

const result = await client.query('SELECT name, age FROM users WHERE age > 18');
```

## Python

### Kurulum

```bash
pip install baradb
```

### Temel Kullanım

```python
from baradb import Client

client = Client("localhost", 9472)
client.connect()
result = client.query("SELECT name, age FROM users WHERE age > 18")
```

## Nim (Gömülü Mod)

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