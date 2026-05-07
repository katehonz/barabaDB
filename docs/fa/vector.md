# موتور جستجوی برداری

اندیس‌های HNSW و IVF-PQ برای جستجوی شباهت.

## استفاده

```nim
import barabadb/vector/engine

var idx = newHNSWIndex(dimensions = 128)
idx.insert(1, @[1.0'f32, 0.0'f32, ...], {"category": "A"}.toTable)

let results = idx.search(queryVector, k = 10)
```

## انواع اندیس

### HNSW

گراف Navigable Small World سلسله‌مراتبی.

```nim
var hnsw = newHNSWIndex(
  dimensions = 128,
  m = 16,
  efConstruction = 200,
  efSearch = 100
)
```

### IVF-PQ

اندیس فایل معکوس با تکمیم محصول.

```nim
var ivfpq = newIVFPQIndex(
  dimensions = 128,
  numCentroids = 256,
  subQuantizers = 8
)
```

## معیارهای فاصله

| معیار | توضیح |
|-------|--------|
| `cosine` | شباهت کسینوسی |
| `euclidean` | فاصله L2 |
| `dotproduct` | ضرب نقطه‌ای |
| `manhattan` | فاصله L1 |

## کوانتیزاسیون

```nim
let scalar = scalarQuantize(data, bits = 8)
let pq = productQuantize(data, subVectors = 8, bits = 8)
```