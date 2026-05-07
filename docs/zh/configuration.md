# BaraDB - 配置参考

BaraDB 可以通过**环境变量**、**配置文件**或**命令行标志**进行配置。

## 优先级顺序

1. 命令行标志（最高优先级）
2. 环境变量
3. 配置文件 (`baradb.conf` 或 `baradb.json`)
4. 内置默认值（最低优先级）

## 环境变量

### 网络

| 变量 | 默认值 | 描述 |
|------|--------|------|
| `BARADB_ADDRESS` | `127.0.0.1` | 绑定地址 |
| `BARADB_PORT` | `9472` | TCP 二进制协议端口 |
| `BARADB_HTTP_PORT` | `9470` | HTTP/REST API 端口 |
| `BARADB_WS_PORT` | `9471` | WebSocket 端口 |

### 存储

| 变量 | 默认值 | 描述 |
|------|--------|------|
| `BARADB_DATA_DIR` | `./data` | 数据目录路径 |
| `BARADB_MEMTABLE_SIZE_MB` | `64` | MemTable 大小（MB） |
| `BARADB_CACHE_SIZE_MB` | `256` | 页面缓存大小（MB） |
| `BARADB_WAL_SYNC_INTERVAL_MS` | `0` | WAL fsync 间隔（0 = 每次写入） |
| `BARADB_COMPACTION_INTERVAL_MS` | `60000` | 后台压缩间隔 |
| `BARADB_BLOOM_BITS_PER_KEY` | `10` | 每个键的 Bloom 过滤器位数 |

### TLS/SSL

| 变量 | 默认值 | 描述 |
|------|--------|------|
| `BARADB_TLS_ENABLED` | `false` | 启用 TLS |
| `BARADB_CERT_FILE` | — | TLS 证书路径 |
| `BARADB_KEY_FILE` | — | TLS 私钥路径 |

### 安全

| 变量 | 默认值 | 描述 |
|------|--------|------|
| `BARADB_AUTH_ENABLED` | `false` | 启用认证 |
| `BARADB_JWT_SECRET` | — | JWT 签名密钥 |
| `BARADB_RATE_LIMIT_GLOBAL` | `10000` | 全局请求数/秒 |
| `BARADB_RATE_LIMIT_PER_CLIENT` | `1000` | 每客户端请求数/秒 |

### 日志

| 变量 | 默认值 | 描述 |
|------|--------|------|
| `BARADB_LOG_LEVEL` | `info` | 日志级别：debug, info, warn, error |
| `BARADB_LOG_FILE` | — | 日志文件路径（空则输出到 stdout） |
| `BARADB_LOG_FORMAT` | `json` | 日志格式：json, text |

### 向量引擎

| 变量 | 默认值 | 描述 |
|------|--------|------|
| `BARADB_VECTOR_M` | `16` | HNSW `M` 参数 |
| `BARADB_VECTOR_EF_CONSTRUCTION` | `200` | HNSW `efConstruction` |
| `BARADB_VECTOR_EF_SEARCH` | `64` | HNSW `efSearch` |

### 图引擎

| 变量 | 默认值 | 描述 |
|------|--------|------|
| `BARADB_GRAPH_PAGE_RANK_ITERATIONS` | `20` | PageRank 迭代次数 |
| `BARADB_GRAPH_PAGE_RANK_DAMPING` | `0.85` | PageRank 阻尼因子 |
| `BARADB_GRAPH_LOUVAIN_RESOLUTION` | `1.0` | Louvain 分辨率参数 |

### 分布式

| 变量 | 默认值 | 描述 |
|------|--------|------|
| `BARADB_RAFT_NODE_ID` | — | 集群中的唯一节点 ID |
| `BARADB_RAFT_PEERS` | — | 逗号分隔的节点地址列表 |
| `BARADB_RAFT_PORT` | `9001` | Raft 内部通信端口 |
| `BARADB_SHARD_COUNT` | `1` | 分片数量 |
| `BARADB_REPLICATION_FACTOR` | `1` | 复制因子 |

## 配置文件

### baradb.conf (INI 风格)

```ini
[server]
address = "0.0.0.0"
port = 9472
http_port = 9470
ws_port = 9471

[storage]
data_dir = "/var/lib/baradb"
memtable_size_mb = 256
cache_size_mb = 512
wal_sync_interval_ms = 10
compaction_interval_ms = 30000

[tls]
enabled = true
cert_file = "/etc/baradb/server.crt"
key_file = "/etc/baradb/server.key"

[auth]
enabled = true
jwt_secret = "change-me-in-production"
rate_limit_global = 10000
rate_limit_per_client = 1000

[logging]
level = "info"
format = "json"
file = "/var/log/baradb/baradb.log"

[vector]
m = 16
ef_construction = 200
ef_search = 64

[cluster]
raft_node_id = "node1"
raft_peers = "node2:9001,node3:9001"
```

### baradb.json

```json
{
  "server": {
    "address": "0.0.0.0",
    "port": 9472,
    "http_port": 9470,
    "ws_port": 9471
  },
  "storage": {
    "data_dir": "/var/lib/baradb",
    "memtable_size_mb": 256,
    "cache_size_mb": 512
  },
  "tls": {
    "enabled": true,
    "cert_file": "/etc/baradb/server.crt",
    "key_file": "/etc/baradb/server.key"
  }
}
```

## 命令行标志

```bash
./build/baradadb --help
```

```
BaraDB v0.1.0 — Multimodal Database Engine

Usage:
  baradadb [options]

Options:
  -c, --config <file>       配置文件路径
  -p, --port <port>         TCP 二进制端口（默认：9472）
  --http-port <port>        HTTP 端口（默认：9470）
  --ws-port <port>         WebSocket 端口（默认：9471）
  -d, --data-dir <dir>      数据目录（默认：./data）
  --tls-cert <file>         TLS 证书文件
  --tls-key <file>          TLS 私钥文件
  --log-level <level>       日志级别：debug, info, warn, error
  --log-file <file>         日志文件路径
  --shell                   启动交互式 shell
  --version                 显示版本
  --recover                 运行 WAL 恢复
  --checkpoint <file>      用于恢复的检查点
  -h, --help                显示此帮助信息
```

## 配置示例

### 开发环境

```bash
./build/baradadb \
  --log-level debug \
  --data-dir ./dev_data
```

### 生产环境单节点

```bash
BARADB_TLS_ENABLED=true \
BARADB_CERT_FILE=/etc/baradb/server.crt \
BARADB_KEY_FILE=/etc/baradb/server.key \
BARADB_AUTH_ENABLED=true \
BARADB_JWT_SECRET="$(openssl rand -hex 32)" \
BARADB_LOG_LEVEL=warn \
BARADB_LOG_FILE=/var/log/baradb/baradb.log \
BARADB_MEMTABLE_SIZE_MB=256 \
BARADB_CACHE_SIZE_MB=1024 \
./build/baradadb
```

### 生产环境集群（3 节点）

```bash
# 节点 1
BARADB_ADDRESS=0.0.0.0 \
BARADB_PORT=9472 \
BARADB_RAFT_NODE_ID=node1 \
BARADB_RAFT_PEERS=node2:9001,node3:9001 \
BARADB_SHARD_COUNT=4 \
BARADB_REPLICATION_FACTOR=2 \
./build/baradadb
```