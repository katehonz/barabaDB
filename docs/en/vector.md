# Vector Search Engine

Native HNSW and IVF-PQ indexes for similarity search with full SQL integration.

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
SELECT id, cosine_distance(embedding, '[0.1, 0.2, 0.3]') AS dist
FROM items;

-- Euclidean / L2 distance
SELECT id, euclidean_distance(embedding, '[0.1, 0.2, 0.3]') AS dist
FROM items;

-- L2 distance with <-> operator
SELECT id, embedding <-> '[0.1, 0.2, 0.3]' AS dist
FROM items;

-- Inner product (negative dot product for minimization)
SELECT id, inner_product(embedding, '[0.1, 0.2, 0.3]') AS dist
FROM items;

-- Manhattan / L1 distance
SELECT id, l1_distance(embedding, '[0.1, 0.2, 0.3]') AS dist
FROM items;
```

### Nearest Neighbor Search

```sql
-- Top-10 nearest neighbors by cosine distance
SELECT id FROM items
ORDER BY cosine_distance(embedding, '[0.1, 0.2, 0.3]') ASC
LIMIT 10;

-- Top-5 nearest neighbors by Euclidean distance
SELECT id FROM items
ORDER BY embedding <-> '[0.1, 0.2, 0.3]'
LIMIT 5;
```

### Vector Indexes

```sql
-- Create HNSW index for approximate nearest neighbor search
CREATE INDEX idx_items_vec ON items(embedding) USING hnsw;

-- The index is automatically maintained on INSERT and UPDATE
```

Supported index methods:
- `USING hnsw` — Hierarchical Navigable Small World (default: cosine metric)
- `USING ivfpq` — Inverted File with Product Quantization

### Dimension Validation

BaraDB validates vector dimensions at insert time:

```sql
-- This will fail: expected 768 dimensions but got 3
INSERT INTO items (id, embedding) VALUES (2, '[1.0, 2.0, 3.0]');
```

## Native Nim API

For embedded or high-performance use, use the native Nim API directly:

```nim
import barabadb/vector/engine

var idx = newHNSWIndex(dimensions = 128)
idx.insert(1, @[1.0'f32, 0.0'f32, ...], {"category": "A"}.toTable)

# Search
let results = idx.search(queryVector, k = 10)

# With metadata filtering
let filtered = idx.searchWithFilter(queryVector, k = 10,
  filter = proc(meta: Table[string, string]): bool =
    return meta.getOrDefault("category") == "A")
```

## Index Types

### HNSW

Hierarchical Navigable Small World graph for approximate nearest neighbor search.

```nim
var hnsw = newHNSWIndex(
  dimensions = 128,
  m = 16,           # connections per layer
  efConstruction = 200,  # search width during construction
  efSearch = 100    # search width during query
)
```

### IVF-PQ

Inverted File Index with Product Quantization for compression.

```nim
var ivfpq = newIVFPQIndex(
  dimensions = 128,
  numCentroids = 256,
  subQuantizers = 8
)
```

## Distance Metrics

| Metric | SQL Function | Description |
|--------|--------------|-------------|
| `cosine` | `cosine_distance(a, b)` | Cosine dissimilarity (1 - similarity) |
| `euclidean` | `euclidean_distance(a, b)` / `<->` | L2 distance |
| `dotproduct` | `inner_product(a, b)` | Negative dot product |
| `manhattan` | `l1_distance(a, b)` | L1 distance |

## Quantization

```nim
import barabadb/vector/quant

# Scalar quantization
let scalar = scalarQuantize(data, bits = 8)

# Product quantization
let pq = productQuantize(data, subVectors = 8, bits = 8)
```

## SIMD Acceleration

```nim
import barabadb/vector/simd

let dist = simdCosineDistance(vec1, vec2)
```