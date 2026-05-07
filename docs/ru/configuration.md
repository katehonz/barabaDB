# Справочник по конфигурации BaraDB

BaraDB можно настроить через **переменные окружения**, **конфигурационный файл** или **флаги командной строки**.

## Приоритет

1. Флаги командной строки (наивысший приоритет)
2. Переменные окружения
3. Конфигурационный файл (`baradb.conf` или `baradb.json`)
4. Встроенные значения по умолчанию (низший приоритет)

## Переменные окружения

### Сеть

| Переменная | По умолчанию | Описание |
|------------|--------------|----------|
| `BARADB_ADDRESS` | `127.0.0.1` | Адрес привязки |
| `BARADB_PORT` | `9472` | Порт бинарного протокола TCP |
| `BARADB_HTTP_PORT` | `9470` | Порт HTTP/REST API |
| `BARADB_WS_PORT` | `9471` | Порт WebSocket |

### Хранилище

| Переменная | По умолчанию | Описание |
|------------|--------------|----------|
| `BARADB_DATA_DIR` | `./data` | Путь к директории данных |
| `BARADB_MEMTABLE_SIZE_MB` | `64` | Размер MemTable в МБ |
| `BARADB_CACHE_SIZE_MB` | `256` | Размер page cache в МБ |
| `BARADB_WAL_SYNC_INTERVAL_MS` | `0` | Интервал fsync для WAL (0 = при каждой записи) |
| `BARADB_COMPACTION_INTERVAL_MS` | `60000` | Интервал фоновой компактификации |
| `BARADB_BLOOM_BITS_PER_KEY` | `10` | Биты Bloom фильтра на ключ |

### TLS/SSL

| Переменная | По умолчанию | Описание |
|------------|--------------|----------|
| `BARADB_TLS_ENABLED` | `false` | Включить TLS |
| `BARADB_CERT_FILE` | — | Путь к TLS сертификату |
| `BARADB_KEY_FILE` | — | Путь к TLS закрытому ключу |

### Безопасность

| Переменная | По умолчанию | Описание |
|------------|--------------|----------|
| `BARADB_AUTH_ENABLED` | `false` | Включить аутентификацию |
| `BARADB_JWT_SECRET` | — | Секрет для подписи JWT |
| `BARADB_RATE_LIMIT_GLOBAL` | `10000` | Глобальный лимит запросов/сек |
| `BARADB_RATE_LIMIT_PER_CLIENT` | `1000` | Лимит запросов/сек на клиента |

### Логирование

| Переменная | По умолчанию | Описание |
|------------|--------------|----------|
| `BARADB_LOG_LEVEL` | `info` | Уровень логирования: debug, info, warn, error |
| `BARADB_LOG_FILE` | — | Путь к файлу логов (stdout если пусто) |
| `BARADB_LOG_FORMAT` | `json` | Формат логов: json, text |

### Векторный движок

| Переменная | По умолчанию | Описание |
|------------|--------------|----------|
| `BARADB_VECTOR_M` | `16` | HNSW параметр `M` |
| `BARADB_VECTOR_EF_CONSTRUCTION` | `200` | HNSW `efConstruction` |
| `BARADB_VECTOR_EF_SEARCH` | `64` | HNSW `efSearch` |

### Графовый движок

| Переменная | По умолчанию | Описание |
|------------|--------------|----------|
| `BARADB_GRAPH_PAGE_RANK_ITERATIONS` | `20` | Количество итераций PageRank |
| `BARADB_GRAPH_PAGE_RANK_DAMPING` | `0.85` | Коэффициент затухания PageRank |
| `BARADB_GRAPH_LOUVAIN_RESOLUTION` | `1.0` | Параметр разрешения Louvain |

### Распределённость

| Переменная | По умолчанию | Описание |
|------------|--------------|----------|
| `BARADB_RAFT_NODE_ID` | — | Уникальный ID узла в кластере |
| `BARADB_RAFT_PEERS` | — | Список пиров через запятую |
| `BARADB_RAFT_PORT` | `9001` | Порт внутренней связи Raft |
| `BARADB_SHARD_COUNT` | `1` | Количество шардов |
| `BARADB_REPLICATION_FACTOR` | `1` | Фактор репликации |

## Конфигурационный файл

### baradb.conf (INI-подобный)

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

## Флаги командной строки

```bash
./build/baradadb --help
```

```
BaraDB v0.1.0 — Multimodal Database Engine

Usage:
  baradadb [options]

Options:
  -c, --config <file>       Путь к конфигурационному файлу
  -p, --port <port>         TCP бинарный порт (по умолчанию: 9472)
  --http-port <port>        HTTP порт (по умолчанию: 9470)
  --ws-port <port>         WebSocket порт (по умолчанию: 9471)
  -d, --data-dir <dir>      Директория данных (по умолчанию: ./data)
  --tls-cert <file>         TLS сертификат
  --tls-key <file>          TLS закрытый ключ
  --log-level <level>       Уровень логирования: debug, info, warn, error
  --log-file <file>         Путь к файлу логов
  --shell                   Запустить интерактивную оболочку
  --version                 Показать версию
  --recover                 Запустить восстановление WAL
  --checkpoint <file>       Чекпоинт для восстановления
  -h, --help                Показать эту справку
```

## Примеры конфигураций

### Разработка

```bash
./build/baradadb \
  --log-level debug \
  --data-dir ./dev_data
```

### Продакшен (один узел)

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

### Продакшен кластер (3 узла)

```bash
# Узел 1
BARADB_ADDRESS=0.0.0.0 \
BARADB_PORT=9472 \
BARADB_RAFT_NODE_ID=node1 \
BARADB_RAFT_PEERS=node2:9001,node3:9001 \
BARADB_SHARD_COUNT=4 \
BARADB_REPLICATION_FACTOR=2 \
./build/baradadb
```