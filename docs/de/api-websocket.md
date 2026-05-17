# WebSocket API

Vollduplex-Streaming für Echtzeit-Datenfeeds und Push-Benachrichtigungen.

## Verbindung

```
ws://localhost:9471/ws
```

## Client-Beispiel

```javascript
const ws = new WebSocket('ws://localhost:9471/ws');

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

## Nachrichtenformat

```json
{
  "type": "query",
  "id": "uuid",
  "sql": "SELECT * FROM users"
}
```

## Nachrichtentypen

### Query-Anfrage

```json
{
  "type": "query",
  "id": "123",
  "sql": "SELECT * FROM users"
}
```

### Query-Antwort

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

### Fehlerantwort

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

Änderungen abonnieren:

```json
{
  "type": "subscribe",
  "id": "sub1",
  "table": "users"
}
```

### Push-Benachrichtigung

Server-Push:

```json
{
  "type": "push",
  "table": "users",
  "action": "insert",
  "data": {"id": 3, "name": "Charlie"}
}
```

## JavaScript-Client

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
