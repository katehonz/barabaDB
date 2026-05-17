# B-Tree Index

Geordnete Indexstruktur für effiziente Bereichsabfragen und Point-Lookups.

## Verwendung

```nim
import barabadb/storage/btree

var btree = newBTreeIndex[string, string]()

# Einfügen
btree.insert("key1", "value1")
btree.insert("key2", "value2")

# Point-Lookup
let values = btree.get("key1")

# Bereichsabfrage
let range = btree.scan("key_a", "key_z")

# Löschen
btree.delete("key1")
```

## Funktionen

- Geordnete Schlüssel-Wert-Speicherung
- Bereichsabfragen (BETWEEN, >, <, >=, <=)
- Präfix-Scans
- Konfigurierbare Seitengröße
- Iterator-Unterstützung

## Anwendungsfälle

- Primärschlüssel-Indizes
- Sekundärindizes für häufig abgefragte Spalten
- Bereichspartitionierte Daten
