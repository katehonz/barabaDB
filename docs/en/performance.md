# BaraDB Performance Guide

## Benchmark Methodology

All benchmarks are run with:
- **Compiler**: Nim 2.2.0 with `-d:release --opt:speed`
- **CPU**: AMD Ryzen 9 5900X (12 cores / 24 threads)
- **Memory**: 64 GB DDR4-3600
- **Storage**: Samsung 980 Pro NVMe SSD
- **OS**: Ubuntu 24.04 LTS

Run the full benchmark suite:

```bash
nim c -d:ssl -d:release -r benchmarks/bench_all.nim
```

## Storage Engine Benchmarks

### LSM-Tree Key-Value

| Metric | Value |
|--------|-------|
| Write throughput | ~580,000 ops/s |
| Read throughput | ~720,000 ops/s |
| Average write latency | 1.7 µs |
| Average read latency | 1.4 µs |
| Test dataset | 100,000 keys (16-byte keys, 64-byte values) |

The LSM-Tree uses a 64MB MemTable, WAL fsync every write, and size-tiered
compaction with 6 levels.

### B-Tree Index

| Metric | Value |
|--------|-------|
| Insert throughput | ~1,200,000 ops/s |
| Point lookup throughput | ~1,500,000 ops/s |
| Range scan (1000 keys) | ~0.3 ms |
| Tree height (100K keys) | 4 |

B-Tree nodes are 4KB with copy-on-write for MVCC compatibility.

## Vector Engine Benchmarks

### HNSW Index

| Metric | Value |
|--------|-------|
| Insert (dim=128) | ~45,000 vectors/s |
| Search top-10 (dim=128, n=10K) | ~2 ms |
| Search top-10 (dim=128, n=100K) | ~8 ms |
| Memory per vector (dim=128) | ~580 bytes |

Parameters: `M=16`, `efConstruction=200`, `efSearch=64`.

### SIMD Distance Functions

| Operation | dim=128 | dim=768 | dim=1536 |
|-----------|---------|---------|----------|
| Cosine distance | 4.2M/s | 850K/s | 420K/s |
| L2 (Euclidean) | 4.5M/s | 920K/s | 450K/s |
| Dot product | 4.8M/s | 980K/s | 480K/s |

SIMD uses AVX2 256-bit vectors with loop unrolling.

### Quantization

| Method | Accuracy Loss | Memory Reduction |
|--------|---------------|------------------|
| Scalar 8-bit | <1% | 4× |
| Scalar 4-bit | ~3% | 8× |
| Product Quantization (PQ16) | ~5% | 16× |
| Binary | ~15% | 32× |

## Full-Text Search Benchmarks

| Metric | Value |
|--------|-------|
| Index throughput | ~320,000 docs/s |
| BM25 search | ~28,000 queries/s |
| Fuzzy search (distance=2) | ~850 queries/s |
| Wildcard regex search | ~4,200 queries/s |

Test corpus: 5 unique documents × 2,000 repetitions (~50 words/doc).

## Graph Engine Benchmarks

| Operation | Throughput | Latency |
|-----------|------------|---------|
| Add node | ~2.5M ops/s | 0.4 µs |
| Add edge | ~1.8M ops/s | 0.55 µs |
| BFS (1K nodes, 5K edges) | ~12K traversals/s | 83 µs |
| DFS (1K nodes, 5K edges) | ~15K traversals/s | 67 µs |
| Dijkstra shortest path | — | ~120 µs |
| PageRank (10 iterations) | ~450 graphs/s | 2.2 ms |
| Louvain community detection | — | ~45 ms |

## Protocol Benchmarks

| Protocol | Connections | Queries/sec | Latency p99 |
|----------|-------------|-------------|-------------|
| Binary (localhost) | 1 | 45,000 | 0.4 ms |
| Binary (localhost) | 100 | 380,000 | 1.2 ms |
| HTTP/REST | 1 | 12,000 | 2.1 ms |
| HTTP/REST | 100 | 95,000 | 5.8 ms |
| WebSocket | 1 | 18,000 | 1.8 ms |

## Query Engine Benchmarks

| Query Type | Rows | Time |
|------------|------|------|
| Simple SELECT | 100K | 12 ms |
| SELECT + WHERE | 100K | 18 ms |
| SELECT + ORDER BY | 100K | 35 ms |
| GROUP BY + aggregates | 100K | 42 ms |
| INNER JOIN (1K × 1K) | 1M result | 85 ms |
| CTE (2 levels) | 100K | 28 ms |
| Subquery (EXISTS) | 100K | 22 ms |

## Scaling Behavior

### Vertical Scaling

| Cores | LSM Write | LSM Read | Vector Search |
|-------|-----------|----------|---------------|
| 1 | 580K | 720K | 2.0 ms |
| 4 | 1.9M | 2.6M | 1.1 ms |
| 8 | 3.4M | 4.8M | 0.7 ms |
| 16 | 5.8M | 7.2M | 0.5 ms |

### Memory Usage

| Component | Base Memory | Per-Entity Overhead |
|-----------|-------------|---------------------|
| LSM MemTable | 64 MB (fixed) | ~1.2× raw data |
| B-Tree | 8 MB (fixed) | ~8 bytes/key |
| HNSW index | — | ~580 bytes/vector (dim=128) |
| Graph | — | ~32 bytes/node, ~24 bytes/edge |
| FTS index | — | ~40% of raw text |
| Page cache | 256 MB (configurable) | — |

## Tuning Guide

### For Write-Heavy Workloads

```bash
export BARADB_MEMTABLE_SIZE_MB=256
export BARADB_WAL_SYNC_INTERVAL_MS=10
export BARADB_COMPACTION_INTERVAL_MS=30000
```

### For Read-Heavy Workloads

```bash
export BARADB_CACHE_SIZE_MB=1024
export BARADB_BLOOM_BITS_PER_KEY=10
export BARADB_COMPACTION_INTERVAL_MS=120000
```

### For Vector Search

```bash
export BARADB_VECTOR_EF_CONSTRUCTION=200
export BARADB_VECTOR_EF_SEARCH=128
export BARADB_VECTOR_M=32
```

### For Graph Analytics

```bash
export BARADB_GRAPH_PAGE_RANK_ITERATIONS=20
export BARADB_GRAPH_LOUVAIN_RESOLUTION=1.0
```
