# اندیس B-Tree

ساختار اندیس مرتب برای اسکن بازه‌ای و جستجوی نقطه‌ای.

## استفاده

```nim
import barabadb/storage/btree

var btree = newBTreeIndex[string, string]()

btree.insert("key1", "value1")
btree.insert("key2", "value2")

let values = btree.get("key1")
let range = btree.scan("key_a", "key_z")
btree.delete("key1")
```

## ویژگی‌ها

- ذخیره‌سازی مرتب کلید-مقدار
- جستجوهای بازه‌ای (BETWEEN, >, <, >=, <=)
- اسکن پیشوندی
- پشتیبانی از iterator