# WebSocket API

用于实时数据流和推送通知的全双工流。

## 连接

```
ws://localhost:9471/ws
```

## 客户端示例

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

## 消息格式

```json
{
  "type": "query",
  "id": "uuid",
  "sql": "SELECT * FROM users"
}
```

## 消息类型

### 查询请求

```json
{
  "type": "query",
  "id": "123",
  "sql": "SELECT * FROM users"
}
```

### 查询响应

```json
{
  "type": "result",
  "id": "123",
  "data": [{"id": 1, "name": "Alice"}]
}
```

### 订阅

```json
{
  "type": "subscribe",
  "table": "users"
}
```