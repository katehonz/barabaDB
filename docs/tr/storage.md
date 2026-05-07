# Depolama Motorları

BaraDB farklı erişim kalıpları için optimize edilmiş birden fazla depolama motoru sağlar.

## LSM-Tree (Anahtar-Değer)

Yazma için optimize edilmiş append-only log yapılı birincil depolama motoru.

### Kullanım

```nim
import barabadb/storage/lsm

var db = newLSMTree("./data")
db.put("key1", cast[seq[byte]]("value1"))
let (found, value) = db.get("key1")
db.close()
```

### Bileşenler

- **MemTable**: Bellek içi sıralı tampon
- **WAL**: Dayanıklılık için write-ahead log
- **SSTable**: Disk üzerinde sıralı string tabloları
- **Bloom Filter**: Hızlı negatif aramalar için olasılıksal yapı
- **Compaction**: Seviye yönetimi ile boyut katmanlı strateji
- **Page Cache**: Hit oranı izlemeli LRU önbellek

## B-Tree İndeksi

Aralık taramaları ve nokta aramaları için sıralı indeks.

### Kullanım

```nim
import barabadb/storage/btree

var btree = newBTreeIndex[string, string]()
btree.insert("key1", "value1")
let values = btree.get("key1")
let range = btree.scan("key_a", "key_z")
```

## Write-Ahead Log (WAL)

Yazma işlemlerinin dayanıklılığını sağlar.

```nim
import barabadb/storage/wal

var wal = newWAL("./wal")
wal.append("txn1", "SET key1 value1")
wal.flush()
```

## Bloom Filter

Hızlı negatif aramalar için olasılıksal veri yapısı.

```nim
import barabadb/storage/bloom

var filter = newBloomFilter(10000, 0.01)
filter.add("key1")
if filter.mightContain("key1"):
  echo "muhtemelen var"
```