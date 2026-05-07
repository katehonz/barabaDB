# HTTP/REST API

JSON-based REST API для веб-приложений.

## Base URL

```
http://localhost:9470/api
```

## Endpoints

### GET /api/users

Список всех пользователей:

```bash
curl http://localhost:9470/api/users
```

### GET /api/users/:id

Получить пользователя по ID:

```bash
curl http://localhost:9470/api/users/1
```

### POST /api/users

Создать пользователя:

```bash
curl -X POST http://localhost:9470/api/users \
  -H "Content-Type: application/json" \
  -d '{"name": "Charlie", "age": 35}'
```

### PUT /api/users/:id

Обновить пользователя:

```bash
curl -X PUT http://localhost:9470/api/users/1 \
  -H "Content-Type: application/json" \
  -d '{"name": "Alice", "age": 31}'
```

### DELETE /api/users/:id

Удалить пользователя:

```bash
curl -X DELETE http://localhost:9470/api/users/1
```

## Query Endpoint

Выполнение BaraQL запросов через HTTP:

```bash
curl -X POST http://localhost:9470/api/query \
  -H "Content-Type: application/json" \
  -d '{"sql": "SELECT * FROM users WHERE age > 18"}'
```

## Ответ об ошибке

```json
{
  "error": {
    "code": "INVALID_QUERY",
    "message": "Syntax error at line 1"
  }
}
```

## Аутентификация

```bash
curl -H "Authorization: Bearer <token>" \
  http://localhost:9470/api/users
```