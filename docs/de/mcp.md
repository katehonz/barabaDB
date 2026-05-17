# MCP Server (Model Context Protocol)

BaraDB enthält einen eingebauten MCP-Server, der es AI-Agenten (Claude, Cursor, etc.) ermöglicht, direkt mit der Datenbank zu interagieren.

## Schnellstart

```bash
./build/baramcp --data-dir ./data
```

Der Server startet im STDIO-Modus und akzeptiert JSON-RPC 2.0 Nachrichten.

## Verfügbare Tools

### 1. `query` — SQL ausführen

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

Parameterisierte Abfragen mit `?`-Platzhaltern. Multi-Tenant-Support über `tenant_id` und `user_id`.

### 2. `vector_search` — Semantische Suche

```json
{
  "name": "vector_search",
  "arguments": {
    "table": "docs",
    "column": "embedding",
    "query_vector": [0.1, 0.2, 0.3],
    "k": 5,
    "metric": "cosine",
    "tenant_id": "company-a"
  }
}
```

Unterstützte Metriken: `cosine`, `euclidean`, `dot_product`, `manhattan`.

### 3. `schema_inspect` — Schema erkunden

```json
{
  "name": "schema_inspect",
  "arguments": {
    "table": "users",
    "tenant_id": "company-a"
  }
}
```

Gibt Tabellen, Spalten, Typen, Primärschlüssel, Fremdschlüssel, Indizes und RLS-Policies zurück.

## Konfiguration in Claude Desktop

```json
{
  "mcpServers": {
    "baradb": {
      "command": "/pfad/zu/build/baramcp",
      "args": ["--data-dir", "/pfad/zu/daten"]
    }
  }
}
```

## Konfiguration in Cursor

```json
{
  "mcpServers": {
    "baradb": {
      "command": "/pfad/zu/build/baramcp",
      "args": ["--data-dir", "~/.baradb/data"]
    }
  }
}
```

## Multi-Tenant Isolation

Jede MCP-Anfrage kann `tenant_id` und `user_id` enthalten. Diese werden als Session-Variablen gesetzt:

- `app.tenant_id` — für RLS-Filterung
- `app.user_id` — für `current_user`-Referenzen

RLS-Policies filtern die Daten automatisch basierend auf diesen Variablen.

## JSON-RPC 2.0 Protokoll

Der Server verwendet JSON-RPC 2.0 über STDIO:

```json
// Anfrage
{"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {...}}

// Antwort
{"jsonrpc": "2.0", "id": 1, "result": {"content": [{"type": "text", "text": "..."}]}}
```
