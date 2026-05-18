# Protocol Reference

BaraDB supports multiple protocols for client communication:
- **Binary Wire Protocol** — high-performance, low-latency
- **HTTP/REST API** — language-agnostic, easy to debug
- **WebSocket** — streaming and pub/sub

---

## Binary Wire Protocol

The binary protocol uses big-endian encoding for all multi-byte values.

### Connection Optimizations

- **TCP_NODELAY** — Enabled on both server and client sockets to minimize latency for small messages (queries, acks). This disables Nagle's algorithm, ensuring packets are sent immediately without buffering.
- **Rate Limiting** — Token-bucket rate limiter is integrated at the protocol level. Queries exceeding the rate limit receive error code 429.

### Connection Lifecycle

```
Client                          Server
  |                               |
  |─── TCP connect ──────────────>|
  |<── TLS handshake (optional) ──|
  |─── Auth message ─────────────>|
  |<── Auth_OK / Error ───────────|
  |─── Query message ────────────>|
  |<── Data / Complete / Error ───|
  |─── Close message ────────────>|
  |<── TCP close ─────────────────|
```

### Message Format

Every message starts with a 8-byte header:

```
┌─────────────┬─────────────┬─────────────┬─────────────────────┐
│  Length     │  Type       │  Sequence   │  Payload            │
│  (4 bytes)  │  (1 byte)   │  (1 byte)   │  (Length - 6 bytes) │
│  uint32 BE  │  uint8      │  uint8      │                     │
└─────────────┴─────────────┴─────────────┴─────────────────────┘
```

### Message Types

| Type | ID | Direction | Description |
|------|----|-----------|-------------|
| Query | 0x01 | C→S | Execute query |
| Insert | 0x02 | C→S | Insert data |
| Update | 0x03 | C→S | Update data |
| Delete | 0x04 | C→S | Delete data |
| Ready | 0x05 | S→C | Ready for next command |
| Error | 0x06 | S→C | Error response |
| Auth | 0x07 | C→S | Authentication request |
| Batch | 0x08 | C→S | Batch operations |
| Ping | 0x09 | C→S | Keepalive ping |
| Data | 0x81 | S→C | Query result data |
| Complete | 0x82 | S→C | Query complete |
| Auth_OK | 0x83 | S→C | Authentication success |
| Pong | 0x84 | S→C | Keepalive response |

### Query Message Payload

```
┌──────────────┬──────────────┬────────────────────────────┐
│ Result Format│ Query Length │ Query String               │
│ (1 byte)     │ (4 bytes)    │ (Query Length bytes)       │
│ 0x00=Binary  │ uint32 BE    │ UTF-8                      │
│ 0x01=JSON    │              │                            │
│ 0x02=Text    │              │                            │
└──────────────┴──────────────┴────────────────────────────┘
```

### Data Message Payload

```
┌──────────────┬─────────────────────────────────────────────┐
│ Column Count │ Column Definitions + Row Data               │
│ (2 bytes)    │                                             │
│ uint16 BE    │                                             │
└──────────────┴─────────────────────────────────────────────┘
```

### Column Definition

```
┌──────────────┬──────────────┬────────────────────────────┐
│ Name Length  │ Name         │ Type                       │
│ (2 bytes)    │ (N bytes)    │ (1 byte)                   │
│ uint16 BE    │ UTF-8        │ See FieldKind table        │
└──────────────┴──────────────┴────────────────────────────┘
```

### Field Types

| Type | ID | Size | Description |
|------|----|------|-------------|
| NULL | 0x00 | 0 | NULL value |
| BOOL | 0x01 | 1 | true/false |
| INT8 | 0x02 | 1 | Signed 8-bit integer |
| INT16 | 0x03 | 2 | Signed 16-bit integer |
| INT32 | 0x04 | 4 | Signed 32-bit integer |
| INT64 | 0x05 | 8 | Signed 64-bit integer |
| FLOAT32 | 0x06 | 4 | IEEE 754 single precision (big-endian) |
| FLOAT64 | 0x07 | 8 | IEEE 754 double precision (big-endian) |
| STRING | 0x08 | variable | UTF-8 string (4-byte length prefix) |
| BYTES | 0x09 | variable | Raw bytes (4-byte length prefix) |
| ARRAY | 0x0A | variable | Array of values |
| OBJECT | 0x0B | variable | Key-value object |
| VECTOR | 0x0C | variable | Float32 array (4-byte length prefix, big-endian floats) |

### Error Message Payload

```
┌──────────────┬──────────────┬────────────────────────────┐
│ Error Code   │ Message Len  │ Error Message              │
│ (4 bytes)    │ (4 bytes)    │ (Message Len bytes)        │
│ uint32 BE    │ uint32 BE    │ UTF-8                      │
└──────────────┴──────────────┴────────────────────────────┘
```

### Example: Raw TCP Session

```bash
# Connect
nc localhost 9472

# Send: Auth request (token "mytoken")
# Header: length=15, type=0x07, seq=1
# Payload: token length=7, token="mytoken"
printf '\x00\x00\x00\x0f\x07\x01\x00\x00\x00\x07mytoken' > /dev/tcp/localhost/9472

# Receive: Auth_OK
# \x00\x00\x00\x06\x83\x01

# Send: Query "SELECT 1"
printf '\x00\x00\x00\x12\x01\x02\x00\x00\x00\x00\x08SELECT 1' > /dev/tcp/localhost/9472

# Receive: Data + Complete
```

---

## HTTP/REST API

Base URL: `http://localhost:9470/api/v1`

### Rate Limiting

All query endpoints (`/query`, `/batch`) are protected by a token-bucket rate limiter:
- **Global rate** — Configured via `BARADB_RATE_LIMIT_GLOBAL` (default: 10,000 requests/minute)
- **Per-client rate** — Configured via `BARADB_RATE_LIMIT_PER_CLIENT` (default: 1,000 requests/minute)
- **Client identification** — Uses `X-Forwarded-For` header when behind a proxy, otherwise uses a global key

When rate-limited, the server returns HTTP 429 with:
```json
{"error": "Rate limit exceeded"}
```

### Endpoints

#### Health

```http
GET /health
```

Response:
```json
{
  "status": "healthy",
  "version": "0.1.0",
  "uptime_seconds": 86400
}
```

#### Ready

```http
GET /ready
```

Returns `200` when ready, `503` during startup.

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

Response:
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

Response:
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

Response:
```json
{
  "types": [
    {
      "name": "User",
      "properties": [
        {"name": "name", "type": "str", "required": true},
        {"name": "age", "type": "int32"}
      ]
    }
  ]
}
```

#### Metrics

```http
GET /metrics
```

Prometheus-compatible metrics. See [Monitoring Guide](monitoring.md).

#### Explain

```http
POST /explain
Content-Type: application/json

{
  "query": "SELECT * FROM users WHERE age > 18"
}
```

Response:
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

#### Admin Operations

```http
POST /admin/compact
POST /admin/rebalance
POST /admin/check
```

### HTTP Status Codes

| Code | Meaning |
|------|---------|
| 200 | Success |
| 400 | Bad request (syntax error) |
| 401 | Unauthorized (auth required) |
| 403 | Forbidden (insufficient permissions) |
| 404 | Not found (table/type doesn't exist) |
| 429 | Too many requests (rate limited) |
| 500 | Internal server error |
| 503 | Service unavailable (starting up) |

---

## WebSocket Protocol

URL: `ws://localhost:9471`

### Frame Format

WebSocket text frames contain JSON messages:

```json
{
  "id": 1,
  "type": "query",
  "query": "SELECT * FROM users"
}
```

### Message Types

| Type | Direction | Description |
|------|-----------|-------------|
| `query` | C→S | Execute query |
| `subscribe` | C→S | Subscribe to changes |
| `unsubscribe` | C→S | Unsubscribe |
| `ping` | C→S | Keepalive |
| `result` | S→C | Query result |
| `notification` | S→C | Change notification |
| `error` | S→C | Error |
| `pong` | S→C | Keepalive response |

### Pub/Sub Example

```javascript
const ws = new WebSocket('ws://localhost:9471');

ws.onopen = () => {
  // Subscribe to table changes
  ws.send(JSON.stringify({
    id: 1,
    type: 'subscribe',
    table: 'users'
  }));
};

ws.onmessage = (event) => {
  const msg = JSON.parse(event.data);
  if (msg.type === 'notification') {
    console.log('Change:', msg.operation, msg.data);
  }
};
```

### Streaming Queries

```javascript
ws.send(JSON.stringify({
  id: 2,
  type: 'query',
  query: 'SELECT * FROM logs ORDER BY timestamp',
  streaming: true
}));

// Server sends multiple result frames
// Final frame has {"complete": true}
```

---

## Nim API Examples

### Binary Protocol

```nim
import barabadb/protocol/wire

let msg = makeQueryMessage(1, "SELECT * FROM users")
let ready = makeReadyMessage(1)
let error = makeErrorMessage(1, 42, "Syntax error")
```

### HTTP Router

```nim
import barabadb/protocol/http

var router = newHttpRouter(port = 9470)

router.get("/api/users", proc(req: Request): Future[JsonNode] {.async.} =
  return %*[
    {"id": 1, "name": "Alice"},
    {"id": 2, "name": "Bob"}
  ]
)

router.post("/api/users", proc(req: Request): Future[JsonNode] {.async.} =
  return %*{"status": "created", "id": 3}
)
```

### WebSocket Server

```nim
import barabadb/core/websocket

var server = newWsServer(port = 9471)
server.onMessage = proc(ws: WebSocket, data: seq[byte]) {.gcsafe.} =
  echo "Received: ", cast[string](data)
  asyncCheck ws.send(cast[string](data))  # Echo
asyncCheck server.run()
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
# Use connection...
pool.release(conn)
```

### Authentication

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
  echo "Request allowed"
```
