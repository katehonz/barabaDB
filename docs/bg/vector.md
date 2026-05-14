# Vector Search Engine

Нативни HNSW и IVF-PQ индекси за търсене на прилика с пълна SQL интеграция.

## SQL Употреба

### Създаване на Векторни Колони

```sql
CREATE TABLE items (
  id INT PRIMARY KEY,
  embedding VECTOR(768)
);
```

Типът `VECTOR(n)` съхранява float32 масиви с фиксирана размерност `n`.

### Вмъкване на Вектори

```sql
INSERT INTO items (id, embedding) VALUES (1, '[0.1, 0.2, 0.3, ...]');
```

### Функции за Векторно Разстояние

```sql
-- Косинусово разстояние (0 = идентични, 1 = ортогонални)
SELECT id, cosine_distance(embedding, '[0.1, 0.2, 0.3]') AS dist
FROM items;

-- Евклидово / L2 разстояние
SELECT id, euclidean_distance(embedding, '[0.1, 0.2, 0.3]') AS dist
FROM items;

-- L2 разстояние с <-> оператор
SELECT id, embedding <-> '[0.1, 0.2, 0.3]' AS dist
FROM items;

-- Скаларно произведение (отрицателно dot product за минимизация)
SELECT id, inner_product(embedding, '[0.1, 0.2, 0.3]') AS dist
FROM items;

-- Манхатън / L1 разстояние
SELECT id, l1_distance(embedding, '[0.1, 0.2, 0.3]') AS dist
FROM items;
```

### Търсене на Най-близки Съседи

```sql
-- Топ-10 най-близки съседи по косинусово разстояние
SELECT id FROM items
ORDER BY cosine_distance(embedding, '[0.1, 0.2, 0.3]') ASC
LIMIT 10;

-- Топ-5 най-близки съседи по евклидово разстояние
SELECT id FROM items
ORDER BY embedding <-> '[0.1, 0.2, 0.3]'
LIMIT 5;
```

### Векторни Индекси

```sql
-- Създаване на HNSW индекс за приблизително търсене на най-близки съседи
CREATE INDEX idx_items_vec ON items(embedding) USING hnsw;

-- Индексът се поддържа автоматично при INSERT и UPDATE
```

Поддържани индекс методи:
- `USING hnsw` — Hierarchical Navigable Small World (по подразбиране: косинусова метрика)
- `USING ivfpq` — Inverted File с Product Quantization

### Валидация на Размерност

BaraDB валидира размерностите на векторите при вмъкване:

```sql
-- Това ще даде грешка: очаквани 768 размерности, но подадени 3
INSERT INTO items (id, embedding) VALUES (2, '[1.0, 2.0, 3.0]');
```

## Нативно Nim API

За вградена или високопроизводителна употреба използвайте нативното Nim API директно:

```nim
import barabadb/vector/engine

var idx = newHNSWIndex(dimensions = 128)
idx.insert(1, @[1.0'f32, 0.0'f32, ...], {"category": "A"}.toTable)

# Търсене
let results = idx.search(queryVector, k = 10)

# С филтриране по метаданни
let filtered = idx.searchWithFilter(queryVector, k = 10,
  filter = proc(meta: Table[string, string]): bool =
    return meta.getOrDefault("category") == "A")
```

## Типове Индекси

### HNSW

Иерархичен навигируем малък свят за приблизително търсене на най-близки съседи.

```nim
var hnsw = newHNSWIndex(
  dimensions = 128,
  m = 16,                # връзки на слой
  efConstruction = 200,  # ширина на търсене при изграждане
  efSearch = 100         # ширина на търсене при заявка
)
```

### IVF-PQ

Inverted File Index с продуктово квантуване за компресия.

```nim
var ivfpq = newIVFPQIndex(
  dimensions = 128,
  numCentroids = 256,
  subQuantizers = 8
)
```

## Метрики за Разстояние

| Метрика | SQL Функция | Описание |
|---------|-------------|----------|
| `cosine` | `cosine_distance(a, b)` | Косинусова dissimilarity (1 - similarity) |
| `euclidean` | `euclidean_distance(a, b)` / `<->` | L2 разстояние |
| `dotproduct` | `inner_product(a, b)` | Отрицателно скаларно произведение |
| `manhattan` | `l1_distance(a, b)` | L1 разстояние |

## Квантуване

```nim
import barabadb/vector/quant

# Скаларно квантуване
let scalar = scalarQuantize(data, bits = 8)

# Продуктово квантуване
let pq = productQuantize(data, subVectors = 8, bits = 8)
```

## SIMD Ускорение

```nim
import barabadb/vector/simd

let dist = simdCosineDistance(vec1, vec2)
```
