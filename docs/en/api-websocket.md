# WebSocket API

Full-duplex streaming for real-time data feeds and push notifications.

## Connection

```
ws://localhost:8081/ws
```

## Client Example

```javascript
const ws = new WebSocket('ws://localhost:8081/ws');

ws.onopen = () => {
  console.log('Connected');
  ws.send(JSON.stringify({
    type: 'query',
    sql: 'SELECT * FROM users'
  }));
};

ws.onmessage = (event) => {
  const data = JSON.parse(event.data);
  console.log('Received:', data);
};
```

## Message Format

```json
{
  "type": "query",
  "id": "uuid",
  "sql": "SELECT * FROM users"
}
```

## Message Types

### Query Request

```json
{
  "type": "query",
  "id": "123",
  "sql": "SELECT * FROM users"
}
```

### Query Response

```json
{
  "type": "result",
  "id": "123",
  "data": [
    {"id": 1, "name": "Alice"},
    {"id": 2, "name": "Bob"}
  ]
}
```

### Error Response

```json
{
  "type": "error",
  "id": "123",
  "error": {
    "code": "INVALID_QUERY",
    "message": "Syntax error"
  }
}
```

### Subscription

Subscribe to changes:

```json
{
  "type": "subscribe",
  "id": "sub1",
  "table": "users"
}
```

### Push Notification

Server push:

```json
{
  "type": "push",
  "table": "users",
  "action": "insert",
  "data": {"id": 3, "name": "Charlie"}
}
```

## JavaScript Client

```javascript
class BaraDBClient {
  constructor(url) {
    this.ws = new WebSocket(url);
    this.pending = new Map();
  }

  query(sql) {
    return new Promise((resolve, reject) => {
      const id = crypto.randomUUID();
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ type: 'query', id, sql }));
    });
  }
}
```