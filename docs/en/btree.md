# B-Tree Index

Ordered index structure for efficient range scans and point lookups.

## Usage

```nim
import barabadb/storage/btree

var btree = newBTreeIndex[string, string]()

# Insert
btree.insert("key1", "value1")
btree.insert("key2", "value2")

# Point lookup
let values = btree.get("key1")

# Range scan
let range = btree.scan("key_a", "key_z")

# Delete
btree.delete("key1")
```

## Features

- Ordered key-value storage
- Range queries (BETWEEN, >, <, >=, <=)
- Prefix scans
- Configurable page size
- Iterator support

## Use Cases

- Primary key indexes
- Secondary indexes for frequently queried columns
- Range-partitioned data