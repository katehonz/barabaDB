# Backup и Възстановяване

BaraDB предоставя няколко стратегии за backup — от пълни snapshot-ове до инкрементални и online consistent backups.

## Архитектура

```
┌─────────────────────────────────────────┐
│  Data Directory                         │
│  ├── MANIFEST          (atomic catalog) │
│  ├── sstables/         (SSTable v3 CRC) │
│  │   ├── 1.sst                          │
│  │   └── 2.sst                          │
│  └── wal/                               │
│      ├── wal.log       (активен сегмент)│
│      └── wal_archive/  (ротирани сегменти
└─────────────────────────────────────────┘
```

## SSTable Integrity (v3 CRC Footer)

Всеки SSTable файл, записан от BaraDB, включва CRC32 footer:

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

Това позволява независима проверка на всеки SSTable:

```bash
# Чрез Nim API
import barabadb/storage/lsm
let (ok, msg) = verifySSTable("data/sstables/1.sst")
```

## Storage Repair (`baradb repair`)

При съмнение за повреда, пуснете repair инструмента:

```bash
# Dry run — само преглед
./build/baradadb repair --data-dir=./data --dry-run

# Пълен ремонт — проверка, преместване на битите файлове, WAL replay
./build/baradadb repair --data-dir=./data
```

**Какво прави repair:**
1. Сканира всички `sstables/*.sst` и проверява CRC
2. Премества корумпираните SSTables в `data/corrupt/`
3. Пуска WAL replay за възстановяване на незаписани данни
4. Докладва резултати

## MANIFEST Каталог

Файлът `MANIFEST` е единственият източник на истина за активните SSTables. Обновява се атомично при всеки flush и compaction.

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

Предимства:
- **Консистентен изглед** — няма orphan SSTables след crash
- **Бързо стартиране** — зарежда от MANIFEST вместо scan на директория
- **Откриване на orphans** — `checkStorageConsistency()` докладва излишни/липсващи файлове

## WAL Ротация

Write-Ahead Log се ротира при достигане на 64MB:

```
wal/wal.log          → активен сегмент
wal/wal_archive/
  ├── wal.000001.log
  ├── wal.000002.log
  └── wal.000003.log
```

Ротацията се случва:
- На всеки 1000 WAL записа (лека проверка на размер)
- При всеки `flush` / `checkpoint`

## Checkpoint

Checkpoint създава консистентна граница на storage без спиране на сървъра:

```bash
./build/baradadb checkpoint --data-dir=./data
```

**Как работи:**
1. Freeze на memtable (swap към immutable, нов memtable за writes)
2. Flush на frozen memtable към SSTable
3. Ротация на WAL
4. Запис на MANIFEST

Freeze-ът отнема **< 1ms**; flush-ът продължава паралелно с writes.

## Backup Команди

### Пълен Backup (tar.gz)

```bash
./build/backup backup --data-dir=./data --output=backup_$(date +%s).tar.gz
```

Архивира цялата data директория.

### Инкрементален Backup

```bash
./build/backup incremental --data-dir=./data --output=backup_inc_$(date +%s).tar.gz
```

Включва само:
- `MANIFEST`
- Активни SSTables (от MANIFEST)
- Текущ WAL (`wal/wal.log`)
- WAL архив (`wal/wal_archive/*.log`)

Всички SSTables се **проверяват с CRC** преди архивиране.

### Online Consistent Backup

```bash
./build/baradadb backup --online --output=backup_online_$(date +%s).tar.gz
```

Еквивалентно на:
1. `checkpoint`
2. `incremental backup`

**Безопасно за пускане, когато сървърът е спрян.** Ако сървърът работи, използвайте `backup incremental`.

## Миграция на SSTable Версии

Ако имате legacy v1/v2 SSTables, мигрирайте ги към v3:

```bash
# Преглед
./build/baradadb migrate --data-dir=./data --dry-run

# Миграция
./build/baradadb migrate --data-dir=./data
```

Миграцията пренаписва всеки legacy SSTable в текущия v3 формат (CRC footer) и обновява MANIFEST.

## Процедури за Възстановяване

### Сценарий 1: Открит е Корумпиран SSTable

```bash
# Repair премества битите файлове и пуска WAL replay
./build/baradadb repair --data-dir=./data

# Проверка на консистентност
./build/baradadb repair --data-dir=./data --dry-run
```

### Сценарий 2: Възстановяване от Backup

```bash
# Спиране на сървъра
# Разархивиране на backup
tar -xzf backup_1234567890.tar.gz -C ./data

# Рестарт — LSMTree зарежда от MANIFEST
./build/baradadb
```

### Сценарий 3: Пълна Загуба на Данни

```bash
# 1. Разархивиране на последния backup
tar -xzf backup_latest.tar.gz -C ./data

# 2. Repair за replay на наличния WAL
./build/baradadb repair --data-dir=./data

# 3. Стартиране на сървъра
./build/baradadb
```

## Изисквания за Съхранение

| Тип Backup | Размер | Честота | Задържане |
|------------|--------|---------|-----------|
| Пълен tar.gz | ~1× размер на данните | Седмично | 4 седмици |
| Инкрементален | ~0.05× размер на данните | На всеки час | 24 часа |
| WAL архив | ~0.02× размер на данните / ден | Непрекъснато | 7 дни |

## Най-добри Практики

1. **Пускайте repair след некоректно спиране** — `./build/baradadb repair`
2. **Мигрирайте legacy SSTables** — `./build/baradadb migrate`
3. **Тествайте възстановяването редовно** — Backup, който не може да бъде възстановен, е безполезен
4. **Използвайте incremental + checkpoint** — За чести консистентни snapshot-ове
5. **Съхранявайте backups извън локацията** — S3, GCS или друг сървър
6. **Следете MANIFEST sequence** — Трябва да расте монотонно с flush-овете
