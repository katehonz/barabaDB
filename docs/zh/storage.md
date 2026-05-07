# 存储引擎

BaraDB 提供多种存储引擎，针对不同的访问模式进行了优化。

## LSM-Tree（键值）

主要的存储引擎，采用写优化的追加式日志结构。

### 使用

```nim
import barabadb/storage/lsm

var db = newLSMTree("./data")
db.put("key1", cast[seq[byte]]("value1"))
let (found, value) = db.get("key1")
db.close()
```

### 组件

- **MemTable**：内存中的排序缓冲区
- **WAL**：预写日志，用于持久性
- **SSTable**：磁盘上的排序字符串表
- **Bloom Filter**：用于快速否定查找的概率结构
- **Compaction**：带层级管理的大小分层策略
- **Page Cache**：带命中率追踪的 LRU 缓存

## B-Tree 索引

用于范围扫描和点查询的有序索引。

### 使用

```nim
import barabadb/storage/btree

var btree = newBTreeIndex[string, string]()
btree.insert("key1", "value1")
let values = btree.get("key1")
let range = btree.scan("key_a", "key_z")
```

## 预写日志 (WAL)

确保写操作的持久性。

```nim
import barabadb/storage/wal

var wal = newWAL("./wal")
wal.append("txn1", "SET key1 value1")
wal.flush()
```

## Bloom 过滤器

用于快速否定查找的概率数据结构。

```nim
import barabadb/storage/bloom

var filter = newBloomFilter(10000, 0.01)
filter.add("key1")
if filter.mightContain("key1"):
  echo "可能存在"
```

## 内存映射 I/O

使用 mmap 进行高效的文件访问。

```nim
import barabadb/storage/mmap

var mapped = mmapFile("./data/file.dat")
let data = mapped.read(0, 100)
```