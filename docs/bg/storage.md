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
- **SSTable**: Сортирани string таблици на диска (v3 с CRC footer)
- **Bloom Filter**: Вероятностна проверка за принадлежност
- **Compaction**: Size-tiered стратегия с управление на нива
- **MANIFEST**: Атомичен каталог на активните SSTables
- **Page Cache**: LRU кеш с проследяване на hit rate

### SSTable Формат (v3)

```
[Header] 36 байта
  magic:       uint32  (0x53535442 = "SSTB")
  version:     uint32  (3 = текуща)
  entryCount:  uint32
  level:       uint32
  indexOffset: uint64
  bloomOffset: uint64
  footerOffset: uint64

[Data Block]
  keyLen: uint32
  key:    bytes[keyLen]
  valueLen: uint32
  value:  bytes[valueLen]
  timestamp: uint64
  deleted: uint8

[Index Block]
  keyLen: uint32
  key:    bytes[keyLen]
  dataOffset: uint64

[Bloom Filter Block]
  bloomSize: uint32
  bloomData: bytes[bloomSize]

[Footer] 16 байта
  dataCrc32:  uint32  (CRC32 на Data Block)
  indexCrc32: uint32  (CRC32 на Index Block)
  bloomCrc32: uint32  (CRC32 на Bloom Block)
  reserved:   uint32  (трябва да е 0)
```

CRC footer-ът позволява независима проверка на всеки SSTable файл чрез `verifySSTable(path)`.

### MANIFEST Каталог

Файлът `MANIFEST` проследява всички активни SSTables атомично:

```json
{
  "version": 1,
  "sequence": 42,
  "createdAt": 1779103266,
  "sstables": [
    {"id": 1, "path": "sstables/1.sst", "level": 0, "minKey": "a", "maxKey": "z", "entryCount": 100}
  ]
}
```

- Записва се атомично чрез `MANIFEST.tmp` + rename
- Чете се при стартиране за бързо зареждане
- Обновява се след всеки flush и compaction

### WAL Ротация

Write-Ahead Log се ротира при достигане на 64MB:

```
wal/
  ├── wal.log          (активен сегмент)
  └── wal_archive/
      ├── wal.000001.log
      └── wal.000002.log
```

Ротацията се задейства:
- На всеки 1000 записа (лека проверка)
- При всеки `flush()` или `checkpoint()`

### Storage Repair

Проверка и ремонт на storage:

```bash
# Проверка на всички SSTables
./build/baradadb repair --data-dir=./data --dry-run

# Пълен ремонт
./build/baradadb repair --data-dir=./data
```

### Миграция на SSTable Версии

Пренаписване на legacy v1/v2 SSTables към v3:

```bash
./build/baradadb migrate --data-dir=./data
```

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

Осигурява устойчивост на операциите за запис със сегментна ротация.

```nim
import barabadb/storage/wal

var wal = newWriteAheadLog("./wal")
wal.writePut(key, value, timestamp)
wal.sync()
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

var mapped = openMmap("./data/file.dat")
let val = mapped.readUint32(0)
```
