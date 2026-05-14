# WebSocket API

Full-duplex стрийминг за данни в реално време и push известия.

## Свързване

```
ws://localhost:9471
```

## Клиентски Пример

```javascript
const ws = new WebSocket('ws://localhost:9471');

ws.onopen = () => {
  console.log('Свързан');
  ws.send(JSON.stringify({
    type: 'query',
    query: 'SELECT * FROM users'
  }));
};

ws.onmessage = (event) => {
  const data = JSON.parse(event.data);
  console.log('Получено:', data);
};
```

## Формат на Съобщенията

```json
{
  "type": "query",
  "id": "1",
  "query": "SELECT * FROM users"
}
```

## Типове Съобщения

### Заявка (query)

```json
{
  "type": "query",
  "id": "1",
  "query": "SELECT * FROM users"
}
```

### Резултат (result)

```json
{
  "type": "result",
  "id": "1",
  "columns": ["id", "name"],
  "rows": [["1", "Alice"], ["2", "Bob"]]
}
```

### Грешка (error)

```json
{
  "type": "error",
  "id": "1",
  "code": "INVALID_QUERY",
  "message": "Синтактична грешка"
}
```

### Абониране (subscribe)

Абониране за промени в таблица:

```json
{
  "type": "subscribe",
  "id": "sub1",
  "table": "users"
}
```

### Известие (notification)

Push известие от сървъра:

```json
{
  "type": "notification",
  "table": "users",
  "operation": "insert",
  "data": {"id": 3, "name": "Charlie"}
}
```

### Ping/Pong (keepalive)

```json
{"type": "ping", "id": "ping1"}
```

Отговор:
```json
{"type": "pong", "id": "ping1"}
```

## JavaScript Клиент

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
      this.ws.send(JSON.stringify({ type: 'query', id, query: sql }));
    });
  }
}
```
