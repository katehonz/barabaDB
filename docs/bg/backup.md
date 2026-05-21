# Backup и Възстановяване

BaraDB предоставя няколко стратегии за backup — от пълни snapshot-ове до инкрементални и online consistent backups.

> ⚠️ **Настройка с множество бази данни**
> BaraDB поддържа множество бази данни (`CREATE DATABASE`). Всяка база има собствена изолирана data директория (напр. `data/databases/<име>/`). Командите за backup, repair, checkpoint и migration работят върху **една директория наведнъж**. Ако използвате множество бази, пускайте командите за всяка база отделно или архивирайте цялата `data/databases/` директория.

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

## Backup Инструмент

Backup инструментът е в `src/barabadb/core/backup.nim`. Компилирайте го преди употреба:

```bash
nim c -o:build/backup src/barabadb/core/backup.nim
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
let (ok, msg) = verifySSTable("data/databases/default/sstables/1.sst")
```

## Storage Repair (`baradadb repair`)

При съмнение за повреда, пуснете repair инструмента за конкретна база данни:

```bash
# Dry run — само преглед
./build/baradadb repair --data-dir=./data/databases/default --dry-run

# Пълен ремонт — проверка, преместване на битите файлове, WAL replay
./build/baradadb repair --data-dir=./data/databases/default
```

**Какво прави repair:**
1. Сканира всички `sstables/*.sst` и проверява CRC
2. Премества корумпираните SSTables в `<data-dir>/corrupt/`
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

При настройка с множество бази данни, всяка база поддържа собствен независим MANIFEST в своята data директория.

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
./build/baradadb checkpoint --data-dir=./data/databases/default
```

**Как работи:**
1. Freeze на memtable (swap към immutable, нов memtable за writes)
2. Flush на frozen memtable към SSTable
3. Ротация на WAL
4. Запис на MANIFEST

Freeze-ът отнема **< 1ms**; flush-ът продължава паралелно с writes.

## Backup Команди

> Компилирайте backup инструмента първо: `nim c -o:build/backup src/barabadb/core/backup.nim`

### Пълен Backup (tar.gz)

```bash
./build/backup backup --data-dir=./data/databases/default --output=backup_$(date +%s).tar.gz
```

Архивира цялата data директория на посочената база данни.

### Инкрементален Backup

```bash
./build/backup incremental --data-dir=./data/databases/default --output=backup_inc_$(date +%s).tar.gz
```

Включва само:
- `MANIFEST`
- Активни SSTables (от MANIFEST)
- Текущ WAL (`wal/wal.log`)
- WAL архив (`wal/wal_archive/*.log`)

Всички SSTables се **проверяват с CRC** преди архивиране.

### Online Consistent Backup

```bash
./build/backup backup --online --data-dir=./data/databases/default --output=backup_online_$(date +%s).tar.gz
```

Еквивалентно на:
1. `checkpoint`
2. `incremental backup`

Безопасно за пускане докато сървърът работи. Checkpoint-ът създава консистентен snapshot, след което инкременталният backup го архивира.

## Миграция на SSTable Версии

Ако имате legacy v1/v2 SSTables, мигрирайте ги към v3 за всяка база данни:

```bash
# Преглед
./build/baradadb migrate --data-dir=./data/databases/default --dry-run

# Миграция
./build/baradadb migrate --data-dir=./data/databases/default
```

Миграцията пренаписва всеки legacy SSTable в текущия v3 формат (CRC footer) и обновява MANIFEST.

## Процедури за Възстановяване

### Сценарий 1: Открит е Корумпиран SSTable

```bash
# Repair премества битите файлове и пуска WAL replay
./build/baradadb repair --data-dir=./data/databases/default

# Проверка на консистентност
./build/baradadb repair --data-dir=./data/databases/default --dry-run
```

### Сценарий 2: Възстановяване от Backup (Единична База)

```bash
# Спиране на сървъра
# Разархивиране на backup в директорията на базата
tar -xzf backup_1234567890.tar.gz -C ./data/databases/default

# Рестарт — LSMTree зарежда от MANIFEST
./build/baradadb
```

### Сценарий 3: Възстановяване на Всички Бази

Ако сте архивирали цялото `data/databases/` дърво:

```bash
# 1. Разархивиране на последния backup
tar -xzf backup_latest.tar.gz -C ./data

# 2. Repair за всяка база за replay на наличния WAL
for db in ./data/databases/*/; do
  ./build/baradadb repair --data-dir="$db" --dry-run
done

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
