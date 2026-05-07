# پشتیبان‌گیری و بازیابی

## Snapshot آنلاین

BaraDB از snapshot آنلاین بدون توقف سرور پشتیبانی می‌کند.

### ایجاد snapshot

```nim
import barabadb/core/backup

var bm = newBackupManager()
bm.createSnapshot("/backup/baradb_2025-01-15")
```

### از طریق CLI

```bash
./build/baradadb --snapshot --output=/backup/snapshot.db
```

### از طریق HTTP API

```bash
curl -X POST http://localhost:9470/api/backup \
  -d '{"destination": "/backup/snapshot.db"}'
```

### پشتیبان‌گیری خودکار

```bash
0 2 * * * /usr/local/bin/baradadb --snapshot --output=/backup/baradb_$(date +\%Y\%m\%d).db
find /backup -name "baradb_*.db" -mtime +7 -delete
```

## بازیابی نقطه‌درزمان (PITR)

### بازیابی از snapshot + WAL

```bash
./build/baradadb --recover \
  --checkpoint=/backup/snapshot.db \
  --wal-dir=/backup/wal
```

### بازیابی از طریق SQL

```sql
RECOVER TO TIMESTAMP '2026-05-07T12:00:00';
```

## سناریوهای بازیابی

### سناریو 1: خرابی فایل

```bash
cp /backup/sstables/000012.sst ./data/sstables/
./build/baradadb --rebuild-index
```

### سناریو 2: از دست دادن کامل داده

```bash
cp /backup/snapshot.db ./data/
./build/baradadb --recover --wal-dir=/backup/wal
```

### سناریو 3: خرابی گره کلاستر

```bash
BARADB_RAFT_NODE_ID=newnode \
BARADB_RAFT_PEERS=node1:9001,node2:9001 \
./build/baradadb
```

## بهترین شیوه‌ها

1. بازیابی را مرتب تست کنید
2. پشتیبان‌ها را خارج از سایت ذخیره کنید
3. پشتیبان‌ها را رمزنگاری کنید
4. کارهای پشتیبان‌گیری را مانیتور کنید