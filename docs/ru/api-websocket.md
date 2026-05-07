# WebSocket API

Полнодуплексная потоковая передача для real-time лент данных и push-уведомлений.

## Подключение

```
ws://localhost:9471/ws
```

## Пример клиента

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

## Формат сообщения

```json
{
  "type": "query",
  "id": "uuid",
  "sql": "SELECT * FROM users"
}
```

## Типы сообщений

### Запрос

```json
{
  "type": "query",
  "id": "123",
  "sql": "SELECT * FROM users"
}
```

### Ответ

```json
{
  "type": "result",
  "id": "123",
  "data": [{"id": 1, "name": "Alice"}]
}
```

### Подписка

```json
{
  "type": "subscribe",
  "table": "users"
}
```

### Push уведомление

```json
{
  "type": "push",
  "table": "users",
  "action": "insert",
  "data": {"id": 3, "name": "Charlie"}
}
```