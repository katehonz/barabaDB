# Yedekleme ve Kurtarma

## Çevrimiçi Anlık Görüntüler

BaraDB sunucuyu durdurmadan çevrimiçi anlık görüntüleri destekler.

### Anlık Görüntü Oluşturma

```nim
import barabadb/core/backup

var bm = newBackupManager()
bm.createSnapshot("/backup/baradb_2025-01-15")
```

### CLI ile

```bash
./build/baradadb --snapshot --output=/backup/snapshot.db
```

### HTTP API ile

```bash
curl -X POST http://localhost:9470/api/backup \
  -d '{"destination": "/backup/snapshot.db"}'
```

### Otomatik Yedeklemeler

```bash
0 2 * * * /usr/local/bin/baradadb --snapshot --output=/backup/baradb_$(date +\%Y\%m\%d).db
find /backup -name "baradb_*.db" -mtime +7 -delete
```

## Zaman Noktası Kurtarma (PITR)

### snapshot + WAL'dan Kurtarma

```bash
./build/baradadb --recover \
  --checkpoint=/backup/snapshot.db \
  --wal-dir=/backup/wal
```

### SQL ile Kurtarma

```sql
RECOVER TO TIMESTAMP '2026-05-07T12:00:00';
```

## Felaket Kurtarma Senaryoları

### Senaryo 1: Dosya Bozulması

```bash
cp /backup/sstables/000012.sst ./data/sstables/
./build/baradadb --rebuild-index
```

### Senaryo 2: Tam Veri Kaybı

```bash
cp /backup/snapshot.db ./data/
./build/baradadb --recover --wal-dir=/backup/wal
```

### Senaryo 3: Küme Düğümü Arızası

```bash
BARADB_RAFT_NODE_ID=newnode \
BARADB_RAFT_PEERS=node1:9001,node2:9001 \
./build/baradadb
```

## En İyi Uygulamalar

1. Kurtarmayı düzenli olarak test edin
2. Yedeklemeleri uzakta saklayın (S3, GCS, Azure Blob)
3. Yedeklemeleri şifreleyin
4. Yedekleme işlerini izleyin
5. RTO/RPO'nuzu belgelendirin