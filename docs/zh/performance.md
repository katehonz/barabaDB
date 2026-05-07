# 性能指南

## 基准测试方法论

所有基准测试使用：
- **编译器**: Nim 2.2.0 配合 `-d:release --opt:speed`
- **CPU**: AMD Ryzen 9 5900X (12 cores / 24 threads)
- **内存**: 64 GB DDR4-3600
- **存储**: Samsung 980 Pro NVMe SSD

```bash
nim c -d:ssl -d:release -r benchmarks/bench_all.nim
```

## 存储引擎基准测试

### LSM-Tree 键值

| 指标 | 值 |
|------|-----|
| 写入吞吐量 | ~580,000 ops/s |
| 读取吞吐量 | ~720,000 ops/s |
| 平均写入延迟 | 1.7 µs |
| 平均读取延迟 | 1.4 µs |

### B-Tree 索引

| 指标 | 值 |
|------|-----|
| 插入吞吐量 | ~1,200,000 ops/s |
| 点查询吞吐量 | ~1,500,000 ops/s |
| 范围扫描 (1000 keys) | ~0.3 ms |

## 向量引擎基准测试

### HNSW 索引

| 指标 | 值 |
|------|-----|
| 插入 (dim=128) | ~45,000 vectors/s |
| 搜索 top-10 (n=100K) | ~8 ms |
| 每向量内存 (dim=128) | ~580 bytes |

参数: `M=16`, `efConstruction=200`, `efSearch=64`。

### SIMD 距离函数

| 操作 | dim=128 | dim=768 | dim=1536 |
|------|---------|---------|----------|
| Cosine distance | 4.2M/s | 850K/s | 420K/s |
| L2 (Euclidean) | 4.5M/s | 920K/s | 450K/s |
| Dot product | 4.8M/s | 980K/s | 480K/s |

## 协议基准测试

| 协议 | 连接数 | 查询/秒 | p99 延迟 |
|------|--------|---------|----------|
| Binary (localhost) | 1 | 45,000 | 0.4 ms |
| Binary (localhost) | 100 | 380,000 | 1.2 ms |
| HTTP/REST | 1 | 12,000 | 2.1 ms |
| HTTP/REST | 100 | 95,000 | 5.8 ms |

## 调优指南

### 写密集型工作负载

```bash
BARADB_MEMTABLE_SIZE_MB=256
BARADB_WAL_SYNC_INTERVAL_MS=10
BARADB_COMPACTION_INTERVAL_MS=30000
```

### 读密集型工作负载

```bash
BARADB_CACHE_SIZE_MB=1024
BARADB_BLOOM_BITS_PER_KEY=10
BARADB_COMPACTION_INTERVAL_MS=120000
```

### 向量搜索

```bash
BARADB_VECTOR_EF_CONSTRUCTION=200
BARADB_VECTOR_EF_SEARCH=128
BARADB_VECTOR_M=32
```

### 图分析

```bash
BARADB_GRAPH_PAGE_RANK_ITERATIONS=20
BARADB_GRAPH_LOUVAIN_RESOLUTION=1.0
```