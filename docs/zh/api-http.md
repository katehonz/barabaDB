# HTTP/REST API

用于 Web 应用程序的基于 JSON 的 REST API。

## Base URL

```
http://localhost:9470/api
```

## 端点

### GET /api/users

列出所有用户：

```bash
curl http://localhost:9470/api/users
```

### GET /api/users/:id

按 ID 获取用户：

```bash
curl http://localhost:9470/api/users/1
```

### POST /api/users

创建用户：

```bash
curl -X POST http://localhost:9470/api/users \
  -d '{"name": "Charlie", "age": 35}'
```

### PUT /api/users/:id

更新用户：

```bash
curl -X PUT http://localhost:9470/api/users/1 \
  -d '{"name": "Alice", "age": 31}'
```

### DELETE /api/users/:id

删除用户：

```bash
curl -X DELETE http://localhost:9470/api/users/1
```

## 查询端点

通过 HTTP 执行 BaraQL 查询：

```bash
curl -X POST http://localhost:9470/api/query \
  -d '{"sql": "SELECT * FROM users WHERE age > 18"}'
```