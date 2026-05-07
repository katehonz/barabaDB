# Vektör Arama Motoru

Benzerlik araması için HNSW ve IVF-PQ indeksleri.

## Kullanım

```nim
import barabadb/vector/engine

var idx = newHNSWIndex(dimensions = 128)
idx.insert(1, @[1.0'f32, 0.0'f32, ...], {"category": "A"}.toTable)

let results = idx.search(queryVector, k = 10)
```

## İndeks Türleri

### HNSW

Hiyerarşik Navigable Small World grafiği.

```nim
var hnsw = newHNSWIndex(
  dimensions = 128,
  m = 16,
  efConstruction = 200,
  efSearch = 100
)
```

### IVF-PQ

Ürün nicemleme ile Ters Dosya İndeksi.

```nim
var ivfpq = newIVFPQIndex(
  dimensions = 128,
  numCentroids = 256,
  subQuantizers = 8
)
```

## Mesafe Metrikleri

| Metrik | Açıklama |
|--------|----------|
| `cosine` | Kosinüs benzerliği |
| `euclidean` | L2 mesafesi |
| `dotproduct` | Nokta çarpımı |
| `manhattan` | L1 mesafesi |

## Nicemleme

```nim
let scalar = scalarQuantize(data, bits = 8)
let pq = productQuantize(data, subVectors = 8, bits = 8)
```

## SIMD Hızlandırma

```nim
import barabadb/vector/simd

let dist = simdCosineDistance(vec1, vec2)
```