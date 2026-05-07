# مرجع پروتکل

BaraDB چندین پروتکل پشتیبانی می‌کند:
- **Binary Wire Protocol** — با کارایی بالا
- **HTTP/REST API** — مستقل از زبان
- **WebSocket** — استریمینگ و pub/sub

## Binary Wire Protocol

از کدگذاری big-endian استفاده می‌کند.

### چرخه اتصال

```
Client                          Server
  |                               |
  |─── TCP connect ──────────────>|
  |─── Auth message ─────────────>|
  |<── Auth_OK / Error ───────────|
  |─── Query message ────────────>|
  |<── Data / Complete / Error ───|
```

### فرمت پیام

```
┌─────────────┬─────────────┬─────────────┬─────────────────────┐
│  Length     │  Type       │  Sequence   │  Payload            │
│  (4 bytes)  │  (1 byte)   │  (1 byte)   │  (Length - 6 bytes) │
└─────────────┴─────────────┴─────────────┴─────────────────────┘
```

### انواع پیام

| نوع | ID | توضیح |
|----|----|--------|
| Query | 0x01 | اجرای کوئری |
| Insert | 0x02 | درج داده |
| Update | 0x03 | به‌روزرسانی |
| Delete | 0x04 | حذف |
| Ready | 0x05 | آماده |
| Error | 0x06 | پاسخ خطا |

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
{
  "query": "SELECT * FROM users"
}
```

## WebSocket Protocol

URL: `ws://localhost:9471`