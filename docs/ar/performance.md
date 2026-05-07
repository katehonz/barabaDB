# دليل الأداء

## منهجية المعايير

جميع المعايير تعمل بـ:
- **المترجم**: Nim 2.2.0 مع `-d:release --opt:speed`
- **CPU**: AMD Ryzen 9 5900X (12 نواة / 24 خيط)
- **الذاكرة**: 64 GB DDR4-3600
- **التخزين**: Samsung 980 Pro NVMe SSD

```bash
nim c -d:ssl -d:release -r benchmarks/bench_all.nim
```

## معايير محركات التخزين

### LSM-Tree

| المقاييس | القيمة |
|----------|--------|
| إنتاجية الكتابة | ~580,000 ops/s |
| إنتاجية القراءة | ~720,000 ops/s |
| متوسط تأخير الكتابة | 1.7 µs |
| متوسط تأخير القراءة | 1.4 µs |

### فهرس B-Tree

| المقاييس | القيمة |
|----------|--------|
| إنتاجية الإدراج | ~1,200,000 ops/s |
| إنتاجية البحث النقطي | ~1,500,000 ops/s |

## معايير المحرك المتجهي

### فهرس HNSW

| المقاييس | القيمة |
|----------|--------|
| الإدراج (dim=128) | ~45,000 vectors/s |
| البحث top-10 (n=100K) | ~8 ms |

المعلمات: `M=16`, `efConstruction=200`, `efSearch=64`.

## دليل الضبط

### لأحمال الكتابة الثقيلة

```bash
BARADB_MEMTABLE_SIZE_MB=256
BARADB_WAL_SYNC_INTERVAL_MS=10
BARADB_COMPACTION_INTERVAL_MS=30000
```

### لأحمال القراءة الثقيلة

```bash
BARADB_CACHE_SIZE_MB=1024
BARADB_BLOOM_BITS_PER_KEY=10
BARADB_COMPACTION_INTERVAL_MS=120000
```

### للبحث المتجهي

```bash
BARADB_VECTOR_EF_CONSTRUCTION=200
BARADB_VECTOR_EF_SEARCH=128
BARADB_VECTOR_M=32
```