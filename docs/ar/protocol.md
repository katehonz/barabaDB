# مرجع البروتوكول

يدعم BaraDB بروتوكولات متعددة للتواصل مع العملاء:
- **Binary Wire Protocol** — عالي الأداء، منخفض التأخير
- **HTTP/REST API** — لغةagnostic، سهل التصحيح
- **WebSocket** — الدفق و pub/sub

## Binary Wire Protocol

يستخدم ترميز big-endian لجميع القيم متعددة البايت.

### دورة الاتصال

```
Client                          Server
  |                               |
  |─── TCP connect ──────────────>|
  |─── Auth message ─────────────>|
  |<── Auth_OK / Error ───────────|
  |─── Query message ────────────>|
  |<── Data / Complete / Error ───|
```

### تنسيق الرسالة

```
┌─────────────┬─────────────┬─────────────┬─────────────────────┐
│  Length     │  Type       │  Sequence   │  Payload            │
│  (4 bytes)  │  (1 byte)   │  (1 byte)   │  (Length - 6 bytes) │
└─────────────┴─────────────┴─────────────┴─────────────────────┘
```

### أنواع الرسائل

| النوع | ID | الوصف |
|-------|----|-------|
| Query | 0x01 | تنفيذ استعلام |
| Insert | 0x02 | إدراج بيانات |
| Update | 0x03 | تحديث بيانات |
| Delete | 0x04 | حذف بيانات |
| Ready | 0x05 | جاهز للامر التالي |
| Error | 0x06 | استجابة خطأ |

## HTTP/REST API

Base URL: `http://localhost:9470/api/v1`

### نقاط النهاية

#### Health

```http
GET /health
```

#### استعلام

```http
POST /query
{
  "query": "SELECT * FROM users"
}
```

## WebSocket Protocol

URL: `ws://localhost:9471`