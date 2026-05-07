# LSM-Tree Depolama Motoru

Log-Structured Merge-Tree mimarisini kullanan BaraDB'deki birincil depolama motoru.

## Mimari

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

## Kullanım

```nim
import barabadb/storage/lsm

var db = newLSMTree("./data")

db.put("key1", cast[seq[byte]]("value1"))

let (found, value) = db.get("key1")

db.delete("key1")

db.close()
```

## Özellikler

- **Yazma için optimize**: Append-only log yapısı
- **Dayanıklılık**: WAL çökme kurtarma sağlar
- **Bloom Filter**: Hızlı negatif aramalar
- **Compaction**: Boyut katmanlı strateji
- **Page Cache**: Sık erişilen sayfalar için LRU önbellek