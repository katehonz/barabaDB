# Протоколна Референция

BaraDB поддържа множество протоколи за клиентска комуникация:
- **Бинарен Wire Протокол** — високопроизводителен, ниска латентност
- **HTTP/REST API** — езиково-независим, лесен за дебъгване
- **WebSocket** — стрийминг и pub/sub

---

## Бинарен Wire Протокол

Бинарният протокол използва big-endian кодиране за всички многобайтови стойности.

### Жизнен Цикъл на Връзката

```
Клиент                          Сървър
  |                               |
  |─── TCP свързване ───────────>|
  |<── TLS ръкостискане (опц.) ──|
  |─── Auth съобщение ──────────>|
  |<── Auth_OK / Грешка ─────────|
  |─── Query съобщение ─────────>|
  |<── Data / Complete / Error ──|
  |─── Close съобщение ─────────>|
  |<── TCP затваряне ────────────|
```

### Формат на Съобщенията

Всяко съобщение започва с 12-байтов хедър:

```
┌─────────────┬─────────────┬─────────────┬─────────────────────┐
│  Kind        │  Length     │  RequestId  │  Payload            │
│  (4 bytes)   │  (4 bytes)  │  (4 bytes)  │                     │
│  uint32 BE   │  uint32 BE  │  uint32 BE  │  (Length bytes)     │
└─────────────┴─────────────┴─────────────┴─────────────────────┘
```

### Типове Съобщения

| Тип | ID | Посока | Описание |
|------|----|--------|----------|
| Query | 0x01 | К→С | Изпълни заявка |
| QueryParams | 0x02 | К→С | Параметризирана заявка |
| Auth | 0x07 | К→С | Заявка за автентикация |
| Ping | 0x09 | К→С | Keepalive ping |
| Close | 0x0A | К→С | Затваряне на връзка |
| Data | 0x81 | С→К | Резултат от заявка |
| Complete | 0x82 | С→К | Заявката е завършена |
| Auth_OK | 0x83 | С→К | Успешна автентикация |
| Pong | 0x84 | С→К | Keepalive отговор |
| Error | 0x06 | С→К | Грешка |

### Query Съобщение Payload

```
┌───────────────────┬────────────────────────────┐
│ Query String      │                            │
│ (променлива)      │                            │
│ UTF-8             │                            │
└───────────────────┴────────────────────────────┘
```

### Data Съобщение Payload

```
┌──────────────┬─────────────────────────────────────────────┐
│ Брой Колони  │ Дефиниции на Колони + Данни от Редове        │
│ (4 bytes)    │                                             │
│ uint32 BE    │                                             │
└──────────────┴─────────────────────────────────────────────┘
```

### Типове Полета

| Тип | ID | Размер | Описание |
|------|----|--------|----------|
| NULL | 0x00 | 0 | NULL стойност |
| BOOL | 0x01 | 1 | true/false |
| INT8 | 0x02 | 1 | Signed 8-bit integer |
| INT16 | 0x03 | 2 | Signed 16-bit integer |
| INT32 | 0x04 | 4 | Signed 32-bit integer |
| INT64 | 0x05 | 8 | Signed 64-bit integer |
| FLOAT32 | 0x06 | 4 | IEEE 754 единична точност (big-endian) |
| FLOAT64 | 0x07 | 8 | IEEE 754 двойна точност (big-endian) |
| STRING | 0x08 | променлив | UTF-8 низ (4-байтов префикс за дължина) |
| BYTES | 0x09 | променлив | Сурови байтове (4-байтов префикс за дължина) |
| ARRAY | 0x0A | променлив | Масив от стойности |
| OBJECT | 0x0B | променлив | Ключ-стойност обект |
| VECTOR | 0x0C | променлив | Float32 масив (4-байтов префикс, big-endian floats) |

### Error Съобщение Payload

```
┌──────────────┬──────────────┬────────────────────────────┐
│ Код Грешка   │ Дълж. Съобщ. │ Съобщение за Грешка        │
│ (4 bytes)    │ (4 bytes)    │ (Дълж. Съобщ. bytes)      │
│ uint32 BE    │ uint32 BE    │ UTF-8                      │
└──────────────┴──────────────┴────────────────────────────┘
```

---

## HTTP/REST API

Базов URL: `http://localhost:9470/api/v1`

### Endpoints

#### Health

```http
GET /health
```

Отговор:
```json
{
  "status": "healthy",
  "version": "1.1.0",
  "uptime_seconds": 86400
}
```

#### Ready

```http
GET /ready
```

Връща `200` когато е готов, `503` при стартиране.

#### Query

```http
POST /query
Content-Type: application/json
Authorization: Bearer <token>

{
  "query": "SELECT name, age FROM users WHERE age > 18",
  "params": [],
  "format": "json"
}
```

Отговор:
```json
{
  "columns": ["name", "age"],
  "rows": [
    ["Alice", 30],
    ["Bob", 25]
  ],
  "row_count": 2,
  "duration_ms": 12
}
```

#### Batch

```http
POST /batch
Content-Type: application/json

{
  "queries": [
    "INSERT users { name := 'Alice', age := 30 }",
    "INSERT users { name := 'Bob', age := 25 }"
  ]
}
```

Отговор:
```json
{
  "results": [
    {"status": "ok", "affected_rows": 1},
    {"status": "ok", "affected_rows": 1}
  ]
}
```

#### Schema

```http
GET /schema
```

#### Metrics

```http
GET /metrics
```

Prometheus-съвместими метрики. Виж [Ръководство за Мониторинг](monitoring.md).

#### Explain

```http
POST /explain
Content-Type: application/json

{
  "query": "SELECT * FROM users WHERE age > 18"
}
```

Отговор:
```json
{
  "plan": "IndexScan",
  "index": "idx_users_age",
  "estimated_rows": 42,
  "cost": 120
}
```

#### Backup

```http
POST /backup
Content-Type: application/json

{
  "destination": "/backup/snapshot.db"
}
```

#### Административни Операции

```http
POST /admin/compact
POST /admin/rebalance
POST /admin/check
```

### HTTP Статус Кодове

| Код | Значение |
|------|----------|
| 200 | Успех |
| 400 | Лоша заявка (синтактична грешка) |
| 401 | Неоторизиран (изисква се auth) |
| 403 | Забранен (недостатъчни права) |
| 404 | Не е намерен (таблица/тип не съществува) |
| 429 | Твърде много заявки (rate limited) |
| 500 | Вътрешна сървърна грешка |
| 503 | Услугата е недостъпна (стартира) |

---

## WebSocket Протокол

URL: `ws://localhost:9471`

### Формат на Frame

WebSocket текстови frame-ове съдържат JSON съобщения:

```json
{
  "id": 1,
  "type": "query",
  "query": "SELECT * FROM users"
}
```

### Типове Съобщения

| Тип | Посока | Описание |
|------|--------|----------|
| `query` | К→С | Изпълни заявка |
| `subscribe` | К→С | Абониране за промени |
| `unsubscribe` | К→С | Отписване |
| `ping` | К→С | Keepalive |
| `result` | С→К | Резултат от заявка |
| `notification` | С→К | Известие за промяна |
| `error` | С→К | Грешка |
| `pong` | С→К | Keepalive отговор |

### Pub/Sub Пример

```javascript
const ws = new WebSocket('ws://localhost:9471');

ws.onopen = () => {
  // Абониране за промени в таблица
  ws.send(JSON.stringify({
    id: 1,
    type: 'subscribe',
    table: 'users'
  }));
};

ws.onmessage = (event) => {
  const msg = JSON.parse(event.data);
  if (msg.type === 'notification') {
    console.log('Промяна:', msg.operation, msg.data);
  }
};
```

### Стрийминг Заявки

```javascript
ws.send(JSON.stringify({
  id: 2,
  type: 'query',
  query: 'SELECT * FROM logs ORDER BY timestamp',
  streaming: true
}));

// Сървърът изпраща множество result frame-ове
// Последният frame има {"complete": true}
```

---

## Nim API Примери

### Бинарен Протокол

```nim
import barabadb/protocol/wire

let msg = makeQueryMessage(1, "SELECT * FROM users")
let ready = makeReadyMessage(1)
let error = makeErrorMessage(1, 42, "Syntax error")
```

### Connection Pool

```nim
import barabadb/protocol/pool

var pool = newConnectionPool(
  minConnections = 5,
  maxConnections = 100,
  idleTimeout = 30000
)
let conn = pool.acquire()
# Използване на връзка...
pool.release(conn)
```

### Автентикация

```nim
import barabadb/protocol/auth

var am = newAuthManager("secret-key")
let token = am.createToken(JWTClaims(sub: "user1", role: "admin"))
let result = am.validateCredentials(
  AuthCredentials(authMethod: amToken, payload: token)
)
```

### Rate Limiting

```nim
import barabadb/protocol/ratelimit

var rl = newRateLimiter(
  rlaTokenBucket,
  globalRate = 10000,
  perClientRate = 1000
)
if rl.allowRequest("client-123"):
  echo "Заявката е разрешена"
```
