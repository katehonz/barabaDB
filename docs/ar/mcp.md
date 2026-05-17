# خادم MCP (Model Context Protocol)

يتضمن BaraDB خادم MCP مدمج يمكّن وكلاء الذكاء الاصطناعي (Claude و Cursor وما إلى ذلك) من التفاعل مع قاعدة البيانات مباشرة.

## البداية السريعة

```bash
./build/baramcp --data-dir ./data
```

يبدأ في وضع STDIO، يقبل رسائل JSON-RPC 2.0 على stdin.

## الأدوات المتاحة

### 1. `query` — تنفيذ SQL

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

استعلامات معاملية باستخدام `?` placeholders. دعم multi-tenant عبر `tenant_id` و `user_id`.

### 2. `vector_search` — البحث الدلالي

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

المقاييس: `cosine`، `euclidean`، `dot_product`، `manhattan`.

### 3. `schema_inspect` — استكشاف المخطط

```json
{
  "name": "schema_inspect",
  "arguments": {
    "table": "users",
    "tenant_id": "company-a"
  }
}
```

إرجاع الجداول والأعمدة والأنواع والمفاتيح الأساسية والمفاتيح الخارجية والفهارس وسياسات RLS.

## تكوين Claude Desktop

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

## تكوين Cursor

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

## عزل Multi-Tenant

يمكن أن يتضمن كل طلب MCP قيمة `tenant_id` و `user_id`، والتي يتم تعيينها كمتغيرات جلسة:
- `app.tenant_id` — للترشيح RLS
- `app.user_id` — لمراجع `current_user`

تقوم سياسات RLS بتصفية البيانات تلقائياً بناءً على هذه المتغيرات.

## بروتوكول JSON-RPC 2.0

يستخدم الخادم JSON-RPC 2.0 عبر STDIO:

```json
// الطلب
{"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {...}}

// الاستجابة
{"jsonrpc": "2.0", "id": 1, "result": {"content": [{"type": "text", "text": "..."}]}}
```
