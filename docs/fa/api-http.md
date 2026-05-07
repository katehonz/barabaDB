# HTTP/REST API

API REST مبتنی بر JSON برای برنامه‌های وب.

## Base URL

```
http://localhost:9470/api
```

## Endpoints

### GET /api/users

لیست همه کاربران:

```bash
curl http://localhost:9470/api/users
```

### GET /api/users/:id

دریافت کاربر با ID:

```bash
curl http://localhost:9470/api/users/1
```

### POST /api/users

ایجاد کاربر:

```bash
curl -X POST http://localhost:9470/api/users \
  -d '{"name": "Charlie", "age": 35}'
```

### PUT /api/users/:id

به‌روزرسانی کاربر:

```bash
curl -X PUT http://localhost:9470/api/users/1 \
  -d '{"name": "Alice", "age": 31}'
```

### DELETE /api/users/:id

حذف کاربر:

```bash
curl -X DELETE http://localhost:9470/api/users/1
```

## Query Endpoint

اجرای کوئری BaraQL:

```bash
curl -X POST http://localhost:9470/api/query \
  -d '{"sql": "SELECT * FROM users WHERE age > 18"}'
```