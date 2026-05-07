# WebSocket API

استریم تمام‌دوطرفه برای فیدهای داده real-time.

## اتصال

```
ws://localhost:9471/ws
```

## مثال کلاینت

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

## فرمت پیام

```json
{
  "type": "query",
  "id": "uuid",
  "sql": "SELECT * FROM users"
}
```

## انواع پیام

### درخواست

```json
{
  "type": "query",
  "id": "123",
  "sql": "SELECT * FROM users"
}
```

### پاسخ

```json
{
  "type": "result",
  "id": "123",
  "data": [{"id": 1, "name": "Alice"}]
}
```

### اشتراک

```json
{
  "type": "subscribe",
  "table": "users"
}
```