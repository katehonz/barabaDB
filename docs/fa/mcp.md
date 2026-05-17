# سرور MCP (Model Context Protocol)

BaraDB شامل یک سرور MCP داخلی است که به عوامل هوش مصنوعی (Claude، Cursor و غیره) امکان تعامل مستقیم با پایگاه داده را می‌دهد.

## شروع سریع

```bash
./build/baramcp --data-dir ./data
```

در حالت STDIO شروع می‌شود و پیام‌های JSON-RPC 2.0 را در stdin قبول می‌کند.

## ابزارهای موجود

### 1. `query` — اجرای SQL

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

پرس‌وجوهای پارامتری با `?` placeholders. پشتیبانی multi-tenant از طریق `tenant_id` و `user_id`.

### 2. `vector_search` — جستجوی معنایی

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

معیارها: `cosine`، `euclidean`، `dot_product`، `manhattan`.

### 3. `schema_inspect` — بررسی طرحواره

```json
{
  "name": "schema_inspect",
  "arguments": {
    "table": "users",
    "tenant_id": "company-a"
  }
}
```

جداول، ستون‌ها، انواع، کلیدهای اصلی، کلیدهای خارجی، شاخص‌ها و سیاست‌های RLS را برمی‌گرداند.

## پیکربندی Claude Desktop

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

## پیکربندی Cursor

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

## جداسازی Multi-Tenant

هر درخواست MCP می‌تواند شامل `tenant_id` و `user_id` باشد که به عنوان متغیرهای session تنظیم می‌شوند:
- `app.tenant_id` — برای فیلتر RLS
- `app.user_id` — برای referencهای `current_user`

سیاست‌های RLS به طور خودکار داده‌ها را بر اساس این متغیرها فیلتر می‌کنند.

## پروتکل JSON-RPC 2.0

سرور از JSON-RPC 2.0 از طریق STDIO استفاده می‌کند:

```json
// درخواست
{"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {...}}

// پاسخ
{"jsonrpc": "2.0", "id": 1, "result": {"content": [{"type": "text", "text": "..."}]}}
```
