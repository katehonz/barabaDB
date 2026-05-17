# MCP Server (Model Context Protocol)

BaraDB includes a built-in MCP server that enables AI agents (Claude, Cursor, etc.)
to interact with the database directly.

## Quick Start

```bash
./build/baramcp --data-dir ./data
```

Starts in STDIO mode, accepting JSON-RPC 2.0 messages on stdin.

## Available Tools

### 1. `query` — SQL Execution

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

Parameterized queries using `?` placeholders. Multi-tenant via `tenant_id` and `user_id`.

### 2. `vector_search` — Semantic Search

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

Metrics: `cosine`, `euclidean`, `dot_product`, `manhattan`.

### 3. `schema_inspect` — Schema Exploration

```json
{
  "name": "schema_inspect",
  "arguments": {
    "table": "users",
    "tenant_id": "company-a"
  }
}
```

Returns tables, columns, types, primary keys, foreign keys, indexes, and RLS policies.

## Claude Desktop Configuration

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

## Cursor Configuration

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

## Multi-Tenant Isolation

Each MCP request can include `tenant_id` and `user_id`, set as session variables:
- `app.tenant_id` — for RLS filtering
- `app.user_id` — for `current_user` references

RLS policies automatically filter data based on these variables.

## JSON-RPC 2.0 Protocol

The server uses JSON-RPC 2.0 over STDIO:

```json
// Request
{"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {...}}

// Response
{"jsonrpc": "2.0", "id": 1, "result": {"content": [{"type": "text", "text": "..."}]}}
```
