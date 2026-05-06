# Cross-Modal Queries

BaraDB's unique capability is executing queries that span multiple storage
engines in a single unified BaraQL statement.

## Overview

Traditional databases require separate queries and application-level joins
when working with different data models. BaraDB's cross-modal query planner
optimizes execution across:

- **Document/KV** (LSM-Tree) — structured records
- **Graph** (Adjacency List) — relationships
- **Vector** (HNSW/IVF-PQ) — similarity search
- **Full-Text** (Inverted Index) — text search
- **Columnar** — analytical aggregates

## Query Patterns

### Vector + Full-Text (Semantic + Keyword Search)

Find documents that are semantically similar to a query vector AND contain
specific keywords:

```sql
SELECT title, score
FROM articles
WHERE MATCH(body) AGAINST('machine learning')
ORDER BY cosine_distance(embedding, [0.1, 0.2, 0.3, ...])
LIMIT 10;
```

Execution plan:
1. FTS engine filters articles matching "machine learning"
2. Vector engine ranks filtered results by embedding similarity
3. Top-K results returned

### Graph + Vector (Social Recommendations)

Find friends of a user with similar taste vectors:

```sql
MATCH (u:User)-[:KNOWS]->(friend:User)
WHERE u.name = 'Alice'
ORDER BY cosine_distance(friend.taste_vector, u.taste_vector)
RETURN friend.name, friend.age;
```

Execution plan:
1. Graph engine traverses "KNOWS" edges from Alice
2. Vector engine computes similarity for each friend
3. Results sorted and projected

### Document + Graph (Entity Enrichment)

Get order details with customer relationship graph:

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

### Full-Text + Aggregate (Content Analytics)

Analyze which departments write most about a topic:

```sql
SELECT department, count(*) as article_count,
       avg(length(content)) as avg_length
FROM docs
WHERE MATCH(content) AGAINST('Nim programming')
GROUP BY department
ORDER BY article_count DESC;
```

### Vector + Aggregate (Cluster Analysis)

Group similar vectors and analyze each cluster:

```sql
SELECT cluster_id, count(*) as size,
       centroid(embedding) as center,
       avg(created_at) as avg_date
FROM products
GROUP BY vector_cluster(embedding, k=10)
ORDER BY size DESC;
```

### All Modalities Combined

A complex query using all engines:

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

## Optimization

### Cross-Modal Query Planner

BaraDB's adaptive query optimizer (`query/adaptive.nim`) chooses execution
order based on selectivity:

```
1. Most selective filter first (usually FTS or vector)
2. Push down predicates to each engine
3. Use bloom filters for KV lookups
4. Parallelize independent branches
```

### Index Selection

The optimizer automatically selects the best index:

| Query Pattern | Primary Engine | Secondary Engine |
|---------------|----------------|------------------|
| `MATCH ... ORDER BY cosine_distance` | Vector | FTS |
| `MATCH ... WHERE graph condition` | Graph | FTS |
| `WHERE id = ? AND vector_search` | KV | Vector |
| `GROUP BY + MATCH` | FTS | Columnar |

### Hints

Force a specific execution order:

```sql
SELECT /*+ USE_INDEX(vector) */ *
FROM products
WHERE category = 'electronics'
ORDER BY cosine_distance(embedding, [...])
LIMIT 10;
```

## Performance

Cross-modal queries are optimized to minimize data movement:

| Query Type | Latency (10K rows) | Latency (100K rows) |
|------------|--------------------|---------------------|
| FTS + Vector | 15 ms | 85 ms |
| Graph + Vector | 25 ms | 120 ms |
| FTS + Aggregate | 12 ms | 55 ms |
| All modalities | 45 ms | 220 ms |

## Use Cases

### E-Commerce Search

```sql
-- Find products matching a search term, similar to a viewed item,
-- purchased by similar users
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

### Fraud Detection

```sql
-- Find transactions similar to known fraud patterns
-- where the user is connected to flagged accounts
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
-- Retrieve relevant documents for a query,
-- then traverse the knowledge graph for related concepts
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
