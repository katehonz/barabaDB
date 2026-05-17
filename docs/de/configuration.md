# Konfigurationsreferenz

BaraDB kann über **Environment-Variablen**, eine **Konfigurationsdatei** oder **Kommandozeilen-Flags** konfiguriert werden.

## Prioritätsreihenfolge

1. Kommandozeilen-Flags (höchste Priorität)
2. Environment-Variablen
3. Konfigurationsdatei (`baradb.conf` oder `baradb.json`)
4. Integrierte Standardwerte (niedrigste Priorität)

## Environment-Variablen

### Netzwerk

| Variable | Standard | Beschreibung |
|----------|---------|-------------|
| `BARADB_ADDRESS` | `127.0.0.1` | Bind-Adresse |
| `BARADB_PORT` | `9472` | TCP Binary Protocol Port |
| `BARADB_HTTP_PORT` | `9470` | HTTP/REST API Port |
| `BARADB_WS_PORT` | `9471` | WebSocket Port |

### Speicher

| Variable | Standard | Beschreibung |
|----------|---------|-------------|
| `BARADB_DATA_DIR` | `./data` | Datenverzeichnis-Pfad |
| `BARADB_MEMTABLE_SIZE_MB` | `64` | MemTable-Größe in MB |
| `BARADB_CACHE_SIZE_MB` | `256` | Page-Cache-Größe in MB |
| `BARADB_WAL_SYNC_INTERVAL_MS` | `0` | WAL fsync Intervall (0 = bei jedem Write) |
| `BARADB_COMPACTION_INTERVAL_MS` | `60000` | Background Compaction Intervall |
| `BARADB_BLOOM_BITS_PER_KEY` | `10` | Bloom-Filter Bits pro Schlüssel |

### TLS/SSL

| Variable | Standard | Beschreibung |
|----------|---------|-------------|
| `BARADB_TLS_ENABLED` | `false` | TLS aktivieren |
| `BARADB_CERT_FILE` | — | Pfad zum TLS-Zertifikat |
| `BARADB_KEY_FILE` | — | Pfad zum TLS Private Key |

### Sicherheit

| Variable | Standard | Beschreibung |
|----------|---------|-------------|
| `BARADB_AUTH_ENABLED` | `false` | Authentifizierung aktivieren |
| `BARADB_JWT_SECRET` | — | JWT Signatur-Geheimnis |
| `BARADB_RATE_LIMIT_GLOBAL` | `10000` | Globale Requests pro Sekunde |
| `BARADB_RATE_LIMIT_PER_CLIENT` | `1000` | Per-Client Requests pro Sekunde |

### Logging

| Variable | Standard | Beschreibung |
|----------|---------|-------------|
| `BARADB_LOG_LEVEL` | `info` | Log-Level: debug, info, warn, error |
| `BARADB_LOG_FILE` | — | Log-Datei-Pfad (stdout wenn leer) |
| `BARADB_LOG_FORMAT` | `json` | Log-Format: json, text |

### Vector Engine

| Variable | Standard | Beschreibung |
|----------|---------|-------------|
| `BARADB_VECTOR_M` | `16` | HNSW `M` Parameter |
| `BARADB_VECTOR_EF_CONSTRUCTION` | `200` | HNSW `efConstruction` |
| `BARADB_VECTOR_EF_SEARCH` | `64` | HNSW `efSearch` |

### Graph Engine

| Variable | Standard | Beschreibung |
|----------|---------|-------------|
| `BARADB_GRAPH_PAGE_RANK_ITERATIONS` | `20` | PageRank Iterationsanzahl |
| `BARADB_GRAPH_PAGE_RANK_DAMPING` | `0.85` | PageRank Dämpfungsfaktor |
| `BARADB_GRAPH_LOUVAIN_RESOLUTION` | `1.0` | Louvain Resolution-Parameter |

### Distributed

| Variable | Standard | Beschreibung |
|----------|---------|-------------|
| `BARADB_RAFT_NODE_ID` | — | Eindeutige Knoten-ID im Cluster |
| `BARADB_RAFT_PEERS` | — | Komma-getrennte Liste von Peer-Adressen |
| `BARADB_RAFT_PORT` | `9001` | Raft interne Kommunikation Port |
| `BARADB_SHARD_COUNT` | `1` | Anzahl der Shards |
| `BARADB_REPLICATION_FACTOR` | `1` | Replikationsfaktor |

## Konfigurationsdatei

### baradb.conf (INI-ähnlich)

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

## Kommandozeilen-Flags

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

## Beispielkonfigurationen

### Entwicklung

```bash
./build/baradadb \
  --log-level debug \
  --data-dir ./dev_data
```

### Produktion Single Node

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

### Produktion Cluster (3 Knoten)

```bash
# Knoten 1
BARADB_ADDRESS=0.0.0.0 \
BARADB_PORT=9472 \
BARADB_RAFT_NODE_ID=node1 \
BARADB_RAFT_PEERS=node2:9001,node3:9001 \
BARADB_SHARD_COUNT=4 \
BARADB_REPLICATION_FACTOR=2 \
./build/baradadb
```
