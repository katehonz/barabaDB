# محرك تخزين LSM-Tree

محرك التخزين الأساسي في BaraDB باستخدام بنية Log-Structured Merge-Tree.

## البنية

```
┌─────────────────────────────────────────────┐
│                   Writes                     │
│         (append to WAL + MemTable)           │
└─────────────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────┐
│                  MemTable                    │
│         (in-memory sorted buffer)            │
└─────────────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────┐
│                  SSTable                     │
│          (sorted string table on disk)       │
└─────────────────────────────────────────────┘
```

## الاستخدام

```nim
import barabadb/storage/lsm

var db = newLSMTree("./data")

db.put("key1", cast[seq[byte]]("value1"))

let (found, value) = db.get("key1")

db.delete("key1")

db.close()
```

## الميزات

- **محسن للكتابة**: هيكل log-only إضافي
- **الدائمة**: WAL يضمن استعادة بعد الانهيار
- **Bloom Filter**: بحث سلبي سريع
- **الضغط**: استراتيجية size-tiered
- **ذاكرة الصفحة**: LRU للصفحاتaccessed بشكل متكرر