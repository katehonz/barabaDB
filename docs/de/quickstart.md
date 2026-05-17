# BaraDB — Schnellstart

## Server starten

```bash
./build/baradadb
```

Der Server startet standardmäßig auf `localhost:9470`.

## Verbindung via CLI

```bash
./build/baradadb --shell
```

## MCP Server (AI Agenten)

```bash
./build/baramcp --data-dir ./data
```

Der MCP Server startet im STDIO-Modus und stellt 3 Tools für AI-Agenten bereit: `query`, `vector_search`, `schema_inspect`.

## Grundlegende Operationen

### Tabelle erstellen

```sql
CREATE TABLE users (
    id INTEGER PRIMARY KEY,
    name TEXT,
    email TEXT,
    age INTEGER
);
```

### Daten einfügen

```sql
INSERT INTO users (id, name, email, age) VALUES (1, 'Alice', 'alice@test.com', 30);
INSERT INTO users (id, name, email, age) VALUES (2, 'Bob', 'bob@test.com', 25);
```

### Daten abfragen

```sql
SELECT name, age FROM users WHERE age > 18;
```

### Indizes erstellen

```sql
-- BTree Index
CREATE INDEX idx_name ON users(name) USING btree;

-- Volltext-Index
CREATE INDEX idx_email_fts ON users(email) USING fts;

-- Vektor-Index
CREATE INDEX idx_vec ON items(embedding) USING hnsw;
```

## Vector Search

```sql
CREATE TABLE docs (id INTEGER PRIMARY KEY, content TEXT, embedding VECTOR(768));
CREATE INDEX docs_vec ON docs(embedding) USING hnsw;

-- Ähnlichkeitssuche
SELECT id, cosine_distance(embedding, '[0.1, 0.2, ...]') AS dist
FROM docs ORDER BY dist ASC LIMIT 10;
```

## Graph Engine

```sql
CREATE GRAPH social;
INSERT INTO social_nodes (id, node_label) VALUES (1, 'Alice'), (2, 'Bob');
INSERT INTO social_edges (source_id, dest_id) VALUES (1, 2);

-- BFS Traversal
SELECT * FROM GRAPH_TABLE(social MATCH (n)-[r]->(m) ALGORITHM bfs COLUMNS (id, node_label));

-- PageRank
SELECT * FROM GRAPH_TABLE(social ALGORITHM pagerank COLUMNS (id, node_label, rank));

-- Community Detection (Louvain)
SELECT * FROM GRAPH_TABLE(social ALGORITHM community COLUMNS (id, node_label, community));

-- Kürzester Pfad
SELECT * FROM GRAPH_TABLE(social ALGORITHM shortest_path START 1 END 2 COLUMNS (id, node_label));

-- Knoten-Ähnlichkeit (Jaccard)
SELECT similarity_nodes('social', 'jaccard') AS result;
```

## AI Pipeline

```sql
-- Text in Chunks zerlegen
SELECT chunk('Langer Text hier...', 1024, 128) AS result;

-- Embedding generieren (mit konfiguriertem externen Service)
SELECT embed_text('Suchanfrage') AS result;

-- Schema-Prompt für LLM generieren
SELECT schema_prompt('users') AS result;

-- Natural Language → SQL (mit konfiguriertem LLM)
SELECT nl_to_sql('Zeige alle Benutzer über 25', 'users') AS result;

-- Cypher zu BaraQL übersetzen
SELECT cypher('MATCH (a)-[r]->(b) RETURN a.node_label, b.node_label') AS result;
```

## HTTP/REST API

```bash
curl -X POST http://localhost:9470/query \
  -H "Content-Type: application/json" \
  -d '{"query": "SELECT * FROM users"}'
```

## Konfiguration

```bash
# Umgebungsvariablen
export BARADB_DATA_DIR=./data
export BARADB_EMBED_ENDPOINT=http://localhost:11434/api/embeddings
export BARADB_EMBED_MODEL=nomic-embed-text
export BARADB_LLM_ENDPOINT=http://localhost:11434/api/generate
export BARADB_LLM_MODEL=llama3
```
