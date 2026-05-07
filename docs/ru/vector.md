# Векторный движок

Родные индексы HNSW и IVF-PQ для поиска по сходству.

## Использование

```nim
import barabadb/vector/engine

var idx = newHNSWIndex(dimensions = 128)
idx.insert(1, @[1.0'f32, 0.0'f32, ...], {"category": "A"}.toTable)

let results = idx.search(queryVector, k = 10)

let filtered = idx.searchWithFilter(queryVector, k = 10,
  filter = proc(meta: Table[string, string]): bool =
    return meta.getOrDefault("category") == "A")
```

## Типы индексов

### HNSW

Иерархический навигируемый граф малого мира для приближенного поиска ближайших соседей.

```nim
var hnsw = newHNSWIndex(
  dimensions = 128,
  m = 16,
  efConstruction = 200,
  efSearch = 100
)
```

### IVF-PQ

Инвертированный файловый индекс с продуктовым квантованием.

```nim
var ivfpq = newIVFPQIndex(
  dimensions = 128,
  numCentroids = 256,
  subQuantizers = 8
)
```

## Метрики расстояния

| Метрика | Описание |
|---------|---------|
| `cosine` | Косинусное сходство |
| `euclidean` | L2 расстояние |
| `dotproduct` | Скалярное произведение |
| `manhattan` | L1 расстояние |

## Квантование

```nim
import barabadb/vector/quant

let scalar = scalarQuantize(data, bits = 8)
let pq = productQuantize(data, subVectors = 8, bits = 8)
```

## SIMD ускорение

```nim
import barabadb/vector/simd

let dist = simdCosineDistance(vec1, vec2)
```