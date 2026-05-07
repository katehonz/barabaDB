# 列式存储

用于分析查询和聚合的面向列的存储。

## 用法

```nim
import barabadb/core/columnar

var batch = newColumnBatch()
var ageCol = batch.addInt64Col("age")
var nameCol = batch.addStringCol("name")

ageCol.appendInt64(25)
nameCol.appendString("Alice")
```

## 聚合

```nim
echo ageCol.sumInt64()
echo ageCol.avgInt64()
echo ageCol.minInt64()
echo ageCol.maxInt64()
```

## 编码

### RLE

```nim
let rle = rleEncode(@[1'i64, 1, 1, 2, 2, 3])
```

### Dictionary

```nim
let dict = dictEncode(@["apple", "banana", "apple"])
```

## 列类型

| 类型 | 描述 |
|------|------|
| `int32` | 32 位整数 |
| `int64` | 64 位整数 |
| `float32` | 32 位浮点数 |
| `float64` | 64 位浮点数 |
| `string` | 可变长度字符串 |
| `bool` | 布尔值 |