# HTTP/REST API

JSON-basierte REST API für Web-Anwendungen.

## Basis-URL

```
http://localhost:9470/api
```

## Endpoints

### GET /api/users

Alle Benutzer auflisten:

```bash
curl http://localhost:9470/api/users
```

Antwort:
```json
[
  {"id": 1, "name": "Alice", "age": 30},
  {"id": 2, "name": "Bob", "age": 25}
]
```

### GET /api/users/:id

Benutzer nach ID abrufen:

```bash
curl http://localhost:9470/api/users/1
```

### POST /api/users

Benutzer erstellen:

```bash
curl -X POST http://localhost:9470/api/users \
  -H "Content-Type: application/json" \
  -d '{"name": "Charlie", "age": 35}'
```

### PUT /api/users/:id

Benutzer aktualisieren:

```bash
curl -X PUT http://localhost:9470/api/users/1 \
  -H "Content-Type: application/json" \
  -d '{"name": "Alice", "age": 31}'
```

### DELETE /api/users/:id

Benutzer löschen:

```bash
curl -X DELETE http://localhost:9470/api/users/1
```

## Query-Endpoint

BaraQL-Abfragen über HTTP ausführen:

```bash
curl -X POST http://localhost:9470/api/query \
  -H "Content-Type: application/json" \
  -d '{"sql": "SELECT * FROM users WHERE age > 18"}'
```

## Fehlerantwort

```json
{
  "error": {
    "code": "INVALID_QUERY",
    "message": "Syntax error at line 1"
  }
}
```

## Authentifizierung

```bash
curl -H "Authorization: Bearer <token>" \
  http://localhost:9470/api/users
```
