# B-Tree 索引

用于高效范围扫描和点查询的有序索引结构。

## 用法

```nim
import barabadb/storage/btree

var btree = newBTreeIndex[string, string]()

btree.insert("key1", "value1")
btree.insert("key2", "value2")

let values = btree.get("key1")
let range = btree.scan("key_a", "key_z")
btree.delete("key1")
```

## 特性

- 有序键值存储
- 范围查询（BETWEEN, >, <, >=, <=）
- 前缀扫描
- 可配置的页面大小
- 迭代器支持