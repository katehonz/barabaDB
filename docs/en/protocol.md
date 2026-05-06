# Protocol Reference

BaraDB supports multiple protocols for client communication.

## Binary Wire Protocol

Efficient big-endian binary protocol:

```nim
import barabadb/protocol/wire

# Query message
let msg = makeQueryMessage(1, "SELECT * FROM users")

# Ready message
let ready = makeReadyMessage(1)

# Error message
let error = makeErrorMessage(1, 42, "Syntax error")
```

### Message Types

| Type | ID | Description |
|------|-----|-------------|
| Query | 0x01 | Execute query |
| Insert | 0x02 | Insert data |
| Update | 0x03 | Update data |
| Delete | 0x04 | Delete data |
| Ready | 0x05 | Ready for next command |
| Error | 0x06 | Error response |
| Auth | 0x07 | Authentication |
| Batch | 0x08 | Batch operations |

## HTTP/REST API

JSON-based REST API:

```nim
import barabadb/protocol/http

var router = newHttpRouter(port = 8080)

router.get("/api/users", proc(req: Request): Future[JsonNode] {.async.} =
  return %*[{"id": 1, "name": "Alice"}])

router.post("/api/users", proc(req: Request): Future[JsonNode] {.async.} =
  return %*{"status": "created"})
```

## WebSocket API

Full-duplex streaming:

```nim
import barabadb/core/websocket

var server = newWsServer(port = 8081)
server.onMessage = proc(ws: WebSocket, data: seq[byte]) {.gcsafe.} =
  echo "Received: ", cast[string](data)
asyncCheck server.run()
```

## Authentication

JWT-based authentication:

```nim
import barabadb/protocol/auth

var am = newAuthManager("secret-key")
let token = am.createToken(JWTClaims(sub: "user1", role: "admin"))
let result = am.validateCredentials(AuthCredentials(authMethod: amToken, payload: token))
```

## Rate Limiting

Token bucket rate limiting:

```nim
import barabadb/protocol/ratelimit

var rl = newRateLimiter(rlaTokenBucket, globalRate = 1000, perClientRate = 100)
if rl.allowRequest("client-123"):
  echo "Request allowed"
```

## Connection Pooling

```nim
import barabadb/protocol/pool

var pool = newConnectionPool(
  minConnections = 5,
  maxConnections = 100
)
let conn = pool.acquire()
pool.release(conn)
```