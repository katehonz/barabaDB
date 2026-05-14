# Configuration Reference

BaraDB can be configured via **environment variables**, a **config file**, or **command-line flags**.

## Priority Order

1. Command-line flags (highest priority)
2. Environment variables
3. Config file (`baradb.conf` or `baradb.json`)
4. Built-in defaults (lowest priority)

## Environment Variables

### Network

| Variable | Default | Description |
|----------|---------|-------------|
| `BARADB_ADDRESS` | `127.0.0.1` | Bind address |
| `BARADB_PORT` | `9472` | TCP binary protocol port |
| `BARADB_HTTP_PORT` | `9470` | HTTP/REST API port |
| `BARADB_WS_PORT` | `9471` | WebSocket port |

### Storage

| Variable | Default | Description |
|----------|---------|-------------|
| `BARADB_DATA_DIR` | `./data` | Data directory path |
| `BARADB_MEMTABLE_SIZE_MB` | `64` | MemTable size in MB |
| `BARADB_CACHE_SIZE_MB` | `256` | Page cache size in MB |
| `BARADB_WAL_SYNC_INTERVAL_MS` | `0` | WAL fsync interval (0 = every write) |
| `BARADB_COMPACTION_INTERVAL_MS` | `60000` | Background compaction interval |
| `BARADB_BLOOM_BITS_PER_KEY` | `10` | Bloom filter bits per key |

### TLS/SSL

| Variable | Default | Description |
|----------|---------|-------------|
| `BARADB_TLS_ENABLED` | `false` | Enable TLS |
| `BARADB_CERT_FILE` | — | Path to TLS certificate |
| `BARADB_KEY_FILE` | — | Path to TLS private key |

### Security

| Variable | Default | Description |
|----------|---------|-------------|
| `BARADB_AUTH_ENABLED` | `false` | Enable authentication |
| `BARADB_JWT_SECRET` | — | JWT signing secret |
| `BARADB_RATE_LIMIT_GLOBAL` | `10000` | Global requests per second |
| `BARADB_RATE_LIMIT_PER_CLIENT` | `1000` | Per-client requests per second |

### Logging

| Variable | Default | Description |
|----------|---------|-------------|
| `BARADB_LOG_LEVEL` | `info` | Log level: debug, info, warn, error |
| `BARADB_LOG_FILE` | — | Log file path (stdout if empty) |
| `BARADB_LOG_FORMAT` | `json` | Log format: json, text |

### Vector Engine

| Variable | Default | Description |
|----------|---------|-------------|
| `BARADB_VECTOR_M` | `16` | HNSW `M` parameter |
| `BARADB_VECTOR_EF_CONSTRUCTION` | `200` | HNSW `efConstruction` |
| `BARADB_VECTOR_EF_SEARCH` | `64` | HNSW `efSearch` |

### Graph Engine

| Variable | Default | Description |
|----------|---------|-------------|
| `BARADB_GRAPH_PAGE_RANK_ITERATIONS` | `20` | PageRank iteration count |
| `BARADB_GRAPH_PAGE_RANK_DAMPING` | `0.85` | PageRank damping factor |
| `BARADB_GRAPH_LOUVAIN_RESOLUTION` | `1.0` | Louvain resolution parameter |

### Distributed

| Variable | Default | Description |
|----------|---------|-------------|
| `BARADB_RAFT_NODE_ID` | — | Unique node ID in cluster |
| `BARADB_RAFT_PEERS` | — | Comma-separated list of peer addresses |
| `BARADB_RAFT_PORT` | `9001` | Raft internal communication port |
| `BARADB_SHARD_COUNT` | `1` | Number of shards |
| `BARADB_REPLICATION_FACTOR` | `1` | Replication factor |

## Config File

### baradb.conf (INI-like)

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

## Command-Line Flags

```bash
./build/baradadb --help
```

```
BaraDB v1.1.0 — Multimodal Database Engine

Usage:
  baradadb [options]

Options:
  -c, --config <file>       Config file path
  -p, --port <port>         TCP binary port (default: 9472)
  --http-port <port>        HTTP port (default: 9470)
  --ws-port <port>          WebSocket port (default: 9471)
  -d, --data-dir <dir>      Data directory (default: ./data)
  --tls-cert <file>         TLS certificate file
  --tls-key <file>          TLS private key file
  --log-level <level>       Log level: debug, info, warn, error
  --log-file <file>         Log file path
  --shell                   Start interactive shell
  --version                 Show version
  --recover                 Run WAL recovery
  --checkpoint <file>       Checkpoint for recovery
  -h, --help                Show this help
```

## Example Configurations

### Development

```bash
./build/baradadb \
  --log-level debug \
  --data-dir ./dev_data
```

### Production Single Node

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

### Production Cluster (3 nodes)

```bash
# Node 1
BARADB_ADDRESS=0.0.0.0 \
BARADB_PORT=9472 \
BARADB_RAFT_NODE_ID=node1 \
BARADB_RAFT_PEERS=node2:9001,node3:9001 \
BARADB_SHARD_COUNT=4 \
BARADB_REPLICATION_FACTOR=2 \
./build/baradadb
```
