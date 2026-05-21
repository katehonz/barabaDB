# Оставащи бъгове — nim-allographer (BaraDB клиент) + BaraDB сървър

> Дата: 2026-05-21
> Поправени в тази сесия: компилационни грешки, `toJson()`, агрегати, `whereIn`/`whereBetween` placeholder-и, `paginate`, transaction cleanup, `insertSql` state.
> **Допълнително поправени:** reserved words parser, cloneForConnection nil fields, SQL injection (prepared statements), `getRowPlain()` semantics, BaraDB-native `SHOW TABLES` + schema builder

---

## 🔴 Критични — блокират функционалност

### ✅ 1. [СЪРВЪР] SIGSEGV при INSERT в транзакция — ПОПРАВЕНО

**Статус:** Поправено. `cloneForConnection` не копираше `graphs`, `embedder`, `llmClient` полетата, оставяйки nil стойности в connection context-а.

**Файл:** `src/barabadb/query/executor.nim` — `cloneForConnection()`

---

### ✅ 2. [СЪРВЪР] Parser error за резервирани думи като колони — ПОПРАВЕНО

**Статус:** Поправено. Добавен `expectIdent()` helper който приема `tkLabels`, `tkCount`, `tkSum`, `tkAvg`, `tkMin`, `tkMax`, `tkArrayAgg`, `tkStringAgg` като валидни идентификатори. Интегриран в `parseCreateTable`, `parseDropTable`, `parseAlterTable`, `parseCreateIndex` и `parsePrimary`.

**Файл:** `src/barabadb/query/parser.nim`

---

## 🟡 Важни — качество и сигурност

### ✅ 3. [КЛИЕНТ] SQL injection риск в `formatSql()` — ПОПРАВЕНО

**Статус:** Поправено. Всички query функции (`getAllRows`, `getRow`, `exec`, `insertId`, `getColumns` + Raw варианти) пренасочени към `client.query(sql, params)` през `mkQueryParams` wire protocol. Стойностите вече не се интерполират в SQL стринга.

**Файл:** `clients/nim-allographer/.../baradb_exec.nim`

---

### ✅ 4. [КЛИЕНТ] Schema builder използва `information_schema` — ПОПРАВЕНО

**Статус:** Поправено.
- **Сървър:** Добавени `SHOW TABLES` и `SHOW COLUMNS FROM table` команди (parser + executor)
- **Клиент:** Schema builder пренаписан да ползва `SHOW TABLES` → `SHOW COLUMNS FROM` вместо `information_schema`

**Файлове:**
- `src/barabadb/query/ast.nim` — добавен `nkShowTables` node
- `src/barabadb/query/parser.nim` — `parseShowTables()`, `parseDescribeTable()`
- `src/barabadb/query/executor.nim` — `nkShowTables` handler
- `clients/nim-allographer/.../create_schema.nim` — BaraDB-native introspection

---

## 🟢 Дреболии

### ✅ 5. [КЛИЕНТ] `getRowPlain()` връща празен seq при празен резултат — ПОПРАВЕНО

**Статус:** Поправено. `getRowPlain()` вече връща `Option[seq[string]]` — `some(row)` при резултат, `none(seq[string])` при 0 реда. `firstPlain`/`findPlain` запазват backward-compatible `seq[string]` API.

**Файл:** `clients/nim-allographer/.../baradb_exec.nim`

---

## Приоритет (след поправките)

| Приоритет | # | Проблем | Статус |
|-----------|---|---------|--------|
| ~~P0~~ | ~~1~~ | ~~Сървърен SIGSEGV при INSERT в транзакция~~ | ✅ Fixed |
| ~~P0~~ | ~~2~~ | ~~Сървърен parser error за резервирани думи~~ | ✅ Fixed |
| ~~P1~~ | ~~3~~ | ~~SQL injection~~ | ✅ Fixed |
| ~~P1~~ | ~~4~~ | ~~Schema builder `information_schema`~~ | ✅ Fixed |
| ~~P2~~ | ~~5~~ | ~~`getRowPlain()` semantics~~ | ✅ Fixed |

**Всички 5 бъга са поправени.** 🎉
