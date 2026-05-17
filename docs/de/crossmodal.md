# Cross-Modal Abfragen

BaraDB's einzigartige Fähigkeit ist die Ausführung von Abfragen, die mehrere
Speicher-Engines in einer einzigen vereinheitlichten BaraQL-Anweisung umfassen.

## Überblick

Traditionelle Datenbanken erfordern separate Abfragen und applikationsseitige Joins
bei der Arbeit mit verschiedenen Datenmodellen. BaraDB's Cross-Modal Query Planner
optimiert die Ausführung über:

- **Document/KV** (LSM-Tree) — strukturierte Datensätze
- **Graph** (Adjacency List) — Beziehungen
- **Vector** (HNSW/IVF-PQ) — Ähnlichkeitssuche
- **Full-Text** (Inverted Index) — Textsuche
- **Columnar** — analytische Aggregatfunktionen

## Abfragemuster

### Vector + Full-Text (Semantisch + Schlüsselwortsuche)

Finde Dokumente, die semantisch ähnlich zu einem Query-Vektor sind UND
bestimmte Schlüsselwörter enthalten:

```sql
SELECT title, score
FROM articles
WHERE MATCH(body) AGAINST('machine learning')
ORDER BY cosine_distance(embedding, [0.1, 0.2, 0.3, ...])
LIMIT 10;
```

Ausführungsplan:
1. FTS-Engine filtert Artikel mit "machine learning"
2. Vector-Engine rankt gefilterte Ergebnisse nach Embedding-Ähnlichkeit
3. Top-K Ergebnisse zurückgegeben

### Graph + Vector (Soziale Empfehlungen)

Finde Freunde eines Benutzers mit ähnlichen Geschmacksvektoren:

```sql
MATCH (u:User)-[:KNOWS]->(friend:User)
WHERE u.name = 'Alice'
ORDER BY cosine_distance(friend.taste_vector, u.taste_vector)
RETURN friend.name, friend.age;
```

Ausführungsplan:
1. Graph-Engine traversiert "KNOWS"-Kanten von Alice
2. Vector-Engine berechnet Ähnlichkeit für jeden Freund
3. Ergebnisse sortiert und projiziert

### Document + Graph (Entity-Anreicherung)

Erhalte Bestelldetails mit Kunden-Beziehungsgraph:

```sql
SELECT o.id, o.total, c.name,
       (SELECT count(*) FROM orders WHERE customer_id = c.id) as order_count
FROM orders o
JOIN customers c ON o.customer_id = c.id
WHERE c.id IN (
  SELECT node_id FROM graph
  WHERE MATCH pattern (c:Customer)-[:REFERRED]->(:Customer)
);
```

### Full-Text + Aggregate (Content-Analyse)

Analysiere welche Abteilungen am meisten über ein Thema schreiben:

```sql
SELECT department, count(*) as article_count,
       avg(length(content)) as avg_length
FROM docs
WHERE MATCH(content) AGAINST('Nim programming')
GROUP BY department
ORDER BY article_count DESC;
```

### Vector + Aggregate (Cluster-Analyse)

Gruppiere ähnliche Vektoren und analysiere jedes Cluster:

```sql
SELECT cluster_id, count(*) as size,
       centroid(embedding) as center,
       avg(created_at) as avg_date
FROM products
GROUP BY vector_cluster(embedding, k=10)
ORDER BY size DESC;
```

### Alle Modalitäten kombiniert

Eine komplexe Abfrage unter Verwendung aller Engines:

```sql
WITH relevant_docs AS (
  SELECT id, title, embedding
  FROM articles
  WHERE MATCH(body) AGAINST('database optimization')
    AND created_at > '2024-01-01'
),
author_graph AS (
  MATCH (a:Author)-[:COAUTHORED]->(b:Author)
  WHERE a.name = 'Dr. Smith'
  RETURN b.id as coauthor_id
)
SELECT rd.title, rd.score,
       a.name as author,
       cosine_distance(rd.embedding, query_vec) as similarity
FROM relevant_docs rd
JOIN authors a ON rd.author_id = a.id
WHERE a.id IN (SELECT coauthor_id FROM author_graph)
ORDER BY similarity ASC, rd.score DESC
LIMIT 20;
```

## Optimierung

### Cross-Modal Query Planner

BaraDB's adaptiver Query-Optimizer (`query/adaptive.nim`) wählt die Ausführungsreihenfolge basierend auf Selektivität:

```
1. Selektivstes Filter zuerst (normalerweise FTS oder Vector)
2. Prädikate zu jeder Engine pushen
3. Bloom-Filter für KV-Lookups verwenden
4. Unabhängige Zweige parallelisieren
```

### Index-Auswahl

Der Optimizer wählt automatisch den besten Index:

| Abfragemuster | Primäre Engine | Sekundäre Engine |
|---------------|----------------|-----------------|
| `MATCH ... ORDER BY cosine_distance` | Vector | FTS |
| `MATCH ... WHERE graph condition` | Graph | FTS |
| `WHERE id = ? AND vector_search` | KV | Vector |
| `GROUP BY + MATCH` | FTS | Columnar |

### Hints

Bestimmte Ausführungsreihenfolge erzwingen:

```sql
SELECT /*+ USE_INDEX(vector) */ *
FROM products
WHERE category = 'electronics'
ORDER BY cosine_distance(embedding, [...])
LIMIT 10;
```

## Performance

Cross-Modal Abfragen sind optimiert um Datenbewegung zu minimieren:

| Abfragetyp | Latenz (10K Zeilen) | Latenz (100K Zeilen) |
|------------|---------------------|----------------------|
| FTS + Vector | 15 ms | 85 ms |
| Graph + Vector | 25 ms | 120 ms |
| FTS + Aggregate | 12 ms | 55 ms |
| Alle Modalitäten | 45 ms | 220 ms |

## Anwendungsfälle

### E-Commerce Suche

```sql
-- Finde Produkte passend zu einem Suchbegriff, ähnlich zu einem betrachteten Artikel,
-- gekauft von ähnlichen Benutzern
SELECT p.name, p.price
FROM products p
WHERE MATCH(p.description) AGAINST('wireless headphones')
  AND cosine_distance(p.embedding, viewed_embedding) < 0.3
  AND p.id IN (
    SELECT product_id FROM orders o
    JOIN graph ON o.customer_id = graph.node_id
    WHERE graph.similarity > 0.8
  )
ORDER BY p.rating DESC
LIMIT 20;
```

### Betrugserkennung

```sql
-- Finde Transaktionen ähnlich zu bekannten Betrugsmustern,
-- wo der Benutzer mit markierten Konten verbunden ist
SELECT t.id, t.amount
FROM transactions t
WHERE cosine_distance(t.pattern_vector, fraud_vector) < 0.2
  AND t.user_id IN (
    MATCH (u:User)-[*1..3]->(f:FlaggedAccount)
    RETURN u.id
  );
```

### Knowledge Graph + RAG

```sql
-- Relevante Dokumente für eine Query abrufen,
-- dann den Knowledge Graph für verwandte Konzepte traversieren
WITH docs AS (
  SELECT id, content, embedding
  FROM documents
  ORDER BY cosine_distance(embedding, query_embedding)
  LIMIT 5
)
SELECT d.content, c.name as related_concept
FROM docs d
JOIN graph ON d.id = graph.doc_id
MATCH (d)-[:MENTIONS]->(c:Concept)
RETURN d.content, c.name;
```
