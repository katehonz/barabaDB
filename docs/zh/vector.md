# 向量搜索引擎

用于相似性搜索的本机 HNSW 和 IVF-PQ 索引。

## 用法

```nim
import barabadb/vector/engine

var idx = newHNSWIndex(dimensions = 128)
idx.insert(1, @[1.0'f32, 0.0'f32, ...], {"category": "A"}.toTable)

let results = idx.search(queryVector, k = 10)
```

## 索引类型

### HNSW

用于近似最近邻搜索的分层可导航小世界图。

```nim
var hnsw = newHNSWIndex(
  dimensions = 128,
  m = 16,
  efConstruction = 200,
  efSearch = 100
)
```

### IVF-PQ

带乘积量化的倒排文件索引。

```nim
var ivfpq = newIVFPQIndex(
  dimensions = 128,
  numCentroids = 256,
  subQuantizers = 8
)
```

## 距离度量

| 度量 | 描述 |
|------|------|
| `cosine` | 余弦相似度 |
| `euclidean` | L2 距离 |
| `dotproduct` | 点积相似度 |
| `manhattan` | L1 距离 |

## 量化

```nim
let scalar = scalarQuantize(data, bits = 8)
let pq = productQuantize(data, subVectors = 8, bits = 8)
```

## SIMD 加速

```nim
import barabadb/vector/simd

let dist = simdCosineDistance(vec1, vec2)
```