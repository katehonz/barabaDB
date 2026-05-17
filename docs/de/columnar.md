# Kolumnare Speicherung

Spaltenorientierte Speicherung für analytische Abfragen und Aggregation.

## Verwendung

```nim
import barabadb/core/columnar

var batch = newColumnBatch()
var ageCol = batch.addInt64Col("age")
var nameCol = batch.addStringCol("name")

ageCol.appendInt64(25)
nameCol.appendString("Alice")
```

## Aggregation

```nim
echo ageCol.sumInt64()
echo ageCol.avgInt64()
echo ageCol.minInt64()
echo ageCol.maxInt64()
echo ageCol.count()
```

## Kodierung

### RLE (Run-Length Encoding)

```nim
let rle = rleEncode(@[1'i64, 1, 1, 2, 2, 3])
```

### Dictionary-Kodierung

```nim
let dict = dictEncode(@["apple", "banana", "apple"])
```

## Spaltentypen

| Typ | Beschreibung |
|------|-------------|
| `int32` | 32-Bit Integer |
| `int64` | 64-Bit Integer |
| `float32` | 32-Bit Float |
| `float64` | 64-Bit Float |
| `string` | Variable-length String |
| `bool` | Boolean |

## Anwendungsfälle

- OLAP-Workloads
- Großflächige Aggregation
- Data Warehousing
- Zeitreihenanalyse
