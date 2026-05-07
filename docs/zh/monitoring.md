# 监控与可观测性

## 健康检查

### HTTP 健康端点

```bash
curl http://localhost:9470/health
```

响应：

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

服务器准备接受流量时返回 `200 OK`，启动期间返回 `503`。

## 指标

### Prometheus 兼容指标

```bash
curl http://localhost:9470/metrics
```

示例输出：

```
baradb_queries_total 152340
baradb_queries_duration_seconds_bucket{le="0.001"} 45000
baradb_storage_lsm_size_bytes 2147483648
baradb_cache_hit_rate 0.94
baradb_active_connections 42
```

### JSON 格式指标

```bash
curl http://localhost:9470/metrics?format=json
```

## 日志

### 日志级别

| 级别 | 描述 |
|------|------|
| `debug` | 详细的内部操作 |
| `info` | 正常操作 |
| `warn` | 可恢复的问题 |
| `error` | 需要关注的故障 |

### 结构化 JSON 日志

```bash
BARADB_LOG_LEVEL=info \
BARADB_LOG_FORMAT=json \
BARADB_LOG_FILE=/var/log/baradb/baradb.log \
./build/baradadb
```

## Grafana 仪表板

导入仪表板 ID `baradb-001` 或使用 `monitoring/grafana-dashboard.json` 中的 JSON。

关键面板：
- 每秒查询数
- 查询延迟百分位数 (p50, p95, p99)
- 存储大小和 SSTable 数量
- 缓存命中率
- 活跃连接数
- 事务率
- 错误率

## 集群监控

```bash
curl http://node1:9470/metrics/cluster
```

## 使用指标进行故障排除

| 症状 | 指标 | 操作 |
|------|------|------|
| 查询慢 | `baradb_queries_duration_seconds` | 检查缓存命中率，考虑添加索引 |
| 内存高 | `process_resident_memory_bytes` | 减小 memtable/cache 大小 |
| 存储增长 | `baradb_storage_lsm_size_bytes` | 运行手动压缩 |
| 连接错误 | `baradb_active_connections` | 增加连接池或添加节点 |