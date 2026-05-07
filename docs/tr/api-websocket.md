# WebSocket API

Gerçek zamanlı veri akışları ve anlık bildirimler için tam çift yönlü akış.

## Bağlantı

```
ws://localhost:9471/ws
```

## İstemci Örneği

```javascript
const ws = new WebSocket('ws://localhost:9471/ws');

ws.onopen = () => {
  ws.send(JSON.stringify({
    type: 'query',
    sql: 'SELECT * FROM users'
  }));
};

ws.onmessage = (event) => {
  console.log('Received:', JSON.parse(event.data));
};
```

## Mesaj Formatı

```json
{
  "type": "query",
  "id": "uuid",
  "sql": "SELECT * FROM users"
}
```

## Mesaj Türleri

### Sorgu İsteği

```json
{
  "type": "query",
  "id": "123",
  "sql": "SELECT * FROM users"
}
```

### Sorgu Yanıtı

```json
{
  "type": "result",
  "id": "123",
  "data": [{"id": 1, "name": "Alice"}]
}
```

### Abonelik

```json
{
  "type": "subscribe",
  "table": "users"
}
```

### Anlık Bildirim

```json
{
  "type": "push",
  "table": "users",
  "action": "insert",
  "data": {"id": 3, "name": "Charlie"}
}
```