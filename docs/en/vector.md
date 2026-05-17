# Vector Search Engine

Native HNSW and IVF-PQ indexes for similarity search with full SQL integration.
Includes AI pipeline for chunking, embedding, and hybrid RAG search.

## SQL Usage

### Creating Vector Columns

```sql
CREATE TABLE items (
    id INT PRIMARY KEY,
    embedding VECTOR(768)
);
```

The `VECTOR(n)` type stores float32 arrays of fixed dimension `n`.

### Inserting Vectors

```sql
INSERT INTO items (id, embedding) VALUES (1, '[0.1, 0.2, 0.3, ...]');
```

### Vector Distance Functions

```sql
-- Cosine distance (0 = identical, 1 = orthogonal)
SELECT id, cosine_distance(embedding, '[0.1, 0.2, 0.3]') AS dist FROM items;

-- Euclidean / L2 distance
SELECT id, euclidean_distance(embedding, '[0.1, 0.2, 0.3]') AS dist FROM items;
SELECT id, embedding <-> '[0.1, 0.2, 0.3]' AS dist FROM items;

-- Inner product (negative for minimization)
SELECT id, inner_product(embedding, '[0.1, 0.2, 0.3]') AS dist FROM items;

-- Manhattan / L1 distance
SELECT id, l1_distance(embedding, '[0.1, 0.2, 0.3]') AS dist FROM items;
```

### Nearest Neighbor Search

```sql
-- Top-10 nearest neighbors by cosine distance
SELECT id FROM items
ORDER BY cosine_distance(embedding, '[0.1, 0.2, 0.3]') ASC
LIMIT 10;
```

### Vector Indexes

```sql
-- Create HNSW index
CREATE INDEX idx_items_vec ON items(embedding) USING hnsw;
-- Index is automatically maintained on INSERT and UPDATE
```

## Hybrid RAG Search

```sql
-- Combined vector + FTS search with Reciprocal Rank Fusion reranking
SELECT hybrid_search('AI query', embedding, content, 10) AS result;

-- Filtered hybrid search
SELECT hybrid_search_filtered('AI query', embedding, content, 10, 'category', 'news') AS result;

-- Comma-separated IDs only
SELECT hybrid_search_ids('AI query', embedding, content, 10) AS result;
```

## AI Pipeline

### Text Chunking

```sql
-- Split text into overlapping chunks (max 1024 chars, 128 overlap)
SELECT chunk('Long text content here...', 1024, 128) AS result;

-- Returns: [{"index":0, "text":"...", "size":124}, ...]
```

Strategies: `paragraph`, `sentence`, `fixed`, `recursive` (default).

### Embedding Generation

```sql
-- Call external embedding service for a query vector
SELECT embed_text('query text here') AS result;
```

Configure the embedder via environment variables:
```bash
export BARADB_EMBED_ENDPOINT=http://localhost:11434/api/embeddings
export BARADB_EMBED_MODEL=nomic-embed-text
export BARADB_EMBED_API_KEY=sk-...  # optional, for OpenAI
```

### Auto-Embedding on INSERT

When a VECTOR column is NULL on INSERT but a TEXT column has content, the embedding
is automatically generated (if an embedder is configured):

```sql
CREATE TABLE docs (id INTEGER PRIMARY KEY, content TEXT, embedding VECTOR(768));
CREATE INDEX docs_vec ON docs(embedding) USING hnsw;

-- embedding is automatically populated
INSERT INTO docs (id, content) VALUES (1, 'This text will be auto-embedded');
```

## Natural Language → SQL

```sql
-- Generate schema prompt for LLM context
SELECT schema_prompt('users') AS result;

-- Natural language to SQL (requires configured LLM)
SELECT nl_to_sql('Show all users over 25 years old', 'users') AS result;
```

LLM configuration:
```bash
export BARADB_LLM_ENDPOINT=http://localhost:11434/api/generate
export BARADB_LLM_MODEL=llama3
export BARADB_LLM_API_KEY=sk-...  # optional
```

## Distance Metrics

| Metric | SQL Function | Description |
|--------|--------------|-------------|
| `cosine` | `cosine_distance(a, b)` | Cosine dissimilarity (1 - similarity) |
| `euclidean` | `euclidean_distance(a, b)` / `<->` | L2 distance |
| `dotproduct` | `inner_product(a, b)` | Negative dot product |
| `manhattan` | `l1_distance(a, b)` | L1 distance |

## Native Nim API

```nim
import barabadb/vector/engine

var idx = newHNSWIndex(dimensions = 128)
idx.insert(1, @[1.0'f32, 0.0'f32, ...], {"category": "A"}.toTable)
let results = idx.search(queryVector, k = 10)
let filtered = idx.searchWithFilter(queryVector, k = 10,
    filter = proc(meta: Table[string, string]): bool = "category" in meta)
```

## Index Types

### HNSW (Default)

```nim
var hnsw = newHNSWIndex(dimensions = 128, m = 16, efConstruction = 200)
```

### IVF-PQ

```nim
var ivfpq = newIVFPQIndex(dimensions = 128, numCentroids = 256, subQuantizers = 8)
```

## Quantization

```nim
import barabadb/vector/quant
let scalar = scalarQuantize(data, bits = 8)
let pq = productQuantize(data, subVectors = 8, bits = 8)
```

## SIMD Acceleration

```nim
import barabadb/vector/simd
let dist = simdCosineDistance(vec1, vec2)
```
