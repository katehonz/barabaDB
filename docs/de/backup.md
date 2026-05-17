# Backup & Wiederherstellung

## Online Snapshots

BaraDB unterstützt Online-Snapshots ohne Server-Stopp. Der Snapshot erfasst eine
konsistente Point-in-Time-Ansicht mittels MVCC.

### Snapshot erstellen

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

### Automatisierte Backups

Cron für geplante Backups verwenden:

```bash
# Daily snapshot at 2 AM
0 2 * * * /usr/local/bin/baradadb --snapshot --output=/backup/baradb_$(date +\%Y\%m\%d).db

# Letzte 7 Tage behalten
find /backup -name "baradb_*.db" -mtime +7 -delete
```

## Point-in-Time Recovery (PITR)

BaraDB verwendet das Write-Ahead Log (WAL) für Point-in-Time Recovery.

### WAL-Archivierung

Kontinuierliche WAL-Archivierung aktivieren:

```bash
BARADB_WAL_ARCHIVE_DIR=/backup/wal \
BARADB_WAL_ARCHIVE_INTERVAL_MS=60000 \
./build/baradadb
```

### Wiederherstellung von Checkpoint + WAL

```bash
# Von Snapshot wiederherstellen
./build/baradadb --recover \
  --checkpoint=/backup/snapshot.db \
  --wal-dir=/backup/wal

# Wiederherstellung zu spezifischem LSN
./build/baradadb --recover \
  --checkpoint=/backup/snapshot.db \
  --wal-dir=/backup/wal \
  --target-lsn=15420

# Wiederherstellung zu spezifischer Zeit
./build/baradadb --recover \
  --checkpoint=/backup/snapshot.db \
  --wal-dir=/backup/wal \
  --target-time="2025-01-15T10:30:00Z"
```

### Wiederherstellung via SQL

Sie können auch direkt via BaraQL wiederherstellen:

```sql
RECOVER TO TIMESTAMP '2026-05-07T12:00:00';
```

### Inkrementelle Backups

Inkrementelle Backups kopieren nur geänderte SSTables:

```bash
./build/baradadb --backup-incremental \
  --last-backup=/backup/previous \
  --output=/backup/incremental_$(date +%Y%m%d)
```

## Replikation als Backup

Für kontinuierlichen Schutz, Streaming-Replikation verwenden:

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

### Wiederherstellungsverfahren

#### Szenario 1: Einzelne Dateikorruption

```bash
# Korrupte SSTable aus Logs identifizieren
# Spezifische SSTable aus Backup wiederherstellen
cp /backup/sstables/000012.sst ./data/sstables/

# Index neu aufbauen
./build/baradadb --rebuild-index
```

#### Szenario 2: Kompletter Datenverlust

```bash
# 1. Neuesten Snapshot wiederherstellen
cp /backup/snapshot.db ./data/

# 2. WAL replay
./build/baradadb --recover --wal-dir=/backup/wal

# 3. Verifizieren
curl http://localhost:9470/health
```

#### Szenario 3: Cluster-Knoten-Ausfall

```bash
# Für Raft-Cluster, einfach neuen Knoten starten
BARADB_RAFT_NODE_ID=newnode \
BARADB_RAFT_PEERS=node1:9001,node2:9001 \
./build/baradadb

# Der neue Knoten wird über Raft-Log-Replikation aufholen
```

## Backup-Verifizierung

Backups immer verifizieren:

```bash
# In temporäres Verzeichnis wiederherstellen
./build/baradadb --recover \
  --checkpoint=/backup/snapshot.db \
  --data-dir=/tmp/verify_data

# Konsistenzprüfung ausführen
curl http://localhost:9470/api/admin/check
```

## Speicheranforderungen

| Backup-Typ | Größe | Häufigkeit | Aufbewahrung |
|-------------|------|-----------|--------------|
| Full snapshot | ~1× Datengröße | Täglich | 7 Tage |
| Inkrementell | ~0.1× Datengröße | Stündlich | 24 Stunden |
| WAL-Archiv | ~0.05× Datengröße / Tag | Kontinuierlich | 30 Tage |

## Best Practices

1. **Restores regelmäßig testen** — Ein Backup das Sie nicht wiederherstellen können ist wertlos
2. **Backups außerhalb speichern** — S3, GCS oder Azure Blob verwenden
3. **Backups verschlüsseln** — `gpg` oder OS-Level-Verschlüsselung verwenden
4. **Backup-Jobs überwachen** — Bei fehlgeschlagenen Backups alarmieren
5. **RTO/RPO dokumentieren** — Ihre Wiederherstellungszeit und Punktziele kennen

### Cloud-Backup-Upload

```bash
# Zu S3 hochladen
aws s3 cp /backup/snapshot.db s3://my-bucket/baradb/

# Zu GCS hochladen
gsutil cp /backup/snapshot.db gs://my-bucket/baradb/

# Zu Azure hochladen
az storage blob upload \
  --container-name backups \
  --file /backup/snapshot.db \
  --name baradb/snapshot.db
```
