# İzleme ve Gözlemlenebilirlik

## Sağlık Kontrolleri

### HTTP Sağlık Endpoint'i

```bash
curl http://localhost:9470/health
```

Yanıt:

```json
{
  "status": "healthy",
  "version": "0.1.0",
  "uptime_seconds": 86400,
  "checks": {
    "storage": "ok",
    "memory": "ok",
    "connections": "ok"
  }
}
```

## Metrikler

### Prometheus Uyumlu Metrikler

```bash
curl http://localhost:9470/metrics
```

Örnek çıktı:

```
baradb_queries_total 152340
baradb_queries_duration_seconds_bucket{le="0.001"} 45000
baradb_storage_lsm_size_bytes 2147483648
baradb_cache_hit_rate 0.94
baradb_active_connections 42
```

## Günlükleme

### Günlük Seviyeleri

| Seviye | Açıklama |
|--------|----------|
| `debug` | Detaylı dahili operasyonlar |
| `info` | Normal operasyonlar |
| `warn` | Kurtarılabilir sorunlar |
| `error` | Dikkat gerektiren başarısızlıklar |

### Yapılandırılmış JSON Günlükleri

```bash
BARADB_LOG_LEVEL=info \
BARADB_LOG_FORMAT=json \
BARADB_LOG_FILE=/var/log/baradb/baradb.log \
./build/baradadb
```

## Grafana Dashboard

Dashboard ID `baradb-001` içe aktarın veya `monitoring/grafana-dashboard.json` içindeki JSON'u kullanın.

Temel paneller:
- Saniyedeki sorgular
- Sorgu gecikme yüzdeleri (p50, p95, p99)
- Depolama boyutu ve SSTable sayısı
- Önbellek isabet oranı
- Aktif bağlantılar
- İşlem oranı
- Hata oranı

## Metriklerle Sorun Giderme

| Belirti | Metrik | Eylem |
|---------|--------|-------|
| Yavaş sorgular | `baradb_queries_duration_seconds` | Önbellek isabet oranını kontrol edin, indeks ekleyin |
| Yüksek bellek | `process_resident_memory_bytes` | Memtable/cache boyutlarını azaltın |
| Depolama büyüyor | `baradb_storage_lsm_size_bytes` | Manuel sıkıştırma çalıştırın |
| Bağlantı hataları | `baradb_active_connections` | Bağlantı havuzunu artırın veya düğüm ekleyin |