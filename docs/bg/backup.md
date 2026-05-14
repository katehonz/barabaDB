# Backup и Възстановяване

## Online Snapshots

BaraDB поддържа online snapshots без спиране на сървъра. Snapshot-ът заснема консистентен изглед към момент във времето чрез MVCC.

### Създаване на Snapshot

```nim
import barabadb/core/backup

var bm = newBackupManager()
bm.createSnapshot("/backup/baradb_2025-01-15")
```

### Чрез CLI

```bash
./build/baradadb --snapshot --output=/backup/snapshot.db
```

### Чрез HTTP API

```bash
curl -X POST http://localhost:9470/api/backup \
  -H "Content-Type: application/json" \
  -d '{"destination": "/backup/snapshot.db"}'
```

### Автоматизирани Backups

Използвайте cron за планирани backups:

```bash
# Ежедневен snapshot в 2 сутринта
0 2 * * * /usr/local/bin/baradadb --snapshot --output=/backup/baradb_$(date +\%Y\%m\%d).db

# Запазване на последните 7 дни
find /backup -name "baradb_*.db" -mtime +7 -delete
```

## Point-in-Time Recovery (PITR)

BaraDB използва Write-Ahead Log (WAL) за възстановяване до момент във времето.

### WAL Архивиране

Включете непрекъснато WAL архивиране:

```bash
BARADB_WAL_ARCHIVE_DIR=/backup/wal \
BARADB_WAL_ARCHIVE_INTERVAL_MS=60000 \
./build/baradadb
```

### Възстановяване от Checkpoint + WAL

```bash
# Възстановяване от snapshot
./build/baradadb --recover \
  --checkpoint=/backup/snapshot.db \
  --wal-dir=/backup/wal

# Възстановяване до конкретен LSN
./build/baradadb --recover \
  --checkpoint=/backup/snapshot.db \
  --wal-dir=/backup/wal \
  --target-lsn=15420

# Възстановяване до конкретно време
./build/baradadb --recover \
  --checkpoint=/backup/snapshot.db \
  --wal-dir=/backup/wal \
  --target-time="2025-01-15T10:30:00Z"
```

### Възстановяване чрез SQL

Можете също да възстановявате директно чрез BaraQL:

```sql
RECOVER TO TIMESTAMP '2026-05-07T12:00:00';
```

### Инкрементални Backups

Инкременталните backups копират само променени SSTables:

```bash
./build/baradadb --backup-incremental \
  --last-backup=/backup/previous \
  --output=/backup/incremental_$(date +%Y%m%d)
```

## Репликация като Backup

За непрекъсната защита използвайте streaming репликация:

### Primary

```bash
BARADB_REPLICATION_ENABLED=true \
BARADB_REPLICATION_MODE=async \
./build/baradadb
```

### Replica

```bash
BARADB_REPLICATION_ENABLED=true \
BARADB_REPLICATION_PRIMARY=primary:9472 \
./build/baradadb
```

## Disaster Recovery

### Процедури за Възстановяване

#### Сценарий 1: Повреда на Единичен Файл

```bash
# Идентифициране на повреден SSTable от логовете
# Възстановяване на конкретен SSTable от backup
cp /backup/sstables/000012.sst ./data/sstables/

# Възстановяване на индекса
./build/baradadb --rebuild-index
```

#### Сценарий 2: Пълна Загуба на Данни

```bash
# 1. Възстановяване на последния snapshot
cp /backup/snapshot.db ./data/

# 2. Преиграване на WAL
./build/baradadb --recover --wal-dir=/backup/wal

# 3. Проверка
curl http://localhost:9470/health
```

#### Сценарий 3: Отказ на Възел в Клъстер

```bash
# За Raft клъстери, просто стартирайте нов възел
BARADB_RAFT_NODE_ID=newnode \
BARADB_RAFT_PEERS=node1:9001,node2:9001 \
./build/baradadb

# Новият възел ще навакса чрез Raft log репликация
```

## Верификация на Backup

Винаги проверявайте backups:

```bash
# Възстановяване във временна директория
./build/baradadb --recover \
  --checkpoint=/backup/snapshot.db \
  --data-dir=/tmp/verify_data

# Проверка на консистентност
curl http://localhost:9470/api/admin/check
```

## Изисквания за Съхранение

| Тип Backup | Размер | Честота | Задържане |
|------------|--------|---------|-----------|
| Пълен snapshot | ~1× размер на данните | Ежедневно | 7 дни |
| Инкрементален | ~0.1× размер на данните | На всеки час | 24 часа |
| WAL архив | ~0.05× размер на данните / ден | Непрекъснато | 30 дни |

## Най-добри Практики

1. **Тествайте възстановяването редовно** — Backup, който не може да бъде възстановен, е безполезен
2. **Съхранявайте backups извън локацията** — Използвайте S3, GCS или Azure Blob
3. **Криптирайте backups** — Използвайте `gpg` или криптиране на ниво ОС
4. **Мониторирайте backup задачите** — Алармирайте при неуспешни backups
5. **Документирайте RTO/RPO** — Знайте целите си за време и точка на възстановяване

### Качване на Backup в Облак

```bash
# Качване в S3
aws s3 cp /backup/snapshot.db s3://my-bucket/baradb/

# Качване в GCS
gsutil cp /backup/snapshot.db gs://my-bucket/baradb/

# Качване в Azure
az storage blob upload \
  --container-name backups \
  --file /backup/snapshot.db \
  --name baradb/snapshot.db
```
