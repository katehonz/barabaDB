# موتورهای ذخیره‌سازی

BaraDB چندین موتور ذخیره‌سازی بهینه‌شده برای الگوهای دسترسی مختلف فراهم می‌کند.

## LSM-Tree (کلید-مقدار)

موتور ذخیره‌سازی اصلی با ساختار log-only اضافه‌شونده بهینه برای نوشتن.

### استفاده

```nim
import barabadb/storage/lsm

var db = newLSMTree("./data")
db.put("key1", cast[seq[byte]]("value1"))
let (found, value) = db.get("key1")
db.close()
```

### اجزا

- **MemTable**: بافر مرتب در حافظه
- **WAL**: log جلوگیری از نوشتن برای دوام
- **SSTable**: جداول رشته‌ای مرتب روی دیسک
- **Bloom Filter**: ساختار احتمالی برای جستجوهای منفی سریع
- **Compaction**: استراتژی size-tiered با مدیریت سطح
- **Page Cache**: کش LRU با ردیابی نرخ hit

## اندیس B-Tree

اندیس مرتب برای اسکن بازه‌ای و جستجوهای نقطه‌ای.

### استفاده

```nim
import barabadb/storage/btree

var btree = newBTreeIndex[string, string]()
btree.insert("key1", "value1")
let values = btree.get("key1")
let range = btree.scan("key_a", "key_z")
```

## Write-Ahead Log (WAL)

دوام عملیات‌های نوشتن را تضمین می‌کند.

```nim
import barabadb/storage/wal

var wal = newWAL("./wal")
wal.append("txn1", "SET key1 value1")
wal.flush()
```

## Bloom Filter

ساختار داده احتمالی برای جستجوهای منفی سریع.

```nim
import barabadb/storage/bloom

var filter = newBloomFilter(10000, 0.01)
filter.add("key1")
if filter.mightContain("key1"):
  echo "احتمالاً وجود دارد"
```

## I/O نگاشته‌شده به حافظه

دسترسی کارآمد به فایل با استفاده از mmap.

```nim
import barabadb/storage/mmap

var mapped = mmapFile("./data/file.dat")
let data = mapped.read(0, 100)
```