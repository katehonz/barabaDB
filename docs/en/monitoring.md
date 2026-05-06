# Monitoring & Observability

## Health Checks

### HTTP Health Endpoint

```bash
curl http://localhost:8080/health
```

Response:

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
curl http://localhost:8080/ready
```

Returns `200 OK` when the server is ready to accept traffic, `503` during startup.

## Metrics

### Prometheus-Compatible Metrics

```bash
curl http://localhost:8080/metrics
```

Example output:

```
# HELP baradb_queries_total Total number of queries executed
# TYPE baradb_queries_total counter
baradb_queries_total 152340

# HELP baradb_queries_duration_seconds Query duration histogram
# TYPE baradb_queries_duration_seconds histogram
baradb_queries_duration_seconds_bucket{le="0.001"} 45000
baradb_queries_duration_seconds_bucket{le="0.01"} 120000
baradb_queries_duration_seconds_bucket{le="0.1"} 148000

# HELP baradb_storage_lsm_size_bytes LSM-Tree total size
# TYPE baradb_storage_lsm_size_bytes gauge
baradb_storage_lsm_size_bytes 2147483648

# HELP baradb_storage_sstables Number of SSTables
# TYPE baradb_storage_sstables gauge
baradb_storage_sstables 12

# HELP baradb_cache_hit_rate Page cache hit rate
# TYPE baradb_cache_hit_rate gauge
baradb_cache_hit_rate 0.94

# HELP baradb_active_connections Active client connections
# TYPE baradb_active_connections gauge
baradb_active_connections 42

# HELP baradb_txns_active Active transactions
# TYPE baradb_txns_active gauge
baradb_txns_active 7

# HELP baradb_txns_committed_total Total committed transactions
# TYPE baradb_txns_committed_total counter
baradb_txns_committed_total 89123
```

### JSON Metrics

```bash
curl http://localhost:8080/metrics?format=json
```

## Logging

### Log Levels

| Level | Description |
|-------|-------------|
| `debug` | Detailed internal operations |
| `info` | Normal operations |
| `warn` | Recoverable issues |
| `error` | Failures requiring attention |

### Structured JSON Logs

```bash
BARADB_LOG_LEVEL=info \
BARADB_LOG_FORMAT=json \
BARADB_LOG_FILE=/var/log/baradb/baradb.log \
./build/baradadb
```

Example log entry:

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

### Text Format

```bash
BARADB_LOG_FORMAT=text ./build/baradadb
```

Output:

```
2025-01-15T10:30:00.123Z [INFO] server: Query executed | query="SELECT * FROM users" duration_ms=12
```

## Alerting Rules

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
          summary: "BaraDB error rate is high"

      - alert: BaraDBLowCacheHitRate
        expr: baradb_cache_hit_rate < 0.8
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "BaraDB cache hit rate below 80%"

      - alert: BaraDBHighConnections
        expr: baradb_active_connections > 800
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "BaraDB connection count is high"

      - alert: BaraDBDown
        expr: up{job="baradb"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "BaraDB instance is down"
```

## Grafana Dashboard

Import dashboard ID `baradb-001` or use the provided JSON in `monitoring/grafana-dashboard.json`.

Key panels:
- Queries per second
- Query latency percentiles (p50, p95, p99)
- Storage size and SSTable count
- Cache hit rate
- Active connections
- Transaction rate
- Error rate

## Distributed Monitoring

### Cluster Metrics

For Raft clusters, monitor:

```bash
curl http://node1:8080/metrics/cluster
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

## Performance Profiling

### Built-in CPU Profiler

```bash
curl -X POST http://localhost:8080/debug/pprof/cpu?seconds=30 > cpu.prof
```

### Memory Profiler

```bash
curl http://localhost:8080/debug/pprof/heap > heap.prof
```

### Trace

```bash
curl -X POST http://localhost:8080/debug/pprof/trace?seconds=5 > trace.out
```

## Log Aggregation

### Fluent Bit Configuration

```ini
[INPUT]
    Name tail
    Path /var/log/baradb/baradb.log
    Parser json
    Tag baradb

[OUTPUT]
    Name elasticsearch
    Match baradb
    Host elasticsearch
    Port 9200
    Index baradb-logs
```

## Troubleshooting with Metrics

| Symptom | Metric | Action |
|---------|--------|--------|
| Slow queries | `baradb_queries_duration_seconds` | Check cache hit rate, consider adding indexes |
| High memory | `process_resident_memory_bytes` | Reduce memtable/cache sizes |
| Storage growing | `baradb_storage_lsm_size_bytes` | Run manual compaction |
| Connection errors | `baradb_active_connections` | Increase connection pool or add nodes |
| Replication lag | `baradb_replication_lag_ms` | Check network, increase resources |
