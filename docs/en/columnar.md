# Columnar Storage

Column-oriented storage for analytical queries and aggregations.

## Usage

```nim
import barabadb/core/columnar

var batch = newColumnBatch()
var ageCol = batch.addInt64Col("age")
var nameCol = batch.addStringCol("name")

ageCol.appendInt64(25)
nameCol.appendString("Alice")
```

## Aggregations

```nim
echo ageCol.sumInt64()
echo ageCol.avgInt64()
echo ageCol.minInt64()
echo ageCol.maxInt64()
echo ageCol.count()
```

## Encoding

### RLE (Run-Length Encoding)

```nim
let rle = rleEncode(@[1'i64, 1, 1, 2, 2, 3])
```

### Dictionary Encoding

```nim
let dict = dictEncode(@["apple", "banana", "apple"])
```

## Column Types

| Type | Description |
|------|-------------|
| `int32` | 32-bit integer |
| `int64` | 64-bit integer |
| `float32` | 32-bit float |
| `float64` | 64-bit float |
| `string` | Variable-length string |
| `bool` | Boolean |

## Use Cases

- OLAP workloads
- Large-scale aggregations
- Data warehousing
- Time-series analysis