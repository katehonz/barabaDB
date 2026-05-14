# HTTP/REST API

JSON-базиран REST API за уеб приложения.

## Базов URL

```
http://localhost:9470
```

## Endpoints

### GET /health

Health проверка:

```bash
curl http://localhost:9470/health
```

### GET /ready

Readiness проверка:

```bash
curl http://localhost:9470/ready
```

### POST /query

Изпълнение на BaraQL заявка:

```bash
curl -X POST http://localhost:9470/api/query \
  -H "Content-Type: application/json" \
  -d '{"query": "SELECT * FROM users WHERE age > 18"}'
```

Отговор:
```json
{
  "columns": ["name", "age"],
  "rows": [["Alice", 30], ["Bob", 25]],
  "row_count": 2,
  "duration_ms": 12
}
```

### POST /batch

Групови заявки:

```bash
curl -X POST http://localhost:9470/api/batch \
  -H "Content-Type: application/json" \
  -d '{"queries": ["INSERT users { name := \"Alice\" }", "INSERT users { name := \"Bob\" }"]}'
```

### GET /schema

Преглед на схемата:

```bash
curl http://localhost:9470/api/schema
```

### GET /metrics

Prometheus метрики:

```bash
curl http://localhost:9470/metrics
```

### POST /explain

Обяснение на план за изпълнение:

```bash
curl -X POST http://localhost:9470/api/explain \
  -H "Content-Type: application/json" \
  -d '{"query": "SELECT * FROM users WHERE age > 18"}'
```

### POST /backup

Създаване на backup:

```bash
curl -X POST http://localhost:9470/api/backup \
  -H "Content-Type: application/json" \
  -d '{"destination": "/backup/snapshot.db"}'
```

## Грешки

```json
{
  "error": {
    "code": "INVALID_QUERY",
    "message": "Грешка в синтаксиса"
  }
}
```

## Автентикация

```bash
curl -H "Authorization: Bearer <token>" \
  http://localhost:9470/api/users
```
