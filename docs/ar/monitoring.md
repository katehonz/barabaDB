# المراقبة والقابلية للملاحظة

## فحوصات الصحة

### نقطة نهاية صحة HTTP

```bash
curl http://localhost:9470/health
```

الاستجابة:

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

## المقاييس

### مقاييس متوافقة مع Prometheus

```bash
curl http://localhost:9470/metrics
```

مثال على المخرجات:

```
baradb_queries_total 152340
baradb_queries_duration_seconds_bucket{le="0.001"} 45000
baradb_storage_lsm_size_bytes 2147483648
baradb_cache_hit_rate 0.94
baradb_active_connections 42
```

## التسجيل

### مستويات السجل

| المستوى | الوصف |
|---------|-------|
| `debug` | عمليات داخلية مفصلة |
| `info` | عمليات عادية |
| `warn` | مشاكل قابلة للاسترداد |
| `error` | فشل يستلزم الاهتمام |

### سجلات JSON المهيكلة

```bash
BARADB_LOG_LEVEL=info \
BARADB_LOG_FORMAT=json \
BARADB_LOG_FILE=/var/log/baradb/baradb.log \
./build/baradadb
```

## لوحة Grafana

استيراد معرف اللوحة `baradb-001` أو استخدام JSON في `monitoring/grafana-dashboard.json`.

اللوحات الرئيسية:
- الاستعلامات في الثانية
- نسب مئوية لتأخير الاستعلام (p50, p95, p99)
- حجم التخزين وعدد SSTable
- معدل إصابة ذاكرة التخزين المؤقت
- الاتصالات النشطة
- معدل المعاملات
- معدل الأخطاء

## حل المشكلات بالمقاييس

| العَرَض | المقاييس | الإجراء |
|---------|----------|---------|
| استعلامات بطيئة | `baradb_queries_duration_seconds` | فحص معدل إصابة ذاكرة التخزين المؤقت، إضافة فهارس |
| ذاكرة عالية | `process_resident_memory_bytes` | تقليل أحجام memtable/cache |
| نمو التخزين | `baradb_storage_lsm_size_bytes` | تشغيل الضغط اليدوي |
| أخطاء الاتصال | `baradb_active_connections` | زيادة تجمع الاتصالات أو إضافة العقد |