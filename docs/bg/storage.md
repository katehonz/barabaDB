# Storage Engines

BaraDB предоставя множество storage двигатели, оптимизирани за различни модели на достъп.

## LSM-Tree (Key-Value)

Основният storage engine с write-оптимизирана append-only лог структура.

### Употреба

```nim
import barabadb/storage/lsm

var db = newLSMTree("./data")
db.put("key1", cast[seq[byte]]("value1"))
let (found, value) = db.get("key1")
db.close()
```

### Компоненти

- **MemTable**: В-памет сортиран буфер
- **WAL**: Write-ahead log за устойчивост
- **SSTable**: Сортирани string таблици на диска
- **Bloom Filter**: Вероятностна проверка за принадлежност
- **Compaction**: Size-tiered стратегия с управление на нива
- **Page Cache**: LRU кеш с проследяване на hit rate

## B-Tree Индекс

Подреден индекс за range сканиране и точково търсене.

### Употреба

```nim
import barabadb/storage/btree

var btree = newBTreeIndex[string, string]()
btree.insert("key1", "value1")
let values = btree.get("key1")
let range = btree.scan("key_a", "key_z")
```

## Write-Ahead Log (WAL)

Осигурява устойчивост на операциите за запис.

```nim
import barabadb/storage/wal

var wal = newWAL("./wal")
wal.append("txn1", "SET key1 value1")
wal.flush()
```

## Bloom Filter

Вероятностна структура от данни за бързи негативни проверки.

```nim
import barabadb/storage/bloom

var filter = newBloomFilter(10000, 0.01)
filter.add("key1")
if filter.mightContain("key1"):
  echo "евентуално съществува"
```

## Memory-mapped I/O

Ефективен достъп до файлове чрез mmap.

```nim
import barabadb/storage/mmap

var mapped = mmapFile("./data/file.dat")
let data = mapped.read(0, 100)
```
