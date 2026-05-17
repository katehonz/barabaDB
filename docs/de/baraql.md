# BaraQL — Abfragesprache-Referenz

BaraQL ist eine SQL-kompatible Abfragesprache mit Erweiterungen für Graph-, Vektor- und Dokumentoperationen.

## Datentypen

| Typ | Beschreibung | Beispiel |
|------|-------------|---------|
| `null` | Nullwert | `null` |
| `bool` | Boolean | `true`, `false` |
| `int64` | 64-bit Ganzzahl | `42` |
| `float64` | 64-bit Fließkomma | `3.14` |
| `str` | UTF-8 String | `'hello'` |
| `vector(n)` | Float32 Vektor | `VECTOR(768)` |
| `json` | JSON-Dokument | `{"key": "value"}` |

## Grundlegende Abfragen

```sql
SELECT * FROM users;
SELECT name, age FROM users WHERE age > 18;
SELECT * FROM users ORDER BY age DESC LIMIT 10;
```

## Vektor-Operationen

```sql
-- Distanzberechnungen
SELECT cosine_distance(embedding, '[0.1, 0.2, 0.3]') AS dist FROM items;
SELECT embedding <-> '[0.1, 0.2, 0.3]' AS dist FROM items;

-- Hybride Suche
SELECT hybrid_search('query', embedding, content, 10) AS result;
```

## Graph-Operationen

```sql
CREATE GRAPH social;
DROP GRAPH social;

-- Traversierung
SELECT * FROM GRAPH_TABLE(social MATCH (n)-[r]->(m)
    ALGORITHM bfs START 1
    COLUMNS (id, node_label));

-- PageRank
SELECT * FROM GRAPH_TABLE(social ALGORITHM pagerank
    COLUMNS (id, node_label, rank));

-- Community Detection
SELECT * FROM GRAPH_TABLE(social ALGORITHM community
    COLUMNS (id, node_label, community));
```

## AI-Funktionen

```sql
-- Text in Chunks zerlegen
SELECT chunk('Langer Text...', 1024, 128) AS result;

-- Embedding generieren
SELECT embed_text('Suchtext') AS result;

-- Natural Language → SQL
SELECT nl_to_sql('Zeige alle Benutzer über 25', 'users') AS result;

-- Schema-Prompt für LLM
SELECT schema_prompt('users') AS result;

-- Cypher-Übersetzung
SELECT cypher('MATCH (a)-[r]->(b) RETURN a.node_label') AS result;

-- Knotenähnlichkeit
SELECT similarity_nodes('social', 'jaccard') AS result;

-- Graph-Embeddings
SELECT node2vec_embed('social', 64) AS result;
```

## Joins

```sql
SELECT u.name, o.amount
FROM users u
INNER JOIN orders o ON u.id = o.user_id;
```

## Aggregation

```sql
SELECT department, COUNT(*), AVG(salary)
FROM employees
GROUP BY department
HAVING COUNT(*) > 5;
```

## Index-Erstellung

```sql
CREATE INDEX idx_name ON users(name) USING btree;
CREATE INDEX idx_vec ON docs(embedding) USING hnsw;
CREATE INDEX idx_fts ON docs(content) USING fts;
```

## Multi-Tenant / RLS

```sql
CREATE POLICY tenant_policy ON orders
FOR ALL USING (tenant_id = current_setting('app.tenant_id'));

SET app.tenant_id = 'company-a';
SELECT * FROM orders;  -- Automatisch gefiltert
```
