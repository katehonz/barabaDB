# HTTP/REST API

JSON-based REST API for web applications.

## Base URL

```
http://localhost:9470/api
```

## Endpoints

### GET /api/users

List all users:

```bash
curl http://localhost:9470/api/users
```

Response:
```json
[
  {"id": 1, "name": "Alice", "age": 30},
  {"id": 2, "name": "Bob", "age": 25}
]
```

### GET /api/users/:id

Get user by ID:

```bash
curl http://localhost:9470/api/users/1
```

### POST /api/users

Create user:

```bash
curl -X POST http://localhost:9470/api/users \
  -H "Content-Type: application/json" \
  -d '{"name": "Charlie", "age": 35}'
```

### PUT /api/users/:id

Update user:

```bash
curl -X PUT http://localhost:9470/api/users/1 \
  -H "Content-Type: application/json" \
  -d '{"name": "Alice", "age": 31}'
```

### DELETE /api/users/:id

Delete user:

```bash
curl -X DELETE http://localhost:9470/api/users/1
```

## Query Endpoint

Execute BaraQL queries via HTTP:

```bash
curl -X POST http://localhost:9470/api/query \
  -H "Content-Type: application/json" \
  -d '{"sql": "SELECT * FROM users WHERE age > 18"}'
```

## Error Response

```json
{
  "error": {
    "code": "INVALID_QUERY",
    "message": "Syntax error at line 1"
  }
}
```

## Authentication

```bash
curl -H "Authorization: Bearer <token>" \
  http://localhost:9470/api/users
```