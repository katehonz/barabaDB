# LSM-Tree Speicher-Engine

Die primäre Speicher-Engine in BaraDB mit Log-Structured Merge-Tree Architektur.

## Architektur

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

## Verwendung

```nim
import barabadb/storage/lsm

var db = newLSMTree("./data")

# Schreiben
db.put("key1", cast[seq[byte]]("value1"))

# Lesen
let (found, value) = db.get("key1")

# Löschen
db.delete("key1")

db.close()
```

## Funktionen

- **Write-optimiert**: Append-only Log-Struktur
- **Dauerhaftigkeit**: Write-Ahead Log (WAL) sichert Crash-Wiederherstellung
- **Bloom-Filter**: Schnelle negative Lookups
- **Compaction**: Size-tiered Strategie mischt SSTables
- **Page-Cache**: LRU-Cache für häufig zugegriffene Seiten

## Konfiguration

```nim
var db = newLSMTree(
  path = "./data",
  memTableSize = 64 * 1024 * 1024,  # 64MB
  walEnabled = true,
  bloomFpRate = 0.01
)
```
