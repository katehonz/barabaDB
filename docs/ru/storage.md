# Хранилища данных

BaraDB предоставляет несколько движков хранилища, оптимизированных для различных паттернов доступа.

## LSM-Tree (Ключ-значение)

Основной движок хранилища с оптимизацией за запись и append-only структурой лога.

### Использование

```nim
import barabadb/storage/lsm

var db = newLSMTree("./data")
db.put("key1", cast[seq[byte]]("value1"))
let (found, value) = db.get("key1")
db.close()
```

### Компоненты

- **MemTable**: Отсортированный буфер в памяти
- **WAL**: Write-ahead log для долговечности
- **SSTable**: Отсортированные строковые таблицы на диске
- **Bloom Filter**: Вероятностная структура для быстрых отрицательных проверок
- **Compaction**: Size-tiered стратегия с управлением уровней
- **Page Cache**: LRU кэш с отслеживанием hit rate

## B-Tree индекс

Упорядоченный индекс для диапазонных сканирований и точечных запросов.

### Использование

```nim
import barabadb/storage/btree

var btree = newBTreeIndex[string, string]()
btree.insert("key1", "value1")
let values = btree.get("key1")
let range = btree.scan("key_a", "key_z")
```

## Write-Ahead Log (WAL)

Обеспечивает долговечность операций записи.

```nim
import barabadb/storage/wal

var wal = newWAL("./wal")
wal.append("txn1", "SET key1 value1")
wal.flush()
```

## Bloom Filter

Вероятностная структура данных для быстрых отрицательных проверок.

```nim
import barabadb/storage/bloom

var filter = newBloomFilter(10000, 0.01)
filter.add("key1")
if filter.mightContain("key1"):
  echo "возможно существует"
```

## Memory-mapped I/O

Эффективный доступ к файлам через mmap.

```nim
import barabadb/storage/mmap

var mapped = mmapFile("./data/file.dat")
let data = mapped.read(0, 100)
```