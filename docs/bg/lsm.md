# LSM-Tree Съхранение

Основният двигател за съхранение използващ Log-Structured Merge-Tree архитектура.

## Употреба

```nim
import barabadb/storage/lsm

var db = newLSMTree("./data")

db.put("key1", cast[seq[byte]]("value1"))
let (found, value) = db.get("key1")

db.close()
```

## Компоненти

- **MemTable**: Сортиран буфер в паметта
- **WAL**: Write-ahead log за трайност
- **SSTable**: Сортирани таблици на диска
- **Bloom Filter**: Бързи негативни проверки
- **Compaction**: Сливане на SSTables
- **Page Cache**: LRU кеш