# Storage Engines

BaraDB provides multiple storage engines optimized for different access patterns.

## LSM-Tree (Key-Value)

The primary storage engine with write-optimized append-only log structure.

### Usage

```nim
import barabadb/storage/lsm

var db = newLSMTree("./data")
db.put("key1", cast[seq[byte]]("value1"))
let (found, value) = db.get("key1")
db.close()
```

### Components

- **MemTable**: In-memory sorted buffer
- **WAL**: Write-ahead log for durability
- **SSTable**: Sorted string tables on disk (v3 with CRC footer)
- **Bloom Filter**: Probabilistic set membership
- **Compaction**: Size-tiered strategy with level management
- **MANIFEST**: Atomic catalog of active SSTables
- **Page Cache**: LRU cache with hit rate tracking

### SSTable Format (v3)

```
[Header] 36 bytes
  magic:       uint32  (0x53535442 = "SSTB")
  version:     uint32  (3 = current)
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

[Footer] 16 bytes
  dataCrc32:  uint32  (CRC32 of Data Block)
  indexCrc32: uint32  (CRC32 of Index Block)
  bloomCrc32: uint32  (CRC32 of Bloom Block)
  reserved:   uint32  (must be 0)
```

The CRC footer enables independent verification of each SSTable file via `verifySSTable(path)`.

### MANIFEST Catalog

The `MANIFEST` file tracks all active SSTables atomically:

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

- Written atomically via `MANIFEST.tmp` + rename
- Read at startup for fast loading
- Updated after every flush and compaction

### WAL Rotation

The Write-Ahead Log rotates when it reaches 64MB:

```
wal/
  ├── wal.log          (active segment)
  └── wal_archive/
      ├── wal.000001.log
      └── wal.000002.log
```

Rotation triggers:
- Every 1000 entries (lightweight check)
- On every `flush()` or `checkpoint()`

### Storage Repair

Verify and repair storage integrity:

```bash
# Check all SSTables
./build/baradadb repair --data-dir=./data --dry-run

# Full repair
./build/baradadb repair --data-dir=./data
```

### SSTable Migration

Rewrite legacy v1/v2 SSTables to v3:

```bash
./build/baradadb migrate --data-dir=./data
```

## B-Tree Index

Ordered index for range scans and point lookups.

### Usage

```nim
import barabadb/storage/btree

var btree = newBTreeIndex[string, string]()
btree.insert("key1", "value1")
let values = btree.get("key1")
let range = btree.scan("key_a", "key_z")
```

## Write-Ahead Log (WAL)

Ensures durability of write operations with segment rotation.

```nim
import barabadb/storage/wal

var wal = newWriteAheadLog("./wal")
wal.writePut(key, value, timestamp)
wal.sync()
```

## Bloom Filter

Probabilistic data structure for fast negative lookups.

```nim
import barabadb/storage/bloom

var filter = newBloomFilter(10000, 0.01)
filter.add("key1")
if filter.mightContain("key1"):
  echo "possibly exists"
```

## Memory-mapped I/O

Efficient file access using mmap.

```nim
import barabadb/storage/mmap

var mapped = openMmap("./data/file.dat")
let val = mapped.readUint32(0)
```
