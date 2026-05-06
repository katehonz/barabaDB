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
- **SSTable**: Sorted string tables on disk
- **Bloom Filter**: Probabilistic set membership
- **Compaction**: Size-tiered strategy with level management
- **Page Cache**: LRU cache with hit rate tracking

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

Ensures durability of write operations.

```nim
import barabadb/storage/wal

var wal = newWAL("./wal")
wal.append("txn1", "SET key1 value1")
wal.flush()
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

var mapped = mmapFile("./data/file.dat")
let data = mapped.read(0, 100)
```