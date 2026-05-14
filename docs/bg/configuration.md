# Конфигурационна Референция

BaraDB може да се конфигурира чрез **променливи на средата**, **конфигурационен файл** или **командно-редови флагове**.

## Ред на Приоритет

1. Командно-редови флагове (най-висок приоритет)
2. Променливи на средата
3. Конфигурационен файл (`baradb.conf` или `baradb.json`)
4. Вградени стойности по подразбиране (най-нисък приоритет)

## Променливи на Средата

### Мрежа

| Променлива | По подр. | Описание |
|------------|----------|----------|
| `BARADB_ADDRESS` | `127.0.0.1` | Адрес за свързване |
| `BARADB_PORT` | `9472` | TCP бинарен протокол порт |
| `BARADB_HTTP_PORT` | `9470` | HTTP/REST API порт |
| `BARADB_WS_PORT` | `9471` | WebSocket порт |

### Съхранение

| Променлива | По подр. | Описание |
|------------|----------|----------|
| `BARADB_DATA_DIR` | `./data` | Път до директория за данни |
| `BARADB_MEMTABLE_SIZE_MB` | `64` | Размер на MemTable в MB |
| `BARADB_CACHE_SIZE_MB` | `256` | Размер на page cache в MB |
| `BARADB_WAL_SYNC_INTERVAL_MS` | `0` | Интервал за WAL fsync (0 = всеки запис) |
| `BARADB_COMPACTION_INTERVAL_MS` | `60000` | Интервал за фонов compaction |
| `BARADB_BLOOM_BITS_PER_KEY` | `10` | Bloom филтър битове за ключ |

### TLS/SSL

| Променлива | По подр. | Описание |
|------------|----------|----------|
| `BARADB_TLS_ENABLED` | `false` | Включване на TLS |
| `BARADB_CERT_FILE` | — | Път до TLS сертификат |
| `BARADB_KEY_FILE` | — | Път до TLS частен ключ |

### Сигурност

| Променлива | По подр. | Описание |
|------------|----------|----------|
| `BARADB_AUTH_ENABLED` | `false` | Включване на автентикация |
| `BARADB_JWT_SECRET` | — | JWT подписващ secret |
| `BARADB_RATE_LIMIT_GLOBAL` | `10000` | Глобални заявки в секунда |
| `BARADB_RATE_LIMIT_PER_CLIENT` | `1000` | Заявки в секунда за клиент |

### Логване

| Променлива | По подр. | Описание |
|------------|----------|----------|
| `BARADB_LOG_LEVEL` | `info` | Ниво на логване: debug, info, warn, error |
| `BARADB_LOG_FILE` | — | Път до лог файл (stdout ако е празен) |
| `BARADB_LOG_FORMAT` | `json` | Формат на лога: json, text |

### Vector Engine

| Променлива | По подр. | Описание |
|------------|----------|----------|
| `BARADB_VECTOR_M` | `16` | HNSW `M` параметър |
| `BARADB_VECTOR_EF_CONSTRUCTION` | `200` | HNSW `efConstruction` |
| `BARADB_VECTOR_EF_SEARCH` | `64` | HNSW `efSearch` |

### Graph Engine

| Променлива | По подр. | Описание |
|------------|----------|----------|
| `BARADB_GRAPH_PAGE_RANK_ITERATIONS` | `20` | Брой итерации на PageRank |
| `BARADB_GRAPH_PAGE_RANK_DAMPING` | `0.85` | PageRank damping фактор |
| `BARADB_GRAPH_LOUVAIN_RESOLUTION` | `1.0` | Louvain резолюционен параметър |

### Разпределени

| Променлива | По подр. | Описание |
|------------|----------|----------|
| `BARADB_RAFT_NODE_ID` | — | Уникално ID на възел в клъстер |
| `BARADB_RAFT_PEERS` | — | Списък с адреси на peer-ове, разделени със запетая |
| `BARADB_RAFT_PORT` | `9001` | Raft вътрешен комуникационен порт |
| `BARADB_SHARD_COUNT` | `1` | Брой шардове |
| `BARADB_REPLICATION_FACTOR` | `1` | Фактор на репликация |
| `BARADB_SEED_NODES` | — | Gossip seed възли (host:port, разделени със запетая) |

## Конфигурационен Файл

### baradb.conf (INI-подобен)

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

## Командно-редови Флагове

```bash
./build/baradadb --help
```

```
BaraDB v1.1.0 — Multimodal Database Engine

Употреба:
  baradadb [опции]

Опции:
  -c, --config <файл>        Път до конфигурационен файл
  -p, --port <порт>          TCP бинарен порт (по подр.: 9472)
  --http-port <порт>         HTTP порт (по подр.: 9470)
  --ws-port <порт>           WebSocket порт (по подр.: 9471)
  -d, --data-dir <дир>       Директория за данни (по подр.: ./data)
  --tls-cert <файл>          TLS сертификатен файл
  --tls-key <файл>           TLS файл с частен ключ
  --log-level <ниво>         Ниво на логване: debug, info, warn, error
  --log-file <файл>          Път до лог файл
  --shell                    Стартиране на интерактивна обвивка
  --version                  Показване на версия
  --recover                  Изпълнение на WAL възстановяване
  --checkpoint <файл>        Checkpoint за възстановяване
  -h, --help                 Показване на тази помощ
```

## Примерни Конфигурации

### Разработка

```bash
./build/baradadb \
  --log-level debug \
  --data-dir ./dev_data
```

### Продукционен Единичен Възел

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

### Продукционен Клъстер (3 възела)

```bash
# Възел 1
BARADB_ADDRESS=0.0.0.0 \
BARADB_PORT=9472 \
BARADB_RAFT_NODE_ID=node1 \
BARADB_RAFT_PEERS=node2:9001,node3:9001 \
BARADB_SHARD_COUNT=4 \
BARADB_REPLICATION_FACTOR=2 \
./build/baradadb
```
