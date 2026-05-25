# HTTP/REST API

JSON-базиран REST API за уеб приложения.

## Базов URL

```
http://localhost:9912
```

## Endpoints

### GET /health

Health проверка:

```bash
curl http://localhost:9912/health
```

### GET /metrics

Prometheus метрики:

```bash
curl http://localhost:9912/metrics
```

### POST /auth

JWT автентикация:

```bash
curl -X POST http://localhost:9912/auth \
  -H "Content-Type: application/json" \
  -d '{"username": "admin", "password": "secret"}'
```

### POST /query

Изпълнение на SQL заявка:

```bash
curl -X POST http://localhost:9912/query \
  -H "Content-Type: application/json" \
  -H "X-Database: default" \
  -d '{"query": "SELECT * FROM users WHERE age > 18"}'
```

Отговор:
```json
{
  "columns": ["name", "age"],
  "rows": [{"name": "Alice", "age": 30}],
  "affectedRows": 0
}
```

> **Забележка:** Header `X-Database` избира към коя база данни да се изпълни заявката. Ако липсва, се използва `default`.

### GET /tables

Списък с таблици в избраната база данни:

```bash
curl http://localhost:9912/tables -H "X-Database: default"
```

### GET /databases

Списък с налични бази данни:

```bash
curl http://localhost:9912/databases
```

### POST /databases

Създаване на нова база данни (изисква admin права):

```bash
curl -X POST http://localhost:9912/databases \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <token>" \
  -d '{"name": "mydb"}'
```

### POST /backup

Създаване на backup (изисква admin права):

```bash
# Backup на всички бази данни
curl -X POST http://localhost:9912/backup \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <token>" \
  -d '{"all": true}'

# Backup на единична база
curl -X POST http://localhost:9912/backup \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <token>" \
  -d '{"database": "default"}'
```

### GET /backups

Списък с налични архиви:

```bash
curl http://localhost:9912/backups -H "Authorization: Bearer <token>"
```

### POST /restore

Възстановяване от архив (изисква admin права):

```bash
curl -X POST http://localhost:9912/restore \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <token>" \
  -d '{"input": "backup_1234567890.tar.gz", "all": true}'
```

## Грешки

```json
{
  "error": "Unauthorized"
}
```

## Автентикация

```bash
curl -H "Authorization: Bearer <token>" \
  http://localhost:9912/metrics
```
