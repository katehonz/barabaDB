# MCP Сървър (Model Context Protocol)

BaraDB включва вграден MCP сървър, който позволява на AI агенти (Claude, Cursor и др.) да взаимодействат директно с базата данни.

## Бързо Стартиране

```bash
./build/baramcp --data-dir ./data
```

Стартира в STDIO режим, приемащ JSON-RPC 2.0 съобщения на stdin.

## Налични Инструменти

### 1. `query` — Изпълнение на SQL

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

Параметризирани заявки с `?` placeholders. Multi-tenant поддръжка чрез `tenant_id` и `user_id`.

### 2. `vector_search` — Семантично Търсене

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

### 3. `schema_inspect` — Изследване на Схемата

```json
{
  "name": "schema_inspect",
  "arguments": {
    "table": "users",
    "tenant_id": "company-a"
  }
}
```

Връща таблици, колони, типове, първични ключове, външни ключове, индекси и RLS политики.

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

## Multi-Tenant Изолация

Всяка MCP заявка може да включва `tenant_id` и `user_id`, зададени като session variables:
- `app.tenant_id` — за RLS филтриране
- `app.user_id` — за `current_user` референции

RLS политиките автоматично филтрират данните въз основа на тези променливи.

## JSON-RPC 2.0 Протокол

Сървърът използва JSON-RPC 2.0 през STDIO:

```json
// Заявка
{"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {...}}

// Отговор
{"jsonrpc": "2.0", "id": 1, "result": {"content": [{"type": "text", "text": "..."}]}}
```
