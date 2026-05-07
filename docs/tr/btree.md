# B-Tree İndeksi

Verimli aralık taramaları ve nokta aramaları için sıralı indeks yapısı.

## Kullanım

```nim
import barabadb/storage/btree

var btree = newBTreeIndex[string, string]()

btree.insert("key1", "value1")
btree.insert("key2", "value2")

let values = btree.get("key1")
let range = btree.scan("key_a", "key_z")
btree.delete("key1")
```

## Özellikler

- Sıralı anahtar-değer depolama
- Aralık sorguları (BETWEEN, >, <, >=, <=)
- Önek taramaları
- Yapılandırılabilir sayfa boyutu
- İteratör desteği