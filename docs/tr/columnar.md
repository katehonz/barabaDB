# Kolonlu Depolama

Analitik sorgular ve toplama işlemleri için sütun yönlü depolama.

## Kullanım

```nim
import barabadb/core/columnar

var batch = newColumnBatch()
var ageCol = batch.addInt64Col("age")
var nameCol = batch.addStringCol("name")

ageCol.appendInt64(25)
nameCol.appendString("Alice")
```

## Toplamalar

```nim
echo ageCol.sumInt64()
echo ageCol.avgInt64()
echo ageCol.minInt64()
echo ageCol.maxInt64()
```

## Kodlama

### RLE

```nim
let rle = rleEncode(@[1'i64, 1, 1, 2, 2, 3])
```

### Dictionary

```nim
let dict = dictEncode(@["apple", "banana", "apple"])
```

## Sütun Türleri

| Tip | Açıklama |
|-----|----------|
| `int32` | 32-bit tamsayı |
| `int64` | 64-bit tamsayı |
| `float32` | 32-bit kayan nokta |
| `float64` | 64-bit kayan nokta |
| `string` | Değişken uzunluklu dize |
| `bool` | Mantıksal |