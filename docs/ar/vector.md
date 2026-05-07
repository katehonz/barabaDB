# محرك البحث المتجهي

فهارس HNSW و IVF-PQ للبحث عن التشابه.

## الاستخدام

```nim
import barabadb/vector/engine

var idx = newHNSWIndex(dimensions = 128)
idx.insert(1, @[1.0'f32, 0.0'f32, ...], {"category": "A"}.toTable)

let results = idx.search(queryVector, k = 10)
```

## أنواع الفهارس

### HNSW

رسم بياني Small World قابل للملاحة هرمي للبحث عن أقرب الجيران.

```nim
var hnsw = newHNSWIndex(
  dimensions = 128,
  m = 16,
  efConstruction = 200,
  efSearch = 100
)
```

### IVF-PQ

فهرس ملف مقلوب مع تكميم المنتج.

```nim
var ivfpq = newIVFPQIndex(
  dimensions = 128,
  numCentroids = 256,
  subQuantizers = 8
)
```

## مقاييس المسافة

| المقياس | الوصف |
|---------|-------|
| `cosine` | تشابه جيب التمام |
| `euclidean` | مسافة L2 |
| `dotproduct` | تشابه المنتج النقطي |
| `manhattan` | مسافة L1 |

## التكميم

```nim
let scalar = scalarQuantize(data, bits = 8)
let pq = productQuantize(data, subVectors = 8, bits = 8)
```

## تسريع SIMD

```nim
import barabadb/vector/simd

let dist = simdCosineDistance(vec1, vec2)
```