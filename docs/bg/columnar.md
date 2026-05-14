# Колонково Съхранение (Columnar)

Колонково-ориентирано съхранение за аналитични заявки и агрегации.

## Употреба

```nim
import barabadb/core/columnar

var batch = newColumnBatch()
var ageCol = batch.addInt64Col("age")
var nameCol = batch.addStringCol("name")

ageCol.appendInt64(25)
nameCol.appendString("Alice")
```

## Агрегации

```nim
echo ageCol.sumInt64()
echo ageCol.avgInt64()
echo ageCol.minInt64()
echo ageCol.maxInt64()
echo ageCol.count()
```

## Кодиране

### RLE (Run-Length Encoding)

```nim
let rle = rleEncode(@[1'i64, 1, 1, 2, 2, 3])
```

### Dictionary Encoding

```nim
let dict = dictEncode(@["apple", "banana", "apple"])
```

## Типове Колони

| Тип | Описание |
|------|----------|
| `int32` | 32-битов integer |
| `int64` | 64-битов integer |
| `float32` | 32-битов float |
| `float64` | 64-битов float |
| `string` | Низ с променлива дължина |
| `bool` | Булев |

## Случаи на Употреба

- OLAP натоварвания
- Мащабни агрегации
- Data warehousing
- Анализ на времеви редове
