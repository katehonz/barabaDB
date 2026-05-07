# التخزين العمودي

تخزين موجهة للأعمدة للاستعلامات التحليلية والتجميعات.

## الاستخدام

```nim
import barabadb/core/columnar

var batch = newColumnBatch()
var ageCol = batch.addInt64Col("age")
var nameCol = batch.addStringCol("name")

ageCol.appendInt64(25)
nameCol.appendString("Alice")
```

## التجميعات

```nim
echo ageCol.sumInt64()
echo ageCol.avgInt64()
echo ageCol.minInt64()
echo ageCol.maxInt64()
```

## الترميز

### RLE

```nim
let rle = rleEncode(@[1'i64, 1, 1, 2, 2, 3])
```

### Dictionary

```nim
let dict = dictEncode(@["apple", "banana", "apple"])
```

## أنواع الأعمدة

| النوع | الوصف |
|-------|-------|
| `int32` | عدد صحيح 32 بت |
| `int64` | عدد صحيح 64 بت |
| `float32` | فاصلة عائمة 32 بت |
| `float64` | فاصلة عائمة 64 بت |
| `string` | سلسلة متغيرة الطول |
| `bool` | منطقي |