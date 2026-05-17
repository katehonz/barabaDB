# Speicher-Engines

BaraDB bietet mehrere Speicher-Engines, optimiert für verschiedene Zugriffsmuster.

## LSM-Tree (Key-Value)

Die primäre Speicher-Engine mit write-optimierter Append-only Log-Struktur.

### Verwendung

```nim
import barabadb/storage/lsm

var db = newLSMTree("./data")
db.put("key1", cast[seq[byte]]("value1"))
let (found, value) = db.get("key1")
db.close()
```

### Komponenten

- **MemTable**: In-Memory sortierter Puffer
- **WAL**: Write-Ahead Log für Dauerhaftigkeit
- **SSTable**: Sortierte String-Tabellen auf Disk
- **Bloom-Filter**: Probabilistische Mengenmitgliedschaft
- **Compaction**: Size-tiered Strategie mit Level-Management
- **Page-Cache**: LRU-Cache mit Trefferraten-Verfolgung

## B-Tree Index

Geordneter Index für Bereichsabfragen und Point-Lookups.

### Verwendung

```nim
import barabadb/storage/btree

var btree = newBTreeIndex[string, string]()
btree.insert("key1", "value1")
let values = btree.get("key1")
let range = btree.scan("key_a", "key_z")
```

## Write-Ahead Log (WAL)

Sichert Dauerhaftigkeit von Schreiboperationen.

```nim
import barabadb/storage/wal

var wal = newWAL("./wal")
wal.append("txn1", "SET key1 value1")
wal.flush()
```

## Bloom-Filter

Probabilistische Datenstruktur für schnelle negative Lookups.

```nim
import barabadb/storage/bloom

var filter = newBloomFilter(10000, 0.01)
filter.add("key1")
if filter.mightContain("key1"):
  echo "possibly exists"
```

## Memory-mapped I/O

Effizienter Dateizugriff mittels mmap.

```nim
import barabadb/storage/mmap

var mapped = mmapFile("./data/file.dat")
let data = mapped.read(0, 100)
```
