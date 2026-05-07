# Руководство по производительности

## Методология бенчмаркинга

Все бенчмарки запускаются с:
- **Компилятор**: Nim 2.2.0 с `-d:release --opt:speed`
- **CPU**: AMD Ryzen 9 5900X (12 cores / 24 threads)
- **Память**: 64 GB DDR4-3600
- **Хранилище**: Samsung 980 Pro NVMe SSD
- **OS**: Ubuntu 24.04 LTS

```bash
nim c -d:ssl -d:release -r benchmarks/bench_all.nim
```

## Бенчмарки хранилища

### LSM-Tree Key-Value

| Метрика | Значение |
|---------|----------|
| Пропускная способность записи | ~580,000 ops/s |
| Пропускная способность чтения | ~720,000 ops/s |
| Средняя латентность записи | 1.7 µs |
| Средняя латентность чтения | 1.4 µs |

### B-Tree индекс

| Метрика | Значение |
|---------|----------|
| Пропускная способность вставки | ~1,200,000 ops/s |
| Пропускная способность точечного поиска | ~1,500,000 ops/s |
| Диапазонное сканирование (1000 ключей) | ~0.3 ms |

## Бенчмарки векторного движка

### HNSW индекс

| Метрика | Значение |
|---------|----------|
| Вставка (dim=128) | ~45,000 vectors/s |
| Поиск top-10 (dim=128, n=100K) | ~8 ms |
| Память на вектор (dim=128) | ~580 bytes |

Параметры: `M=16`, `efConstruction=200`, `efSearch=64`.

### SIMD функции расстояния

| Операция | dim=128 | dim=768 | dim=1536 |
|----------|---------|---------|----------|
| Cosine distance | 4.2M/s | 850K/s | 420K/s |
| L2 (Euclidean) | 4.5M/s | 920K/s | 450K/s |
| Dot product | 4.8M/s | 980K/s | 480K/s |

## Бенчмарки протоколов

| Протокол | Соединения | Запросов/сек | Латентность p99 |
|----------|------------|---------------|-----------------|
| Binary (localhost) | 1 | 45,000 | 0.4 ms |
| Binary (localhost) | 100 | 380,000 | 1.2 ms |
| HTTP/REST | 1 | 12,000 | 2.1 ms |
| HTTP/REST | 100 | 95,000 | 5.8 ms |

## Руководство по настройке

### Для нагрузки с интенсивной записью

```bash
export BARADB_MEMTABLE_SIZE_MB=256
export BARADB_WAL_SYNC_INTERVAL_MS=10
export BARADB_COMPACTION_INTERVAL_MS=30000
```

### Для нагрузки с интенсивным чтением

```bash
export BARADB_CACHE_SIZE_MB=1024
export BARADB_BLOOM_BITS_PER_KEY=10
export BARADB_COMPACTION_INTERVAL_MS=120000
```

### Для векторного поиска

```bash
export BARADB_VECTOR_EF_CONSTRUCTION=200
export BARADB_VECTOR_EF_SEARCH=128
export BARADB_VECTOR_M=32
```

### Для графовой аналитики

```bash
export BARADB_GRAPH_PAGE_RANK_ITERATIONS=20
export BARADB_GRAPH_LOUVAIN_RESOLUTION=1.0
```