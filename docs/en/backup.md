# Backup & Recovery

BaraDB provides multiple backup strategies ranging from full snapshots to incremental, online consistent backups, and multi-database archiving.

## Architecture

```
┌─────────────────────────────────────────┐
│  Data Root                              │
│  └── databases/                         │
│      ├── default/                       │
│      │   ├── MANIFEST                   │
│      │   ├── sstables/                  │
│      │   └── wal/                       │
│      ├── mydb/                          │
│      │   ├── MANIFEST                   │
│      │   ├── sstables/                  │
│      │   └── wal/                       │
│      └── ...                            │
└─────────────────────────────────────────┘
```

## Backup Tool

```bash
nim c -o:build/backup src/barabadb/core/backup.nim
```

## Multi-Database Backup (Recommended)

### Backup all databases

```bash
./build/backup backup --all-databases --data-root=./data/databases --output=all_$(date +%s).tar.gz
```

The archive contains:
- `backup.json` — metadata (version, timestamp, database list)
- `databases/<name>/` — each database with its MANIFEST, SSTables, and WAL

### Backup a single database

```bash
./build/backup backup --database=default --data-root=./data/databases --output=default_$(date +%s).tar.gz
```

### Restore all databases

```bash
./build/backup restore --input=all_1234567890.tar.gz --all-databases --data-root=./data/databases
```

### Restore a single database

```bash
./build/backup restore --input=default_1234567890.tar.gz --database=default --data-root=./data/databases
```

## Legacy Single-Directory Backup

For backward compatibility with older installations (single database in `data/server`):

```bash
./build/backup backup --data-dir=./data/server --output=legacy_$(date +%s).tar.gz
./build/backup restore --input=legacy_1234567890.tar.gz --data-dir=./data/server
```

## Incremental Backup

```bash
./build/backup incremental --database=default --data-root=./data/databases --output=inc_$(date +%s).tar.gz
```

Includes only:
- `MANIFEST`
- Active SSTables (from MANIFEST)
- Current WAL (`wal/wal.log`)
- WAL archive (`wal/wal_archive/*.log`)

All SSTables are **CRC-verified** before archiving.

## Online Consistent Backup

```bash
./build/backup backup --online --database=default --data-root=./data/databases --output=online_$(date +%s).tar.gz
```

Equivalent to:
1. `checkpoint` (freeze memtable, flush, rotate WAL)
2. `incremental backup`

Safe to run while the server is running.

## HTTP API Backup

Backup/restore is also available via REST API (requires admin JWT token):

```bash
# Backup all databases
curl -X POST http://localhost:9912/backup \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"all": true}'

# Backup single database
curl -X POST http://localhost:9912/backup \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"database": "default"}'

# List backups
curl http://localhost:9912/backups \
  -H "Authorization: Bearer <token>"

# Restore
curl -X POST http://localhost:9912/restore \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"input": "backup_1234567890.tar.gz", "all": true}'
```

## SSTable Integrity (v3 CRC Footer)

```
[Header] 36 bytes
  magic, version(3), entryCount, level,
  indexOffset, bloomOffset, footerOffset
[Data Block]
[Index Block]
[Bloom Block]
[Footer] 16 bytes
  dataCrc32, indexCrc32, bloomCrc32, reserved
```

## Storage Repair (`baradadb repair`)

```bash
# Dry run — preview only
./build/baradadb repair --data-dir=./data/databases/default --dry-run

# Full repair
./build/baradadb repair --data-dir=./data/databases/default
```

## MANIFEST Catalog

```json
{
  "version": 1,
  "sequence": 42,
  "createdAt": 1779103266,
  "sstables": [
    {"id": 1, "path": "sstables/1.sst", "level": 0, "minKey": "a", "maxKey": "z", "entryCount": 100}
  ]
}
```

## Checkpoint

```bash
./build/baradadb checkpoint --data-dir=./data/databases/default
```

**How it works:**
1. Freeze memtable (< 1ms)
2. Flush to SSTable
3. Rotate WAL
4. Write MANIFEST

## SSTable Version Migration

```bash
./build/baradadb migrate --data-dir=./data/databases/default --dry-run
./build/baradadb migrate --data-dir=./data/databases/default
```

## Recovery Procedures

### Scenario 1: Corrupt SSTable

```bash
./build/baradadb repair --data-dir=./data/databases/default
```

### Scenario 2: Restore from Multi-Database Backup

```bash
# 1. Extract
./build/backup restore --input=backup_latest.tar.gz --all-databases --data-root=./data/databases

# 2. Repair each database
for db in ./data/databases/*/; do
  ./build/baradadb repair --data-dir="$db" --dry-run
done

# 3. Start server
./build/baradadb
```

### Scenario 3: Manual extraction

```bash
tar -xzf backup_latest.tar.gz -C ./data
# Archive contains: databases/<name>/ + backup.json
```

## Storage Requirements

| Backup Type | Size | Frequency | Retention |
|-------------|------|-----------|-----------|
| Full tar.gz | ~1× data size | Weekly | 4 weeks |
| Incremental | ~0.05× data size | Hourly | 24 hours |
| WAL archive | ~0.02× data size / day | Continuous | 7 days |

## Best Practices

1. **Use `--all-databases`** for full backups in multi-DB setups
2. **Test restores regularly** — A backup you can't restore is useless
3. **Run repair after unclean shutdown**
4. **Store backups offsite** — S3, GCS, or another server
5. **Use incremental + checkpoint** — For frequent consistent snapshots
6. **Monitor `/backups` endpoint** — Via admin panel or API
