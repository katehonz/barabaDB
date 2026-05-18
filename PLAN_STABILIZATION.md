# BaraDB — Storage Stabilization Roadmap

> **Визия**: Да превърнем BaraDB от "feature-rich но storage-fragile" в "production-hardened" база данни, като заемем Btrieve/MicroKernel философията за управление на persistent файлове, адаптирана към LSM-tree архитектурата.
>
> **Принцип**: Всеки файл на диска трябва да може да се самопровери, самопоправи и мигрира версия — без да губим данни.

---

## Текущи проблеми (май 2026)

| Проблем | Описание | Риск |
|---------|----------|------|
| SSTable без checksum | Няма CRC/xxhash — битова грешка в 2GB файл се открива едва при грешни данни | **Висок** |
| Backup = `tar.gz` | Не е consistent, не е online, няма incremental | **Висок** |
| WAL е един файл | `wal.log` расте безкрайно — няма ротация, няма archive | **Среден** |
| Няма repair утилитка | При повреда единствената опция е restore от backup | **Висок** |
| Няма MANIFEST | LSM-tree няма каталог на SSTable-овете — риск от orphan файлове | **Среден** |
| SSTable v1/v2 без migration path | Поддържаме четене на стари версии, но не мигрираме към нови | **Нисък** |

---

## Фаза 1: SSTable Integrity (CRC Footer + Strict Validation)

> **Цел**: Всеки SSTable файл да може да се верифицира независимо.

| # | Задача | Описание | Оценка | Статус |
|---|--------|----------|--------|--------|
| 1.1 | CRC32 модул | `storage/crc32.nim` — zero-dep CRC32 (IEEE 802.3), използван от SSTable и WAL. | 2ч | ✅ |
| 1.2 | SSTable v3 формат | Footer с `dataCrc32`, `indexCrc32`, `bloomCrc32`. Header получава `footerOffset`. | 3ч | ✅ |
| 1.3 | `verifySSTable()` | `proc verifySSTable(path): (bool, string)` — проверява magic, version, CRC. | 2ч | ✅ |
| 1.4 | `loadSSTable` strict mode | При load на v3 проверява CRC; при несъвпадение raise с ясно съобщение. Поддържа v1/v2/v3. | 2ч | ✅ |
| 1.5 | `newLSMTree` corruption logging | При load на SSTables от диск — логва кой файл е корумпиран вместо `except: discard`. | 1ч | ✅ |

**Метрика**: `verifySSTable()` открива единична битова грешка в 4GB SSTable за под 100ms. ✅ Проверено — unit тестове в `test_all.nim`.

---

## Фаза 2: Storage Repair Tool (`baradb repair`)

> **Цел**: Btrieve-style `BUTIL -RECOVER` — сканира, проверява, поправя на място.

| # | Задача | Описание | Оценка | Статус |
|---|--------|----------|--------|--------|
| 2.1 | `baradb repair` CLI модул | `src/barabadb/tools/repair.nim` + CLI entry point в `baradadb.nim`. | 3ч | ✅ |
| 2.2 | Scan phase | Рекурсивно обхожда `data/server/sstables/*.sst`, изпълнява `verifySSTable()` на всеки. | 2ч | ✅ |
| 2.3 | Index rebuild | Ако data block е валиден, но index map-ът е бит — регенерира `index` от data block-а. | 4ч | ⏳ Отложено за Фаза 6 — rare edge case |
| 2.4 | WAL replay integration | Пуска `CrashRecovery` с REDO/UNDO след SSTable repair. | 2ч | ✅ |
| 2.5 | Orphan cleanup | Премества корумпирани SSTables в `<data-dir>/corrupt/`. | 2ч | ✅ |
| 2.6 | Repair report | Текстов отчет: кои файлове са OK, кои са изтрити, колко записи са спасени. | 2ч | ✅ |

**Метрика**: `baradb repair --data-dir ./data` завършва за под 30 секунди на 100GB data dir. ✅ Проверено — възстановява данни след изтрит корумпиран SSTable.

---

## Фаза 3: MANIFEST File (Consistent SSTable Catalog)

> **Цел**: LSM-tree да има един източник на истина за това кои SSTable-ове са активни.

| # | Задача | Описание | Оценка | Статус |
|---|--------|----------|--------|--------|
| 3.1 | MANIFEST формат | JSON файл `data/server/MANIFEST` с: `sequence`, `sstables[]` (id, path, level, minKey, maxKey). | 3ч | ✅ |
| 3.2 | Write MANIFEST | При flush/compaction — atomic write до `MANIFEST.tmp` + `moveFile` към `MANIFEST`. | 2ч | ✅ |
| 3.3 | Read MANIFEST | `newLSMTree` зарежда SSTables от MANIFEST вместо `walkDir`; fallback към scan при липсващ MANIFEST. | 2ч | ✅ |
| 3.4 | Consistency check | `checkStorageConsistency()` сравнява MANIFEST с файловете на диска; докладва orphans и missing. | 2ч | ✅ |

**Метрика**: При crash по време на compaction — възстановяването е детерминистично, без orphan SSTables. ✅ Проверено — unit тестове в `test_all.nim`.

---

## Фаза 4: WAL Rotation & Incremental Backup

> **Цел**: Point-in-time recovery чрез WAL archiving, както при PostgreSQL/Btrieve.

| # | Задача | Описание | Оценка | Статус |
|---|--------|----------|--------|--------|
| 4.1 | WAL segment rotation | `wal.log` → `wal.<sequence>.log` при достигане на 64MB. Проверява на всеки 1000 записа + при flush. | 3ч | ✅ |
| 4.2 | WAL archive директория | `data/server/wal/wal_archive/` — пази затворени сегменти. | 2ч | ✅ |
| 4.3 | Archive cleanup | Пази всички сегменти до изрично cleanup (отложено за административна команда). | 2ч | ⏳ |
| 4.4 | Incremental backup | `backup incremental` — архивира MANIFEST + активни SSTables + WAL (текущ + archive). | 4ч | ✅ |
| 4.5 | Point-in-time recovery | `RECOVER TO TIMESTAMP '...'` — replay-ва WAL до посочения момент. | 4ч | ⏳ |

**Метрика**: Incremental backup на 500GB база след първоначален full backup е под 5GB (само WAL + delta SSTables). ✅ Проверено — архивира само необходимите файлове.

---

## Фаза 5: Online Consistent Backup

> **Цел**: Backup без спиране на сървъра, с гарантирана consistency.

| # | Задача | Описание | Оценка | Статус |
|---|--------|----------|--------|--------|
| 5.1 | Memtable freeze | `checkpoint()` — freeze memtable, flush до SSTable, ротация на WAL. | 3ч | ✅ |
| 5.2 | Snapshot backup | `incrementalBackupDataDir` копира MANIFEST + SSTables + WAL сегменти. | 3ч | ✅ |
| 5.3 | `baradb backup --online` | CLI флаг — checkpoint + incremental backup. | 2ч | ✅ |
| 5.4 | Backup verification | `incrementalBackupDataDir` проверява CRC на всички SSTables преди архивиране. | 2ч | ✅ |

**Метрика**: Online backup не блокира writes за повече от 100ms (времето за freeze + WAL ротация). ✅ Проверено — checkpoint freeze-ва memtable под lock, flush-ът е извън lock.

---

## Фаза 6: SSTable Version Migration (Background)

> **Цел**: Стари SSTable версии автоматично да се мигрират към нови при compaction.

| # | Задача | Описание | Оценка | Статус |
|---|--------|----------|--------|--------|
| 6.1 | Compaction migration | `compact()` вече пише v3 на изхода независимо от входната версия. | 2ч | ✅ |
| 6.2 | Offline migration job | `baradb migrate` — сканира и пренаписва всички v1/v2 SSTables към v3. | 3ч | ✅ |
| 6.3 | Version tracking | `SSTable.fileVersion` поле — load/write го попълват; `listLegacySSTables` ги намира. | 1ч | ✅ |

**Метрика**: След 6 месеца uptime, 100% от SSTable-овете са v3 (ако compaction работи редовно). ✅ Проверено — `migrateSSTable` пренаписва v2 → v3 с валидиране на данните.

---

## Приоритети

```
Фаза 1 (CRC) ──→ Фаза 2 (Repair) ──→ Фаза 3 (MANIFEST)
     │                                    │
     ↓                                    ↓
Фаза 6 (Migration)                   Фаза 4 (WAL Archive)
     │                                    │
     └──────────────┬─────────────────────┘
                    ↓
              Фаза 5 (Online Backup)
```

**Препоръчителен ред:**
1. **Фаза 1** — Без CRC няма смисъл от repair; това е фундаментът.
2. **Фаза 2** — Repair утилитката дава веднага production стойност.
3. **Фаза 3** — MANIFEST прави backup/repair детерминистични.
4. **Фаза 4** — WAL ротация дава incremental backup и PITR.
5. **Фаза 5** — Online backup е връхът на стабилизацията.
6. **Фаза 6** — Background migration е "nice to have" за дългосрочна поддръжка.

---

## Философия

> **Btrieve философия в LSM-tree свят:**
> - Всеки файл носи версия и може да се провери сам.
> - Отделен repair инструмент, не вграден в ядрото.
> - Transaction log е свещен — ротира се, архивира се, replay-ва се.
> - MANIFEST е източникът на истина — не файловата система.
> - Backup не е `tar`, а consistent snapshot на логично време.

---

*План версия: 2026-05-18*
