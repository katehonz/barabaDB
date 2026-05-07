# النسخ الاحتياطي والاستعادة

## لقطات عبر الإنترنت

تدعم BaraDB اللقطات عبر الإنترنت دون إيقاف الخادم.

### إنشاء لقطة

```nim
import barabadb/core/backup

var bm = newBackupManager()
bm.createSnapshot("/backup/baradb_2025-01-15")
```

### عبر CLI

```bash
./build/baradadb --snapshot --output=/backup/snapshot.db
```

### عبر HTTP API

```bash
curl -X POST http://localhost:9470/api/backup \
  -d '{"destination": "/backup/snapshot.db"}'
```

### النسخ الاحتياطي التلقائي

```bash
0 2 * * * /usr/local/bin/baradadb --snapshot --output=/backup/baradb_$(date +\%Y\%m\%d).db
find /backup -name "baradb_*.db" -mtime +7 -delete
```

## استعادة نقطة في الوقت (PITR)

### الاستعادة من اللقطة + WAL

```bash
./build/baradadb --recover \
  --checkpoint=/backup/snapshot.db \
  --wal-dir=/backup/wal
```

### الاستعادة عبر SQL

```sql
RECOVER TO TIMESTAMP '2026-05-07T12:00:00';
```

## سيناريوهات استعادة الكوارث

### السيناريو 1: تلف الملف

```bash
cp /backup/sstables/000012.sst ./data/sstables/
./build/baradadb --rebuild-index
```

### السيناريو 2: فقدان البيانات الكامل

```bash
cp /backup/snapshot.db ./data/
./build/baradadb --recover --wal-dir=/backup/wal
```

### السيناريو 3: فشل عقدة الكتلة

```bash
BARADB_RAFT_NODE_ID=newnode \
BARADB_RAFT_PEERS=node1:9001,node2:9001 \
./build/baradadb
```

## أفضل الممارسات

1. اختبار الاستعادة بانتظام
2. تخزين النسخ الاحتياطية خارج الموقع
3. تشفير النسخ الاحتياطية
4. مراقبة مهام النسخ الاحتياطي
5. توثيق RTO/RPO