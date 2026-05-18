# Backup & Recovery

BaraDB provides multiple backup strategies ranging from full snapshots to incremental and online consistent backups.

## Architecture

```
┌─────────────────────────────────────────┐
│  Data Directory                         │
│  ├── MANIFEST          (atomic catalog) │
│  ├── sstables/         (SSTable v3 CRC) │
│  │   ├── 1.sst                          │
│  │   └── 2.sst                          │
│  └── wal/                               │
│      ├── wal.log       (active segment) │
│      └── wal_archive/  (rotated segments│
└─────────────────────────────────────────┘
```

## SSTable Integrity (v3 CRC Footer)

Every SSTable file written by BaraDB includes a CRC32 footer:

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

This enables independent verification of each SSTable:

```bash
# Via Nim API
import barabadb/storage/lsm
let (ok, msg) = verifySSTable("data/sstables/1.sst")
```

## Storage Repair (`baradb repair`)

If corruption is suspected, run the repair tool:

```bash
# Dry run — preview only
./build/baradadb repair --data-dir=./data --dry-run

# Full repair — verify, move corrupt files, replay WAL
./build/baradadb repair --data-dir=./data
```

**What repair does:**
1. Scans all `sstables/*.sst` and verifies CRC
2. Moves corrupt SSTables to `data/corrupt/`
3. Replays WAL to recover unflushed committed data
4. Reports results

## MANIFEST Catalog

The `MANIFEST` file is the single source of truth for active SSTables. It is updated atomically on every flush and compaction.

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

Benefits:
- **Consistent view** — no orphan SSTables after crash
- **Fast startup** — load from MANIFEST instead of directory scan
- **Orphan detection** — `checkStorageConsistency()` reports extra/missing files

## WAL Rotation

The Write-Ahead Log rotates when it reaches 64MB:

```
wal/wal.log          → active segment
wal/wal_archive/
  ├── wal.000001.log
  ├── wal.000002.log
  └── wal.000003.log
```

Rotation happens:
- Every 1000 WAL entries (lightweight size check)
- On every `flush` / `checkpoint`

## Checkpoint

A checkpoint creates a consistent storage boundary without stopping the server:

```bash
./build/baradadb checkpoint --data-dir=./data
```

**How it works:**
1. Freeze memtable (swap to immutable, new memtable for writes)
2. Flush frozen memtable to SSTable
3. Rotate WAL
4. Write MANIFEST

The freeze takes **< 1ms**; the flush proceeds concurrently with writes.

## Backup Commands

### Full Backup (tar.gz)

```bash
./build/backup backup --data-dir=./data --output=backup_$(date +%s).tar.gz
```

Archives the entire data directory.

### Incremental Backup

```bash
./build/backup incremental --data-dir=./data --output=backup_inc_$(date +%s).tar.gz
```

Includes only:
- `MANIFEST`
- Active SSTables (from MANIFEST)
- Current WAL (`wal/wal.log`)
- WAL archive (`wal/wal_archive/*.log`)

All SSTables are **CRC-verified** before archiving.

### Online Consistent Backup

```bash
./build/baradadb backup --online --output=backup_online_$(date +%s).tar.gz
```

Equivalent to:
1. `checkpoint`
2. `incremental backup`

**Safe to run while the server is stopped.** If the server is running, use `backup incremental` instead.

## SSTable Version Migration

If you have legacy v1/v2 SSTables, migrate them to v3:

```bash
# Preview
./build/baradadb migrate --data-dir=./data --dry-run

# Migrate
./build/baradadb migrate --data-dir=./data
```

Migration rewrites each legacy SSTable with the current v3 format (CRC footer) and updates the MANIFEST.

## Recovery Procedures

### Scenario 1: Corrupt SSTable Detected

```bash
# Repair moves corrupt files and replays WAL
./build/baradadb repair --data-dir=./data

# Verify consistency
./build/baradadb repair --data-dir=./data --dry-run
```

### Scenario 2: Restore from Backup

```bash
# Stop the server
# Extract backup
tar -xzf backup_1234567890.tar.gz -C ./data

# Restart — LSMTree loads from MANIFEST
./build/baradadb
```

### Scenario 3: Complete Data Loss

```bash
# 1. Extract latest backup
tar -xzf backup_latest.tar.gz -C ./data

# 2. Run repair to replay any available WAL
./build/baradadb repair --data-dir=./data

# 3. Start server
./build/baradadb
```

## Storage Requirements

| Backup Type | Size | Frequency | Retention |
|-------------|------|-----------|-----------|
| Full tar.gz | ~1× data size | Weekly | 4 weeks |
| Incremental | ~0.05× data size | Hourly | 24 hours |
| WAL archive | ~0.02× data size / day | Continuous | 7 days |

## Best Practices

1. **Run repair after unclean shutdown** — `./build/baradadb repair`
2. **Migrate legacy SSTables** — `./build/baradadb migrate`
3. **Test restores regularly** — A backup you can't restore is useless
4. **Use incremental + checkpoint** — For frequent consistent snapshots
5. **Store backups offsite** — S3, GCS, or another server
6. **Monitor MANIFEST sequence** — Should grow monotonically with flushes
