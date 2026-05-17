# MCP Sunucusu (Model Context Protocol)

BaraDB, AI ajanlarının (Claude, Cursor vb.) veritabanıyla doğrudan etkileşim kurmasını sağlayan yerleşik bir MCP sunucusu içerir.

## Hızlı Başlangıç

```bash
./build/baramcp --data-dir ./data
```

STDIO modunda başlar, stdin'de JSON-RPC 2.0 mesajlarını kabul eder.

## Mevcut Araçlar

### 1. `query` — SQL Yürütme

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

`?` placeholders kullanarak parametreli sorgular. `tenant_id` ve `user_id` ile multi-tenant desteği.

### 2. `vector_search` — Anlamsal Arama

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

Metrikler: `cosine`, `euclidean`, `dot_product`, `manhattan`.

### 3. `schema_inspect` — Şema Keşfi

```json
{
  "name": "schema_inspect",
  "arguments": {
    "table": "users",
    "tenant_id": "company-a"
  }
}
```

Tabloları, sütunları, tipleri, birincil anahtarları, yabancı anahtarları, indeksleri ve RLS politikalarını döndürür.

## Claude Desktop Yapılandırması

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

## Cursor Yapılandırması

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

## Multi-Tenant İzolasyonu

Her MCP isteği `tenant_id` ve `user_id` içerebilir, bunlar session değişkenleri olarak ayarlanır:
- `app.tenant_id` — RLS filtreleme için
- `app.user_id` — `current_user` referansları için

RLS politikaları bu değişkenlere göre verileri otomatik olarak filtreler.

## JSON-RPC 2.0 Protokolü

Sunucu STDIO üzerinden JSON-RPC 2.0 kullanır:

```json
// İstek
{"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {...}}

// Yanıt
{"jsonrpc": "2.0", "id": 1, "result": {"content": [{"type": "text", "text": "..."}]}}
```
