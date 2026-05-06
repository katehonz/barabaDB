# Vector Search Engine

Native HNSW and IVF-PQ indexes for similarity search.

## Usage

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

| Metric | Description |
|--------|-------------|
| `cosine` | Cosine similarity |
| `euclidean` | L2 distance |
| `dotproduct` | Dot product similarity |
| `manhattan` | L1 distance |

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