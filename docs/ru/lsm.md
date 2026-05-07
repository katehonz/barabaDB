# LSM-Tree хранилище

Основной движок хранилища в BaraDB с архитектурой Log-Structured Merge-Tree.

## Архитектура

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
           (when full, flush to SSTable)
                      │
                      ▼
┌─────────────────────────────────────────────┐
│                  SSTable                     │
│          (sorted string table on disk)       │
└─────────────────────────────────────────────┘
```

## Использование

```nim
import barabadb/storage/lsm

var db = newLSMTree("./data")

db.put("key1", cast[seq[byte]]("value1"))

let (found, value) = db.get("key1")

db.delete("key1")

db.close()
```

## Функции

- **Оптимизация записи**: Append-only log структура
- **Долговечность**: Write-ahead log (WAL) обеспечивает восстановление после сбоев
- **Bloom Filter**: Быстрые отрицательные поиски
- **Compaction**: Size-tiered стратегия объединяет SSTables
- **Page Cache**: LRU кэш для часто доступных страниц

## Конфигурация

```nim
var db = newLSMTree(
  path = "./data",
  memTableSize = 64 * 1024 * 1024,
  walEnabled = true,
  bloomFpRate = 0.01
)
```