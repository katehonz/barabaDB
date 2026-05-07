# ذخیره‌سازی ستونی

ذخیره‌سازی ستون-محور برای کوئری‌های تحلیلی و تجمیع‌ها.

## استفاده

```nim
import barabadb/core/columnar

var batch = newColumnBatch()
var ageCol = batch.addInt64Col("age")
var nameCol = batch.addStringCol("name")

ageCol.appendInt64(25)
nameCol.appendString("Alice")
```

## تجمیع‌ها

```nim
echo ageCol.sumInt64()
echo ageCol.avgInt64()
echo ageCol.minInt64()
echo ageCol.maxInt64()
```

## کدگذاری

### RLE

```nim
let rle = rleEncode(@[1'i64, 1, 1, 2, 2, 3])
```

### Dictionary

```nim
let dict = dictEncode(@["apple", "banana", "apple"])
```

## انواع ستون

| نوع | توضیح |
|-----|--------|
| `int32` | عدد صحیح 32 بیتی |
| `int64` | عدد صحیح 64 بیتی |
| `float32` | عدد اعشاری 32 بیتی |
| `float64` | عدد اعشاری 64 بیتی |
| `string` | رشته با طول متغیر |
| `bool` | بولی |