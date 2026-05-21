# Оставащи бъгове — nim-allographer (BaraDB клиент) + BaraDB сървър

> Дата: 2026-05-21
> Поправени в тази сесия: компилационни грешки, `toJson()`, агрегати, `whereIn`/`whereBetween` placeholder-и, `paginate`, transaction cleanup, `insertSql` state.

---

## 🔴 Критични — блокират функционалност

### 1. [СЪРВЪР] SIGSEGV при INSERT в транзакция

**Описание:** `BEGIN` работи, но при първи `INSERT` след него сървърът пада с `Illegal storage access. (Attempt to read from nil?)`.

**Компонент:** BaraDB сървър — транзакционен engine.

**Възпроизвеждане:**
```sql
BEGIN;
INSERT INTO `users` (`name`) VALUES ('Alice');  -- тук пада
```

**Лог:**
```
[1] Query: BEGIN
[1] Query: INSERT INTO `users` (`name`, `email`, `age`) VALUES ('Alice', 'alice@example.com', 30)
SIGSEGV: Illegal storage access.
```

**Забележка:** Не е клиентски бъг. Клиентът изпраща коректно; сървърът крашва при обработка.

---

### 2. [СЪРВЪР] Parser error за резервирани думи като колони

**Описание:** `CREATE TABLE` с колони на име `label` или `count` хвърля `Expected tkIdent but got tkLabels at line 3`. Вероятно `label` е token тип `tkLabels` и lexer/parser-ът не го разпознава като валиден идентификатор.

**Компонент:** BaraDB сървър — lexer/parser.

**Възпроизвеждане:**
```sql
CREATE TABLE test (
  id SERIAL PRIMARY KEY,
  label VARCHAR(255),   -- грешка тук
  count INTEGER         -- и тук
);
```

**Забележка:** Като workaround в клиента може да се използват backtick-ове (`` ` ``), но сървърът трябва да поддържа всякакви имена.

---

## 🟡 Важни — качество и сигурност

### 3. [КЛИЕНТ] SQL injection риск в `formatSql()`

**Описание:** Целият query builder използва `formatSql()` който прави **client-side string interpolation** (`?` → стойност). Това е уязвимост при злонамерен input.

**Файл:** `clients/nim-allographer/src/allographer/query_builder/models/baradb/baradb_exec.nim`, процедура `formatSql()`.

**Проблем:**
```nim
proc formatSql*(sql: string, args: seq[JsonNode]): string =
  result = sql
  for arg in args:
    let pos = result.find("?")
    result = result[0..<pos] & escapeSqlValue(arg) & result[pos+1..^1]
```

**Решение:** Query builder-ът трябва да изпраща заявките чрез **prepared statements** (`mkQueryParams` в wire protocol), вместо да интерполира стойностите в SQL string. Prepared statements вече са имплементирани (`preparedGet`, `preparedExec` в `baradb_exec.nim`), но query builder-ът ги заобикаля.

**Обхват:** Всички `.where()`, `.insert()`, `.update()`, `.delete()` методи в query builder.

---

### 4. [КЛИЕНТ] Schema builder използва `information_schema`

**Описание:** `create_schema.nim` пита `information_schema.tables` и `information_schema.columns`, които са PostgreSQL/MySQL специфични. BaraDB вероятно няма тези view-та.

**Файл:** `clients/nim-allographer/src/allographer/schema_builder/usecases/baradb/create_schema.nim`

**Решение:** Имплементирай BaraDB-специфична интроспекция — или чрез BaraQL команди, или чрез `PRAGMA`-подобни заявки ако сървърът ги поддържа.

---

## 🟢 Дреболии

### 5. [КЛИЕНТ] `getRowPlain()` връща празен seq при празен резултат

**Описание:** Поправено е да не хвърля `IndexDefect`, но сега връща `@[]`. Потребителят не разбира дали заявката е върнала 0 реда или е станала грешка.

**Файл:** `clients/nim-allographer/src/allographer/query_builder/models/baradb/baradb_exec.nim`

---

## Приоритет

| Приоритет | # | Проблем | Отговорност |
|-----------|---|---------|-------------|
| P0 | 1 | Сървърен SIGSEGV при INSERT в транзакция | Сървърен екип |
| P0 | 2 | Сървърен parser error за резервирани думи | Сървърен екип |
| P1 | 3 | SQL injection — преминаване към prepared statements | Клиентски екип |
| P1 | 4 | Schema builder `information_schema` | Клиентски екип |
| P2 | 5 | `getRowPlain()` semantics | Клиентски екип |

