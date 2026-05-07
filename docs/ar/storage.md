# محركات التخزين

توفر BaraDB محركات تخزين متعددة محسنة لأنماط الوصول المختلفة.

## LSM-Tree (مفتاح-قيمة)

محرك التخزين الأساسي المحسن للكتابة مع بنية log-only إلحاقية.

### الاستخدام

```nim
import barabadb/storage/lsm

var db = newLSMTree("./data")
db.put("key1", cast[seq[byte]]("value1"))
let (found, value) = db.get("key1")
db.close()
```

### المكونات

- **MemTable**: مخزن مؤقت مرتب في الذاكرة
- **WAL**: سجل write-ahead للدائمة
- **SSTable**: جداول السلاسل المرتبة على القرص
- **Bloom Filter**: بنية احتمالية للبحث السلبي السريع
- **الضغط**: استراتيجية ذات طبقات بحجم مع إدارة المستويات
- **ذاكرة الصفحة**: ذاكرة مؤقتة LRU مع تتبع معدل الإصابة

## فهرس B-Tree

فهرس مرتب للبحث بالنطاق والبحث النقطي.

### الاستخدام

```nim
import barabadb/storage/btree

var btree = newBTreeIndex[string, string]()
btree.insert("key1", "value1")
let values = btree.get("key1")
let range = btree.scan("key_a", "key_z")
```

## Write-Ahead Log (WAL)

يضمن دائمة عمليات الكتابة.

```nim
import barabadb/storage/wal

var wal = newWAL("./wal")
wal.append("txn1", "SET key1 value1")
wal.flush()
```

## Bloom Filter

هيكل بيانات احتمالي للبحث السلبي السريع.

```nim
import barabadb/storage/bloom

var filter = newBloomFilter(10000, 0.01)
filter.add("key1")
if filter.mightContain("key1"):
  echo "ربما موجود"
```