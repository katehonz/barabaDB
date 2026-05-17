# Monitoring & Observability

## Health Checks

### HTTP Health Endpoint

```bash
curl http://localhost:9470/health
```

Antwort:

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

Gibt `200 OK` zurück wenn der Server bereit ist Traffic anzunehmen, `503` während des Starts.

## Metrics

### Prometheus-kompatible Metrics

```bash
curl http://localhost:9470/metrics
```

Beispielausgabe:

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
curl http://localhost:9470/metrics?format=json
```

## Logging

### Log-Level

| Level | Beschreibung |
|-------|--------------|
| `debug` | Detaillierte interne Operationen |
| `info` | Normale Operationen |
| `warn` | Behebbare Probleme |
| `error` | Fehler die Aufmerksamkeit erfordern |

### Strukturiertes JSON Logging

```bash
BARADB_LOG_LEVEL=info \
BARADB_LOG_FORMAT=json \
BARADB_LOG_FILE=/var/log/baradb/baradb.log \
./build/baradadb
```

Beispiel-Log-Eintrag:

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

### Textformat

```bash
BARADB_LOG_FORMAT=text ./build/baradadb
```

Ausgabe:

```
2025-01-15T10:30:00.123Z [INFO] server: Query executed | query="SELECT * FROM users" duration_ms=12
```

## Alerting-Regeln

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

Dashboard ID `baradb-001` importieren oder das bereitgestellte JSON in `monitoring/grafana-dashboard.json` verwenden.

Wichtige Panels:
- Queries pro Sekunde
- Query-Latenz Perzentile (p50, p95, p99)
- Speichergröße und SSTable-Anzahl
- Cache Hit Rate
- Aktive Verbindungen
- Transaktionsrate
- Fehlerrate

## Distributed Monitoring

### Cluster Metrics

Für Raft-Cluster überwachen:

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

## Performance Profiling

### Eingebauter CPU Profiler

```bash
curl -X POST http://localhost:9470/debug/pprof/cpu?seconds=30 > cpu.prof
```

### Memory Profiler

```bash
curl http://localhost:9470/debug/pprof/heap > heap.prof
```

### Trace

```bash
curl -X POST http://localhost:9470/debug/pprof/trace?seconds=5 > trace.out
```

## Log-Aggregation

### Fluent Bit Konfiguration

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

## Troubleshooting mit Metrics

| Symptom | Metrik | Aktion |
|---------|--------|--------|
| Langsame Abfragen | `baradb_queries_duration_seconds` | Cache Hit Rate prüfen, Indizes in Betracht ziehen |
| Hoher Speicherverbrauch | `process_resident_memory_bytes` | Memtable/Cache-Größen reduzieren |
| Speicher wächst | `baradb_storage_lsm_size_bytes` | Manuelle Compaction ausführen |
| Verbindungsfehler | `baradb_active_connections` | Connection Pool erhöhen oder Knoten hinzufügen |
| Replikations-Lag | `baradb_replication_lag_ms` | Netzwerk prüfen, Ressourcen erhöhen |
