# BaraDB Performance-Leitfaden

## Benchmark-Methodik

Alle Benchmarks wurden ausgeführt mit:
- **Compiler**: Nim 2.2.0 mit `-d:release --opt:speed`
- **CPU**: AMD Ryzen 9 5900X (12 Kerne / 24 Threads)
- **Memory**: 64 GB DDR4-3600
- **Storage**: Samsung 980 Pro NVMe SSD
- **OS**: Ubuntu 24.04 LTS

Die vollständige Benchmark-Suite ausführen:

```bash
nim c -d:ssl -d:release -r benchmarks/bench_all.nim
```

## Storage Engine Benchmarks

### LSM-Tree Key-Value

| Metrik | Wert |
|--------|------|
| Write Throughput | ~580,000 ops/s |
| Read Throughput | ~720,000 ops/s |
| Durchschnittliche Write-Latenz | 1.7 µs |
| Durchschnittliche Read-Latenz | 1.4 µs |
| Testdatensatz | 100,000 Keys (16-Byte Keys, 64-Byte Values) |

Der LSM-Tree verwendet eine 64MB MemTable, WAL fsync bei jedem Write und size-tiered
Compaction mit 6 Levels.

### B-Tree Index

| Metrik | Wert |
|--------|------|
| Insert Throughput | ~1,200,000 ops/s |
| Point Lookup Throughput | ~1,500,000 ops/s |
| Range Scan (1000 Keys) | ~0.3 ms |
| Baumhöhe (100K Keys) | 4 |

B-Tree Knoten sind 4KB mit Copy-on-Write für MVCC-Kompatibilität.

## Vector Engine Benchmarks

### HNSW Index

| Metrik | Wert |
|--------|------|
| Insert (dim=128) | ~45,000 vectors/s |
| Search top-10 (dim=128, n=10K) | ~2 ms |
| Search top-10 (dim=128, n=100K) | ~8 ms |
| Speicher pro Vektor (dim=128) | ~580 bytes |

Parameter: `M=16`, `efConstruction=200`, `efSearch=64`.

### SIMD Distanzfunktionen

| Operation | dim=128 | dim=768 | dim=1536 |
|-----------|---------|---------|----------|
| Cosine Distance | 4.2M/s | 850K/s | 420K/s |
| L2 (Euclidean) | 4.5M/s | 920K/s | 450K/s |
| Dot Product | 4.8M/s | 980K/s | 480K/s |

SIMD verwendet AVX2 256-Bit Vektoren mit Loop Unrolling.

### Quantization

| Methode | Genauigkeitsverlust | Speicherreduzierung |
|---------|--------------------|--------------------|
| Scalar 8-bit | <1% | 4× |
| Scalar 4-bit | ~3% | 8× |
| Product Quantization (PQ16) | ~5% | 16× |
| Binary | ~15% | 32× |

## Full-Text Search Benchmarks

| Metrik | Wert |
|--------|------|
| Index Throughput | ~320,000 docs/s |
| BM25 Search | ~28,000 queries/s |
| Fuzzy Search (distance=2) | ~850 queries/s |
| Wildcard Regex Search | ~4,200 queries/s |

Testkorpus: 5 einzigartige Dokumente × 2,000 Wiederholungen (~50 Wörter/Dok).

## Graph Engine Benchmarks

| Operation | Throughput | Latenz |
|-----------|------------|--------|
| Knoten hinzufügen | ~2.5M ops/s | 0.4 µs |
| Kante hinzufügen | ~1.8M ops/s | 0.55 µs |
| BFS (1K Knoten, 5K Kanten) | ~12K Traversierungen/s | 83 µs |
| DFS (1K Knoten, 5K Kanten) | ~15K Traversierungen/s | 67 µs |
| Dijkstra kürzester Pfad | — | ~120 µs |
| PageRank (10 Iterationen) | ~450 Graphen/s | 2.2 ms |
| Louvain Community Detection | — | ~45 ms |

## Protokoll-Benchmarks

| Protokoll | Verbindungen | Queries/sec | Latenz p99 |
|-----------|--------------|-------------|------------|
| Binary (localhost) | 1 | 45,000 | 0.4 ms |
| Binary (localhost) | 100 | 380,000 | 1.2 ms |
| HTTP/REST | 1 | 12,000 | 2.1 ms |
| HTTP/REST | 100 | 95,000 | 5.8 ms |
| WebSocket | 1 | 18,000 | 1.8 ms |

## Query Engine Benchmarks

| Abfragetyp | Zeilen | Zeit |
|------------|--------|------|
| Simple SELECT | 100K | 12 ms |
| SELECT + WHERE | 100K | 18 ms |
| SELECT + ORDER BY | 100K | 35 ms |
| GROUP BY + Aggregates | 100K | 42 ms |
| INNER JOIN (1K × 1K) | 1M Ergebnis | 85 ms |
| CTE (2 Ebenen) | 100K | 28 ms |
| Subquery (EXISTS) | 100K | 22 ms |

## Skalierungsverhalten

### Vertikale Skalierung

| Kerne | LSM Write | LSM Read | Vector Search |
|-------|-----------|----------|---------------|
| 1 | 580K | 720K | 2.0 ms |
| 4 | 1.9M | 2.6M | 1.1 ms |
| 8 | 3.4M | 4.8M | 0.7 ms |
| 16 | 5.8M | 7.2M | 0.5 ms |

### Speicherverbrauch

| Komponente | Basis-Speicher | Pro-Entity Overhead |
|------------|----------------|---------------------|
| LSM MemTable | 64 MB (fest) | ~1.2× Rohdaten |
| B-Tree | 8 MB (fest) | ~8 bytes/Key |
| HNSW Index | — | ~580 bytes/Vektor (dim=128) |
| Graph | — | ~32 bytes/Knoten, ~24 bytes/Kante |
| FTS Index | — | ~40% von Rohtext |
| Page Cache | 256 MB (konfigurierbar) | — |

## Tuning-Leitfaden

### Für Write-intensive Workloads

```bash
export BARADB_MEMTABLE_SIZE_MB=256
export BARADB_WAL_SYNC_INTERVAL_MS=10
export BARADB_COMPACTION_INTERVAL_MS=30000
```

### Für Read-intensive Workloads

```bash
export BARADB_CACHE_SIZE_MB=1024
export BARADB_BLOOM_BITS_PER_KEY=10
export BARADB_COMPACTION_INTERVAL_MS=120000
```

### Für Vector Search

```bash
export BARADB_VECTOR_EF_CONSTRUCTION=200
export BARADB_VECTOR_EF_SEARCH=128
export BARADB_VECTOR_M=32
```

### Für Graph Analytics

```bash
export BARADB_GRAPH_PAGE_RANK_ITERATIONS=20
export BARADB_GRAPH_LOUVAIN_RESOLUTION=1.0
```
