# Мониторинг и Наблюдаемост

## Health Checks

### HTTP Health Endpoint

```bash
curl http://localhost:9470/health
```

Отговор:

```json
{
  "status": "healthy",
  "version": "1.1.0",
  "uptime_seconds": 86400,
  "checks": {
    "storage": "ok",
    "memory": "ok",
    "connections": "ok"
  }
}
```

### Readiness Probe

```bash
curl http://localhost:9470/ready
```

Връща `200 OK` когато сървърът е готов да приема трафик, `503` по време на стартиране.

## Метрики

### Prometheus-Съвместими Метрики

```bash
curl http://localhost:9470/metrics
```

Примерен изход:

```
# HELP baradb_queries_total Общ брой изпълнени заявки
# TYPE baradb_queries_total counter
baradb_queries_total 152340

# HELP baradb_queries_duration_seconds Хистограма на времетраене на заявки
# TYPE baradb_queries_duration_seconds histogram
baradb_queries_duration_seconds_bucket{le="0.001"} 45000
baradb_queries_duration_seconds_bucket{le="0.01"} 120000
baradb_queries_duration_seconds_bucket{le="0.1"} 148000

# HELP baradb_storage_lsm_size_bytes Общ размер на LSM-Tree
# TYPE baradb_storage_lsm_size_bytes gauge
baradb_storage_lsm_size_bytes 2147483648

# HELP baradb_cache_hit_rate Page cache hit rate
# TYPE baradb_cache_hit_rate gauge
baradb_cache_hit_rate 0.94

# HELP baradb_active_connections Активни клиентски връзки
# TYPE baradb_active_connections gauge
baradb_active_connections 42
```

### JSON Метрики

```bash
curl http://localhost:9470/metrics?format=json
```

## Логване

### Нива на Логване

| Ниво | Описание |
|------|----------|
| `debug` | Детайлни вътрешни операции |
| `info` | Нормални операции |
| `warn` | Възстановими проблеми |
| `error` | Грешки, изискващи внимание |

### Структурирани JSON Логове

```bash
BARADB_LOG_LEVEL=info \
BARADB_LOG_FORMAT=json \
BARADB_LOG_FILE=/var/log/baradb/baradb.log \
./build/baradadb
```

Примерен лог запис:

```json
{
  "timestamp": "2025-01-15T10:30:00.123Z",
  "level": "info",
  "component": "server",
  "message": "Query executed",
  "query": "SELECT * FROM users",
  "duration_ms": 12,
  "client_ip": "10.0.0.15"
}
```

### Текстов Формат

```bash
BARADB_LOG_FORMAT=text ./build/baradadb
```

## Правила за Алармиране

### Prometheus AlertManager

```yaml
groups:
  - name: baradb
    rules:
      - alert: BaraDBHighErrorRate
        expr: rate(baradb_errors_total[5m]) > 0.1
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Висок процент грешки в BaraDB"

      - alert: BaraDBLowCacheHitRate
        expr: baradb_cache_hit_rate < 0.8
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Cache hit rate под 80%"

      - alert: BaraDBHighConnections
        expr: baradb_active_connections > 800
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Голям брой връзки към BaraDB"

      - alert: BaraDBDown
        expr: up{job="baradb"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "BaraDB инстанцията не работи"
```

## Разпределен Мониторинг

### Клъстерни Метрики

За Raft клъстери, мониторирайте:

```bash
curl http://node1:9470/metrics/cluster
```

```json
{
  "cluster_id": "baradb-cluster-1",
  "nodes": [
    {"id": "node1", "role": "leader", "health": "healthy"},
    {"id": "node2", "role": "follower", "health": "healthy"},
    {"id": "node3", "role": "follower", "health": "healthy"}
  ],
  "raft_log_index": 15420,
  "raft_commit_index": 15420,
  "shards": 4,
  "replication_lag_ms": 5
}
```

## Профилиране на Производителност

### Вграден CPU Profiler

```bash
curl -X POST http://localhost:9470/debug/pprof/cpu?seconds=30 > cpu.prof
```

### Memory Profiler

```bash
curl http://localhost:9470/debug/pprof/heap > heap.prof
```

## Отстраняване на Проблеми с Метрики

| Симптом | Метрика | Действие |
|---------|--------|----------|
| Бавни заявки | `baradb_queries_duration_seconds` | Проверете cache hit rate, добавете индекси |
| Висока памет | `process_resident_memory_bytes` | Намалете memtable/cache размери |
| Растящо съхранение | `baradb_storage_lsm_size_bytes` | Пуснете ръчен compaction |
| Грешки при връзка | `baradb_active_connections` | Увеличете connection pool или добавете възли |
| Репликационно закъснение | `baradb_replication_lag_ms` | Проверете мрежата, увеличете ресурсите |
