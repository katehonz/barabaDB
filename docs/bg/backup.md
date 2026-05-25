# Backup и Възстановяване

BaraDB предоставя няколко стратегии за backup — от пълни snapshot-ове до инкрементални, online consistent backups и multi-database архивиране.

## Архитектура

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

## Backup Инструмент

```bash
nim c -o:build/backup src/barabadb/core/backup.nim
```

## Multi-Database Backup (Препоръчително)

### Архивиране на всички бази

```bash
./build/backup backup --all-databases --data-root=./data/databases --output=all_$(date +%s).tar.gz
```

Архивът съдържа:
- `backup.json` — метаданни (версия, timestamp, списък бази)
- `databases/<име>/` — всяка база със своя MANIFEST, SSTables и WAL

### Backup на единична база

```bash
./build/backup backup --database=default --data-root=./data/databases --output=default_$(date +%s).tar.gz
```

### Възстановяване на всички бази

```bash
./build/backup restore --input=all_1234567890.tar.gz --all-databases --data-root=./data/databases
```

### Възстановяване на единична база

```bash
./build/backup restore --input=default_1234567890.tar.gz --database=default --data-root=./data/databases
```

## Legacy Single-Directory Backup

За обратна съвместимост със стари инсталации (една база в `data/server`):

```bash
./build/backup backup --data-dir=./data/server --output=legacy_$(date +%s).tar.gz
./build/backup restore --input=legacy_1234567890.tar.gz --data-dir=./data/server
```

## Инкрементален Backup

```bash
./build/backup incremental --database=default --data-root=./data/databases --output=inc_$(date +%s).tar.gz
```

Включва само:
- `MANIFEST`
- Активни SSTables (от MANIFEST)
- Текущ WAL (`wal/wal.log`)
- WAL архив (`wal/wal_archive/*.log`)

Всички SSTables се **проверяват с CRC** преди архивиране.

## Online Consistent Backup

```bash
./build/backup backup --online --database=default --data-root=./data/databases --output=online_$(date +%s).tar.gz
```

Еквивалентно на:
1. `checkpoint` (freeze memtable, flush, rotate WAL)
2. `incremental backup`

Безопасно за пускане докато сървърът работи.

## HTTP API Backup

Backup/restore е достъпен и през REST API (изисква admin JWT токен):

```bash
# Backup на всички бази
curl -X POST http://localhost:9912/backup \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"all": true}'

# Backup на единична база
curl -X POST http://localhost:9912/backup \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"database": "default"}'

# Списък с архиви
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
[Header] 36 байта
  magic, version(3), entryCount, level,
  indexOffset, bloomOffset, footerOffset
[Data Block]
[Index Block]
[Bloom Block]
[Footer] 16 байта
  dataCrc32, indexCrc32, bloomCrc32, reserved
```

## Storage Repair (`baradadb repair`)

```bash
# Dry run — само преглед
./build/baradadb repair --data-dir=./data/databases/default --dry-run

# Пълен ремонт
./build/baradadb repair --data-dir=./data/databases/default
```

## MANIFEST Каталог

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

**Как работи:**
1. Freeze на memtable (< 1ms)
2. Flush към SSTable
3. Ротация на WAL
4. Запис на MANIFEST

## Миграция на SSTable Версии

```bash
./build/baradadb migrate --data-dir=./data/databases/default --dry-run
./build/baradadb migrate --data-dir=./data/databases/default
```

## Процедури за Възстановяване

### Сценарий 1: Корумпиран SSTable

```bash
./build/baradadb repair --data-dir=./data/databases/default
```

### Сценарий 2: Възстановяване от Multi-Database Backup

```bash
# 1. Разархивиране
./build/backup restore --input=backup_latest.tar.gz --all-databases --data-root=./data/databases

# 2. Repair за всяка база
for db in ./data/databases/*/; do
  ./build/baradadb repair --data-dir="$db" --dry-run
done

# 3. Стартиране
./build/baradadb
```

### Сценарий 3: Ръчно разархивиране

```bash
tar -xzf backup_latest.tar.gz -C ./data
# Архивът съдържа: databases/<име>/ + backup.json
```

## Изисквания за Съхранение

| Тип Backup | Размер | Честота | Задържане |
|------------|--------|---------|-----------|
| Пълен tar.gz | ~1× размер на данните | Седмично | 4 седмици |
| Инкрементален | ~0.05× размер на данните | На всеки час | 24 часа |
| WAL архив | ~0.02× размер на данните / ден | Непрекъснато | 7 дни |

## Най-добри Практики

1. **Използвайте `--all-databases`** за пълен backup в multi-DB сетъп
2. **Тествайте възстановяването редовно** — Backup, който не може да бъде възстановен, е безполезен
3. **Пускайте repair след некоректно спиране**
4. **Съхранявайте backups извън локацията** — S3, GCS или друг сървър
5. **Използвайте incremental + checkpoint** — За чести консистентни snapshot-ове
6. **Мониторирайте `/backups` endpoint** — През админ панела или API
