# Резервное копирование и восстановление

## Онлайн снэпшоты

BaraDB поддерживает онлайн снэпшоты без остановки сервера. Снэпшот захватывает согласованное представление на момент времени с помощью MVCC.

### Создание снэпшота

```nim
import barabadb/core/backup

var bm = newBackupManager()
bm.createSnapshot("/backup/baradb_2025-01-15")
```

### Через CLI

```bash
./build/baradadb --snapshot --output=/backup/snapshot.db
```

### Через HTTP API

```bash
curl -X POST http://localhost:9470/api/backup \
  -H "Content-Type: application/json" \
  -d '{"destination": "/backup/snapshot.db"}'
```

### Автоматические бэкапы

```bash
# Ежедневный снэпшот в 2 ночи
0 2 * * * /usr/local/bin/baradadb --snapshot --output=/backup/baradb_$(date +\%Y\%m\%d).db

# Хранить последние 7 дней
find /backup -name "baradb_*.db" -mtime +7 -delete
```

## Восстановление на момент времени (PITR)

BaraDB использует WAL для восстановления на момент времени.

### Архивирование WAL

```bash
BARADB_WAL_ARCHIVE_DIR=/backup/wal \
BARADB_WAL_ARCHIVE_INTERVAL_MS=60000 \
./build/baradadb
```

### Восстановление из снэпшота + WAL

```bash
# Восстановление из снэпшота
./build/baradadb --recover \
  --checkpoint=/backup/snapshot.db \
  --wal-dir=/backup/wal

# Восстановление до конкретного LSN
./build/baradadb --recover \
  --checkpoint=/backup/snapshot.db \
  --wal-dir=/backup/wal \
  --target-lsn=15420

# Восстановление до конкретного времени
./build/baradadb --recover \
  --checkpoint=/backup/snapshot.db \
  --wal-dir=/backup/wal \
  --target-time="2025-01-15T10:30:00Z"
```

### Восстановление через SQL

```sql
RECOVER TO TIMESTAMP '2026-05-07T12:00:00';
```

## Сценарии аварийного восстановления

### Сценарий 1: Повреждение файла

```bash
cp /backup/sstables/000012.sst ./data/sstables/
./build/baradadb --rebuild-index
```

### Сценарий 2: Полная потеря данных

```bash
cp /backup/snapshot.db ./data/
./build/baradadb --recover --wal-dir=/backup/wal
curl http://localhost:9470/health
```

### Сценарий 3: Отказ узла кластера

```bash
BARADB_RAFT_NODE_ID=newnode \
BARADB_RAFT_PEERS=node1:9001,node2:9001 \
./build/baradadb
```

## Проверка бэкапов

```bash
./build/baradadb --recover \
  --checkpoint=/backup/snapshot.db \
  --data-dir=/tmp/verify_data

curl http://localhost:9470/api/admin/check
```

## Рекомендации

1. **Регулярно тестируйте восстановление**
2. **Храните бэкапы вне сайта** (S3, GCS, Azure Blob)
3. **Шифруйте бэкапы**
4. **Мониторьте задачи бэкапа**
5. **Документируйте RTO/RPO**