# Backup & Recovery

## Online Snapshots

BaraDB supports online snapshots without stopping the server. The snapshot
captures a consistent point-in-time view using MVCC.

### Creating a Snapshot

```nim
import barabadb/core/backup

var bm = newBackupManager()
bm.createSnapshot("/backup/baradb_2025-01-15")
```

### Via CLI

```bash
./build/baradadb --snapshot --output=/backup/snapshot.db
```

### Via HTTP API

```bash
curl -X POST http://localhost:9470/api/backup \
  -H "Content-Type: application/json" \
  -d '{"destination": "/backup/snapshot.db"}'
```

### Automated Backups

Use cron for scheduled backups:

```bash
# Daily snapshot at 2 AM
0 2 * * * /usr/local/bin/baradadb --snapshot --output=/backup/baradb_$(date +\%Y\%m\%d).db

# Keep last 7 days
find /backup -name "baradb_*.db" -mtime +7 -delete
```

## Point-in-Time Recovery (PITR)

BaraDB uses the Write-Ahead Log (WAL) for point-in-time recovery.

### WAL Archiving

Enable continuous WAL archiving:

```bash
BARADB_WAL_ARCHIVE_DIR=/backup/wal \
BARADB_WAL_ARCHIVE_INTERVAL_MS=60000 \
./build/baradadb
```

### Recovery from Checkpoint + WAL

```bash
# Restore from snapshot
./build/baradadb --recover \
  --checkpoint=/backup/snapshot.db \
  --wal-dir=/backup/wal

# Recovery to specific LSN
./build/baradadb --recover \
  --checkpoint=/backup/snapshot.db \
  --wal-dir=/backup/wal \
  --target-lsn=15420

# Recovery to specific time
./build/baradadb --recover \
  --checkpoint=/backup/snapshot.db \
  --wal-dir=/backup/wal \
  --target-time="2025-01-15T10:30:00Z"
```

### Incremental Backups

Incremental backups only copy changed SSTables:

```bash
./build/baradadb --backup-incremental \
  --last-backup=/backup/previous \
  --output=/backup/incremental_$(date +%Y%m%d)
```

## Replication as Backup

For continuous protection, use streaming replication:

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

### Recovery Procedures

#### Scenario 1: Single File Corruption

```bash
# Identify corrupted SSTable from logs
# Restore specific SSTable from backup
cp /backup/sstables/000012.sst ./data/sstables/

# Rebuild index
./build/baradadb --rebuild-index
```

#### Scenario 2: Complete Data Loss

```bash
# 1. Restore latest snapshot
cp /backup/snapshot.db ./data/

# 2. Replay WAL
./build/baradadb --recover --wal-dir=/backup/wal

# 3. Verify
curl http://localhost:9470/health
```

#### Scenario 3: Cluster Node Failure

```bash
# For Raft clusters, simply start a new node
BARADB_RAFT_NODE_ID=newnode \
BARADB_RAFT_PEERS=node1:9001,node2:9001 \
./build/baradadb

# The new node will catch up via Raft log replication
```

## Backup Verification

Always verify backups:

```bash
# Restore to temporary directory
./build/baradadb --recover \
  --checkpoint=/backup/snapshot.db \
  --data-dir=/tmp/verify_data

# Run consistency check
curl http://localhost:9470/api/admin/check
```

## Storage Requirements

| Backup Type | Size | Frequency | Retention |
|-------------|------|-----------|-----------|
| Full snapshot | ~1× data size | Daily | 7 days |
| Incremental | ~0.1× data size | Hourly | 24 hours |
| WAL archive | ~0.05× data size / day | Continuous | 30 days |

## Best Practices

1. **Test restores regularly** — A backup you can't restore is useless
2. **Store backups offsite** — Use S3, GCS, or Azure Blob
3. **Encrypt backups** — Use `gpg` or OS-level encryption
4. **Monitor backup jobs** — Alert on failed backups
5. **Document RTO/RPO** — Know your recovery time and point objectives

### Cloud Backup Upload

```bash
# Upload to S3
aws s3 cp /backup/snapshot.db s3://my-bucket/baradb/

# Upload to GCS
gsutil cp /backup/snapshot.db gs://my-bucket/baradb/

# Upload to Azure
az storage blob upload \
  --container-name backups \
  --file /backup/snapshot.db \
  --name baradb/snapshot.db
```
