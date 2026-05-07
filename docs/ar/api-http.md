# API HTTP/REST

API REST مبني على JSON لتطبيقات الويب.

## Base URL

```
http://localhost:9470/api
```

## نقاط النهاية

### GET /api/users

قائمة جميع المستخدمين:

```bash
curl http://localhost:9470/api/users
```

### GET /api/users/:id

الحصول على المستخدم بالـ ID:

```bash
curl http://localhost:9470/api/users/1
```

### POST /api/users

إنشاء مستخدم:

```bash
curl -X POST http://localhost:9470/api/users \
  -d '{"Name": "Charlie", "age": 35}'
```

### PUT /api/users/:id

تحديث مستخدم:

```bash
curl -X PUT http://localhost:9470/api/users/1 \
  -d '{"Name": "Alice", "age": 31}'
```

### DELETE /api/users/:id

حذف مستخدم:

```bash
curl -X DELETE http://localhost:9470/api/users/1
```

## نقطة نهاية الاستعلام

تنفيذ استعلامات BaraQL عبر HTTP:

```bash
curl -X POST http://localhost:9470/api/query \
  -d '{"sql": "SELECT * FROM users WHERE age > 18"}'
```