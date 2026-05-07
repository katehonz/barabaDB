# موتور ذخیره‌سازی LSM-Tree

موتور ذخیره‌سازی اصلی BaraDB با معماری Log-Structured Merge-Tree.

## معماری

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

## استفاده

```nim
import barabadb/storage/lsm

var db = newLSMTree("./data")

db.put("key1", cast[seq[byte]]("value1"))

let (found, value) = db.get("key1")

db.delete("key1")

db.close()
```

## ویژگی‌ها

- **بهینه برای نوشتن**: ساختار log-only اضافه‌شونده
- **دوام**: WAL تضمین‌کننده بازیابی پس از خرابی
- **Bloom Filter**: جستجوهای منفی سریع
- **Compaction**: استراتژی size-tiered
- **Page Cache**: کش LRU