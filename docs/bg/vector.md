# Vector Търсене

HNSW и IVF-PQ индекси за търсене на прилика.

## Употреба

```nim
import barabadb/vector/engine

var idx = newHNSWIndex(dimensions = 128)
idx.insert(1, @[1.0'f32, 0.0'f32, ...], {"category": "A"}.toTable)

let results = idx.search(queryVector, k = 10)
```

## Индекс Типове

### HNSW

Иерархичен навигируем малък свят:

```nim
var hnsw = newHNSWIndex(dimensions = 128, m = 16)
```

### IVF-PQ

Инвертиран файл с продуктово квантуване:

```nim
var ivfpq = newIVFPQIndex(dimensions = 128, numCentroids = 256)
```

## Метрики за Разстояние

| Метрика | Описание |
|---------|----------|
| `cosine` | Косинусова прилика |
| `euclidean` | L2 разстояние |
| `dotproduct` | Скаларно произведение |
| `manhattan` | L1 разстояние |