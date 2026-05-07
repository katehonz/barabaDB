# HTTP/REST API

Web uygulamaları için JSON tabanlı REST API.

## Base URL

```
http://localhost:9470/api
```

## Uç Noktalar

### GET /api/users

Tüm kullanıcıları listele:

```bash
curl http://localhost:9470/api/users
```

### GET /api/users/:id

ID ile kullanıcı getir:

```bash
curl http://localhost:9470/api/users/1
```

### POST /api/users

Kullanıcı oluştur:

```bash
curl -X POST http://localhost:9470/api/users \
  -d '{"Name": "Charlie", "age": 35}'
```

### PUT /api/users/:id

Kullanıcı güncelle:

```bash
curl -X PUT http://localhost:9470/api/users/1 \
  -d '{"Name": "Alice", "age": 31}'
```

### DELETE /api/users/:id

Kullanıcı sil:

```bash
curl -X DELETE http://localhost:9470/api/users/1
```

## Sorgu Uç Noktası

BaraQL sorgularını HTTP ile çalıştır:

```bash
curl -X POST http://localhost:9470/api/query \
  -d '{"sql": "SELECT * FROM users WHERE age > 18"}'
```