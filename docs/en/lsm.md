# LSM-Tree Storage Engine

The primary storage engine in BaraDB using the Log-Structured Merge-Tree architecture.

## Architecture

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

## Usage

```nim
import barabadb/storage/lsm

var db = newLSMTree("./data")

# Write
db.put("key1", cast[seq[byte]]("value1"))

# Read
let (found, value) = db.get("key1")

# Delete
db.delete("key1")

db.close()
```

## Features

- **Write-optimized**: Append-only log structure
- **Durability**: Write-ahead log (WAL) ensures crash recovery
- **Bloom Filter**: Fast negative lookups
- **Compaction**: Size-tiered strategy merges SSTables
- **Page Cache**: LRU cache for frequently accessed pages

## Configuration

```nim
var db = newLSMTree(
  path = "./data",
  memTableSize = 64 * 1024 * 1024,  # 64MB
  walEnabled = true,
  bloomFpRate = 0.01
)
```