# Performans Rehberi

## Kıyaslama Metodolojisi

Tüm kıyaslamalar şununla çalıştırılır:
- **Derleyici**: Nim 2.2.0 `-d:release --opt:speed`
- **CPU**: AMD Ryzen 9 5900X (12 çekirdek / 24 iş parçacığı)
- **Bellek**: 64 GB DDR4-3600
- **Depolama**: Samsung 980 Pro NVMe SSD

```bash
nim c -d:ssl -d:release -r benchmarks/bench_all.nim
```

## Depolama Motoru Kıyaslamaları

### LSM-Tree

| Metrik | Değer |
|--------|-------|
| Yazma verimi | ~580,000 ops/s |
| Okuma verimi | ~720,000 ops/s |
| Ortalama yazma gecikmesi | 1.7 µs |
| Ortalama okuma gecikmesi | 1.4 µs |

### B-Tree İndeksi

| Metrik | Değer |
|--------|-------|
| Ekleme verimi | ~1,200,000 ops/s |
| Nokta arama verimi | ~1,500,000 ops/s |

## Vektör Motoru Kıyaslamaları

### HNSW İndeksi

| Metrik | Değer |
|--------|-------|
| Ekleme (dim=128) | ~45,000 vectors/s |
| Top-10 arama (n=100K) | ~8 ms |

Parametreler: `M=16`, `efConstruction=200`, `efSearch=64`.

## Ayar Kılavuzu

### Yoğun Yazma İş Yükü

```bash
BARADB_MEMTABLE_SIZE_MB=256
BARADB_WAL_SYNC_INTERVAL_MS=10
BARADB_COMPACTION_INTERVAL_MS=30000
```

### Yoğun Okuma İş Yükü

```bash
BARADB_CACHE_SIZE_MB=1024
BARADB_BLOOM_BITS_PER_KEY=10
BARADB_COMPACTION_INTERVAL_MS=120000
```

### Vektör Arama

```bash
BARADB_VECTOR_EF_CONSTRUCTION=200
BARADB_VECTOR_EF_SEARCH=128
BARADB_VECTOR_M=32
```