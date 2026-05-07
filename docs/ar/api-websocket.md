# API WebSocket

دفق كامل للاتجاهين لتغذية البيانات في الوقت الفعلي والإشعارات.

## الاتصال

```
ws://localhost:9471/ws
```

## مثال العميل

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

## تنسيق الرسالة

```json
{
  "type": "query",
  "id": "uuid",
  "sql": "SELECT * FROM users"
}
```

## أنواع الرسائل

### طلب الاستعلام

```json
{
  "type": "query",
  "id": "123",
  "sql": "SELECT * FROM users"
}
```

### استجابة الاستعلام

```json
{
  "type": "result",
  "id": "123",
  "data": [{"id": 1, "name": "Alice"}]
}
```

### الاشتراك

```json
{
  "type": "subscribe",
  "table": "users"
}
```

### إشعار

```json
{
  "type": "push",
  "table": "users",
  "action": "insert",
  "data": {"id": 3, "name": "Charlie"}
}
```