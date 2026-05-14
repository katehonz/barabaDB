# LSM-Tree Storage Engine

Основният storage engine в BaraDB, използващ Log-Structured Merge-Tree архитектура.

## Архитектура

```
┌─────────────────────────────────────────────┐
│                   Записи                     │
│       (добавяне към WAL + MemTable)          │
└─────────────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────┐
│                  MemTable                    │
│         (в-памет сортиран буфер)              │
└─────────────────────────────────────────────┘
                       │
              (при запълване, flush към SSTable)
                       │
                       ▼
┌─────────────────────────────────────────────┐
│                  SSTable                     │
│    (сортирана string table на диска)          │
└─────────────────────────────────────────────┘
```

## Употреба

```nim
import barabadb/storage/lsm

var db = newLSMTree("./data")

# Запис
db.put("key1", cast[seq[byte]]("value1"))

# Четене
let (found, value) = db.get("key1")

# Изтриване
db.delete("key1")

db.close()
```

## Възможности

- **Write-оптимизиран**: Append-only лог структура
- **Устойчивост**: Write-ahead log (WAL) осигурява crash recovery
- **Bloom Филтър**: Бързи негативни проверки
- **Compaction**: Size-tiered стратегия слива SSTables
- **Page Cache**: LRU кеш за често достъпвани страници

## Конфигурация

```nim
var db = newLSMTree(
  path = "./data",
  memTableSize = 64 * 1024 * 1024,  # 64MB
  walEnabled = true,
  bloomFpRate = 0.01
)
```
