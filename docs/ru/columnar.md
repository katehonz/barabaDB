# Колоночное хранилище

Хранилище с ориентацией на столбцы для аналитических запросов и агрегаций.

## Использование

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

## Кодирование

### RLE (Run-Length Encoding)

```nim
let rle = rleEncode(@[1'i64, 1, 1, 2, 2, 3])
```

### Dictionary Encoding

```nim
let dict = dictEncode(@["apple", "banana", "apple"])
```

## Типы столбцов

| Тип | Описание |
|-----|---------|
| `int32` | 32-битное целое |
| `int64` | 64-битное целое |
| `float32` | 32-битное с плавающей точкой |
| `float64` | 64-битное с плавающей точкой |
| `string` | Строка переменной длины |
| `bool` | Булевый |

## Сценарии использования

- OLAP нагрузки
- Крупномасштабные агрегации
- Хранилища данных
- Анализ временных рядов