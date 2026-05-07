# 协议参考

BaraDB 支持多种客户端通信协议：
- **Binary Wire Protocol** — 高性能、低延迟
- **HTTP/REST API** — 语言无关、易于调试
- **WebSocket** — 流式传输和发布/订阅

## Binary Wire Protocol

所有多字节值使用大端编码。

### 连接生命周期

```
Client                          Server
  |                               |
  |─── TCP connect ──────────────>|
  |─── Auth message ──────────────>|
  |<── Auth_OK / Error ───────────|
  |─── Query message ────────────>|
  |<── Data / Complete / Error ───|
```

### 消息格式

```
┌─────────────┬─────────────┬─────────────┬─────────────────────┐
│  Length     │  Type       │  Sequence   │  Payload            │
│  (4 bytes)  │  (1 byte)   │  (1 byte)   │  (Length - 6 bytes) │
└─────────────┴─────────────┴─────────────┴─────────────────────┘
```

### 消息类型

| 类型 | ID | 描述 |
|------|----|------|
| Query | 0x01 | 执行查询 |
| Insert | 0x02 | 插入数据 |
| Update | 0x03 | 更新数据 |
| Delete | 0x04 | 删除数据 |
| Ready | 0x05 | 准备就绪 |
| Error | 0x06 | 错误响应 |

## HTTP/REST API

Base URL: `http://localhost:9470/api/v1`

### 端点

#### Health

```http
GET /health
```

#### Query

```http
POST /query
{
  "query": "SELECT * FROM users"
}
```

## WebSocket Protocol

URL: `ws://localhost:9471`