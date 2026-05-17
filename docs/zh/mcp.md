# MCP 服务器 (Model Context Protocol)

BaraDB 包含一个内置 MCP 服务器，使 AI 代理（Claude、Cursor 等）能够直接与数据库交互。

## 快速入门

```bash
./build/baramcp --data-dir ./data
```

以 STDIO 模式启动，在 stdin 上接受 JSON-RPC 2.0 消息。

## 可用工具

### 1. `query` — SQL 执行

```json
{
  "name": "query",
  "arguments": {
    "sql": "SELECT * FROM users WHERE age > ?",
    "params": [25],
    "tenant_id": "company-a",
    "user_id": "alice"
  }
}
```

使用 `?` 占位符的参数化查询。通过 `tenant_id` 和 `user_id` 实现多租户支持。

### 2. `vector_search` — 语义搜索

```json
{
  "name": "vector_search",
  "arguments": {
    "table": "docs",
    "column": "embedding",
    "query_vector": [0.1, 0.2, 0.3],
    "k": 5,
    "metric": "cosine",
    "filter_column": "category",
    "filter_value": "news",
    "tenant_id": "company-a"
  }
}
```

度量：`cosine`、`euclidean`、`dot_product`、`manhattan`。

### 3. `schema_inspect` — Schema 探索

```json
{
  "name": "schema_inspect",
  "arguments": {
    "table": "users",
    "tenant_id": "company-a"
  }
}
```

返回表、列、类型、主键、外键、索引和 RLS 策略。

## Claude Desktop 配置

```json
{
  "mcpServers": {
    "baradb": {
      "command": "/path/to/build/baramcp",
      "args": ["--data-dir", "/path/to/data"]
    }
  }
}
```

## Cursor 配置

```json
{
  "mcpServers": {
    "baradb": {
      "command": "/path/to/build/baramcp",
      "args": ["--data-dir", "~/.baradb/data"]
    }
  }
}
```

## 多租户隔离

每个 MCP 请求都可以包含 `tenant_id` 和 `user_id`，它们被设置为会话变量：
- `app.tenant_id` — 用于 RLS 过滤
- `app.user_id` — 用于 `current_user` 引用

RLS 策略根据这些变量自动过滤数据。

## JSON-RPC 2.0 协议

服务器通过 STDIO 使用 JSON-RPC 2.0：

```json
// 请求
{"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {...}}

// 响应
{"jsonrpc": "2.0", "id": 1, "result": {"content": [{"type": "text", "text": "..."}]}}
```
