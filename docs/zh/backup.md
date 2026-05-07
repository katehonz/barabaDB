# 备份与恢复

## 在线快照

BaraDB 支持在线快照，无需停止服务器。快照使用 MVCC 捕获一致的时间点视图。

### 创建快照

```nim
import barabadb/core/backup

var bm = newBackupManager()
bm.createSnapshot("/backup/baradb_2025-01-15")
```

### 通过 CLI

```bash
./build/baradadb --snapshot --output=/backup/snapshot.db
```

### 通过 HTTP API

```bash
curl -X POST http://localhost:9470/api/backup \
  -d '{"destination": "/backup/snapshot.db"}'
```

### 自动备份

```bash
0 2 * * * /usr/local/bin/baradadb --snapshot --output=/backup/baradb_$(date +\%Y\%m\%d).db
find /backup -name "baradb_*.db" -mtime +7 -delete
```

## 时间点恢复 (PITR)

### 从快照 + WAL 恢复

```bash
./build/baradadb --recover \
  --checkpoint=/backup/snapshot.db \
  --wal-dir=/backup/wal
```

### 通过 SQL 恢复

```sql
RECOVER TO TIMESTAMP '2026-05-07T12:00:00';
```

## 灾难恢复场景

### 场景 1：文件损坏

```bash
cp /backup/sstables/000012.sst ./data/sstables/
./build/baradadb --rebuild-index
```

### 场景 2：完全数据丢失

```bash
cp /backup/snapshot.db ./data/
./build/baradadb --recover --wal-dir=/backup/wal
```

### 场景 3：集群节点故障

```bash
BARADB_RAFT_NODE_ID=newnode \
BARADB_RAFT_PEERS=node1:9001,node2:9001 \
./build/baradadb
```

## 最佳实践

1. 定期测试恢复
2. 将备份存储在场外
3. 加密备份
4. 监控备份作业
5. 记录 RTO/RPO