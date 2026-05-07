# LSM-Tree 存储引擎

BaraDB 的主要存储引擎，使用 Log-Structured Merge-Tree 架构。

## 架构

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
                      ▼
┌─────────────────────────────────────────────┐
│                  SSTable                     │
│          (sorted string table on disk)       │
└─────────────────────────────────────────────┘
```

## 用法

```nim
import barabadb/storage/lsm

var db = newLSMTree("./data")

db.put("key1", cast[seq[byte]]("value1"))

let (found, value) = db.get("key1")

db.delete("key1")

db.close()
```

## 特性

- **写优化**：追加式日志结构
- **持久性**：WAL 确保崩溃恢复
- **Bloom Filter**：快速否定查找
- **压缩**：大小分层策略合并 SSTable
- **页面缓存**：LRU 缓存常用页面