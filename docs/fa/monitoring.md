# پایش و مشاهده‌پذیری

## بررسی‌های سلامت

### endpoint سلامت HTTP

```bash
curl http://localhost:9470/health
```

پاسخ:

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

## معیارها

### معیارهای سازگار با Prometheus

```bash
curl http://localhost:9470/metrics
```

### معیارهای JSON

```bash
curl http://localhost:9470/metrics?format=json
```

## لاگ‌گذاری

### سطوح لاگ

| سطح | توضیح |
|------|--------|
| `debug` | عملیات داخلی تفصیلی |
| `info` | عملیات عادی |
| `warn` | مشکلات قابل بازیابی |
| `error` | خطاهای نیازمند توجه |

### لاگ‌های JSON ساختاریافته

```bash
BARADB_LOG_LEVEL=info \
BARADB_LOG_FORMAT=json \
BARADB_LOG_FILE=/var/log/baradb/baradb.log \
./build/baradadb
```

## Grafana

پنل‌های کلیدی:
- Queries per second
- Latency درصدها (p50, p95, p99)
- اندازه ذخیره‌سازی
- نرخ hit کش
- اتصالات فعال
- نرخ تراکنش
- نرخ خطا

## عیب‌یابی با معیارها

| علامت | معیار | عمل |
|-------|-------|-----|
| کوئری‌های کند | `baradb_queries_duration_seconds` | بررسی نرخ hit کش |
| حافظه بالا | `process_resident_memory_bytes` | کاهش اندازه‌های memtable/cache |
| رشد ذخیره‌سازی | `baradb_storage_lsm_size_bytes` | اجرای فشرده‌سازی دستی |
| خطاهای اتصال | `baradb_active_connections` | افزایش استخر اتصال |