# Справочник по протоколу

BaraDB поддерживает несколько протоколов для клиентской коммуникации:
- **Binary Wire Protocol** — высокопроизводительный, низкая латентность
- **HTTP/REST API** — независимый от языка, легко отлаживать
- **WebSocket** — потоковая передача и pub/sub

## Binary Wire Protocol

Использует big-endian кодирование для всех многобайтовых значений.

### Цикл соединения

```
Client                          Server
  |                               |
  |─── TCP connect ──────────────>|
  |<── TLS handshake (optional) ──|
  |─── Auth message ─────────────>|
  |<── Auth_OK / Error ───────────|
  |─── Query message ────────────>|
  |<── Data / Complete / Error ───|
  |─── Close message ────────────>|
  |<── TCP close ─────────────────|
```

### Формат сообщения

```
┌─────────────┬─────────────┬─────────────┬─────────────────────┐
│  Length     │  Type       │  Sequence   │  Payload            │
│  (4 bytes)  │  (1 byte)   │  (1 byte)   │  (Length - 6 bytes) │
└─────────────┴─────────────┴─────────────┴─────────────────────┘
```

### Типы сообщений

| Тип | ID | Направление | Описание |
|----|----|-------------|---------|
| Query | 0x01 | C→S | Выполнить запрос |
| Insert | 0x02 | C→S | Вставить данные |
| Update | 0x03 | C→S | Обновить данные |
| Delete | 0x04 | C→S | Удалить данные |
| Ready | 0x05 | S→C | Готов к следующей команде |
| Error | 0x06 | S→C | Ответ об ошибке |

## HTTP/REST API

Base URL: `http://localhost:9470/api/v1`

### Endpoints

#### Health

```http
GET /health
```

#### Query

```http
POST /query
Content-Type: application/json

{
  "query": "SELECT name, age FROM users WHERE age > 18"
}
```

#### Schema

```http
GET /schema
```

## WebSocket Protocol

URL: `ws://localhost:9471`

### Pub/Sub

```javascript
ws.send(JSON.stringify({
  type: 'subscribe',
  table: 'users'
}));
```