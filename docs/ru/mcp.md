# MCP Сервер (Model Context Protocol)

BaraDB включает встроенный MCP-сервер, который позволяет агентам AI (Claude, Cursor и т.д.) взаимодействовать с базой данных напрямую.

## Быстрый старт

```bash
./build/baramcp --data-dir ./data
```

Запускается в режиме STDIO, принимая сообщения JSON-RPC 2.0 на stdin.

## Доступные инструменты

### 1. `query` — Выполнение SQL

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

Параметризованные запросы с `?` placeholders. Multi-tenant поддержка через `tenant_id` и `user_id`.

### 2. `vector_search` — Семантический поиск

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

Метрики: `cosine`, `euclidean`, `dot_product`, `manhattan`.

### 3. `schema_inspect` — Исследование схемы

```json
{
  "name": "schema_inspect",
  "arguments": {
    "table": "users",
    "tenant_id": "company-a"
  }
}
```

Возвращает таблицы, столбцы, типы, первичные ключи, внешние ключи, индексы и RLS-политики.

## Конфигурация в Claude Desktop

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

## Конфигурация в Cursor

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

## Multi-Tenant изоляция

Каждый MCP-запрос может включать `tenant_id` и `user_id`, установленные как переменные сессии:
- `app.tenant_id` — для RLS-фильтрации
- `app.user_id` — для ссылок `current_user`

RLS-политики автоматически фильтруют данные на основе этих переменных.

## Протокол JSON-RPC 2.0

Сервер использует JSON-RPC 2.0 через STDIO:

```json
// Запрос
{"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {...}}

// Ответ
{"jsonrpc": "2.0", "id": 1, "result": {"content": [{"type": "text", "text": "..."}]}}
```
