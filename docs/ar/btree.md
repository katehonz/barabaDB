# فهرس B-Tree

هيكل فهرس مرتب للبحث النطاقي والنقطة الفعال.

## الاستخدام

```nim
import barabadb/storage/btree

var btree = newBTreeIndex[string, string]()

btree.insert("key1", "value1")
btree.insert("key2", "value2")

let values = btree.get("key1")
let range = btree.scan("key_a", "key_z")
btree.delete("key1")
```

## الميزات

- تخزين مفاتي-قيم مرتب
- استعلامات النطاق (BETWEEN, >, <, >=, <=)
- المسح بالبادئة
- حجم الصفحة القابل للتكوين
- دعم المكرر