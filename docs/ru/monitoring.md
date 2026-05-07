# Мониторинг и наблюдаемость

## Проверки здоровья

### HTTP endpoint проверки здоровья

```bash
curl http://localhost:9470/health
```

Ответ:

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

### Readiness Probe

```bash
curl http://localhost:9470/ready
```

Возвращает `200 OK` когда сервер готов принимать трафик, `503` во время запуска.

## Метрики

### Prometheus-совместимые метрики

```bash
curl http://localhost:9470/metrics
```

Пример вывода:

```
# HELP baradb_queries_total Total number of queries executed
# TYPE baradb_queries_total counter
baradb_queries_total 152340

# HELP baradb_queries_duration_seconds Query duration histogram
# TYPE baradb_queries_duration_seconds histogram
baradb_queries_duration_seconds_bucket{le="0.001"} 45000

# HELP baradb_storage_lsm_size_bytes LSM-Tree total size
# TYPE baradb_storage_lsm_size_bytes gauge
baradb_storage_lsm_size_bytes 2147483648

# HELP baradb_cache_hit_rate Page cache hit rate
# TYPE baradb_cache_hit_rate gauge
baradb_cache_hit_rate 0.94

# HELP baradb_active_connections Active client connections
# TYPE baradb_active_connections gauge
baradb_active_connections 42
```

### Метрики в формате JSON

```bash
curl http://localhost:9470/metrics?format=json
```

## Логирование

### Уровни логирования

| Уровень | Описание |
|---------|----------|
| `debug` | Детальные внутренние операции |
| `info` | Нормальные операции |
| `warn` | Восстанавливаемые проблемы |
| `error` | Сбои требующие внимания |

### Структурированные JSON логи

```bash
BARADB_LOG_LEVEL=info \
BARADB_LOG_FORMAT=json \
BARADB_LOG_FILE=/var/log/baradb/baradb.log \
./build/baradadb
```

Пример записи лога:

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

## Grafana Dashboard

Импортируйте dashboard ID `baradb-001` или используйте JSON в `monitoring/grafana-dashboard.json`.

Ключевые панели:
- Queries per second
- Query latency percentiles (p50, p95, p99)
- Storage size and SSTable count
- Cache hit rate
- Active connections
- Transaction rate
- Error rate

## Мониторинг кластера

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

## Устранение проблем с метриками

| Симптом | Метрика | Действие |
|---------|---------|----------|
| Медленные запросы | `baradb_queries_duration_seconds` | Проверить cache hit rate, добавить индексы |
| Высокая память | `process_resident_memory_bytes` | Уменьшить размеры memtable/cache |
| Рост хранилища | `baradb_storage_lsm_size_bytes` | Запустить ручную компактификацию |
| Ошибки соединений | `baradb_active_connections` | Увеличить пул или добавить узлы |
| Отставание репликации | `baradb_replication_lag_ms` | Проверить сеть, увеличить ресурсы |