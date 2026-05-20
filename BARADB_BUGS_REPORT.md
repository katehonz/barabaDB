# BaraDB Bug Report — NimForum Integration (Stress Test)

**Date:** 2026-05-19  
**Reporter:** NimForum integration team  
**BaraDB Version:** Latest (docker image `nimforum-baradb`)  
**Severity:** High — prevents real-world multi-table applications from working

---

## Summary

During integration of the NimForum application (a real-world web forum) with BaraDB via the native TCP wire protocol, we hit **three distinct SQL-layer bugs** in BaraDB's query executor/parser. All of them are related to multi-table (implicit join) queries. The bugs are severe enough that any application using standard SQL patterns (table aliases, duplicate column names, or `IN (list)` predicates) will receive incorrect results or crash.

---

## Bug 1: Duplicate column names in multi-table implicit joins cause 0 rows returned

### Description
When a `SELECT` from multiple tables uses implicit join syntax (`FROM a, b WHERE ...`) and the selected columns include the **same column name from both tables** (e.g. `a.id` and `b.id`, or `a.name` and `b.name`) **without explicit `AS` aliases**, BaraDB returns **0 rows** even when matching data exists.

### Reproducer

```sql
-- Returns 0 rows (BUG)
SELECT thread.id, thread.name, category.id, category.name
FROM thread, category
WHERE thread.id = 3
  AND thread.isDeleted = 0
  AND thread.category = category.id;

-- Returns 1 correct row (WORKAROUND)
SELECT t.id AS thread_id, t.name AS thread_name,
       c.id AS cat_id, c.name AS cat_name
FROM thread t, category c
WHERE t.id = 3
  AND t.isDeleted = 0
  AND t.category = c.id;
```

### Expected behavior
Both queries should return 1 row with the thread and category data.

### Actual behavior
The first query (without aliases) returns **0 rows**.

### Root cause hypothesis
BaraDB's executor or result-set builder appears to use column names as keys internally. When two selected columns have the same name (`id`, `name`), the second overwrites the first, corrupting the row metadata and causing the executor to discard the row.

### Impact
Any standard SQL query joining two tables on `id` columns (extremely common) will silently fail.

### Workaround used
Add explicit `AS` aliases to every column in multi-table selects.

---

## Bug 2: Column metadata corruption when duplicate names are present

### Description
Even when rows *are* returned (e.g. in a multi-row list query without `WHERE id = ?`), if duplicate column names exist, the **column metadata and data values are scrambled**. Values from one column appear in another column's position.

### Reproducer

```sql
SELECT t.id, t.name, c.id, c.name, c.description, c.color
FROM thread t, category c
WHERE t.isDeleted = 0 AND t.category = c.id
ORDER BY modified DESC LIMIT 1;
```

### Expected behavior
| id | name | id | name | description | color |
|---|---|---|---|---|---|
| 3 | Test Thread2 | 1 | baradb | multimodal database engine written in Nim | 1a465b |

### Actual behavior
Column metadata returned by BaraDB:
```
Columns: ['id', 'name', 'views', "strftime('%s', \"modified\")", 'isLocked', 'isPinned', 'id', 'name', 'description', 'color']
Row[0]: ['3', 'Test Thread2', 0, '1779200191', <bool>, None, <bool>, None, '1', 'baradb']
```
Values are shifted/missing for the second table's columns.

### Impact
Client code receives corrupted data. In our case `category.description` became `"1"` and `category.color` became `"baradb"`, which would break UI rendering.

### Workaround used
Same as Bug 1: explicit `AS` aliases for every column.

---

## Bug 3: `IN (val1, val2, ...)` list syntax not supported

### Description
BaraDB's SQL parser does not accept the standard `IN` predicate with a comma-separated value list. It throws a parse error.

### Reproducer

```sql
-- ERROR: Expected tkRParen but got tkComma at line 1
SELECT id, name, email
FROM person
WHERE id IN (2, 1);
```

### Expected behavior
Should return rows for `id = 2` and `id = 1`.

### Actual behavior
Parser error: `Expected tkRParen but got tkComma at line 1`

### Impact
Any application that dynamically builds `IN (...)` lists (e.g. looking up multiple users by ID) cannot function without rewriting every query.

### Workaround used
Replace `IN (2, 1)` with `id = 2 OR id = 1` generated dynamically in the application code.

---

## Bug 4: `person.id` / `post.id` in three-table join produces `nkPath` column names

### Description
In a three-table implicit join, when column references use `table.column` syntax, BaraDB's parser sometimes produces corrupted column names like `"strftime('%s', nkPath)"` instead of `"strftime('%s', post.creation)"`.

### Reproducer

```sql
SELECT post.id, strftime('%s', post.creation), post.thread,
       person.id, person.name, person.email,
       strftime('%s', person.lastOnline),
       strftime('%s', person.previousVisitAt), person.usrStatus,
       person.isDeleted,
       thread.name
FROM post, person, thread
WHERE post.thread = thread.id
  AND post.author = person.id
  AND post.id = 10;
```

### Actual column metadata returned
```
Columns: ['id', "strftime('%s', nkPath)", 'thread', 'id', 'name', 'email',
          "strftime('%s', nkPath)", "strftime('%s', nkPath)",
          'usrStatus', 'isDeleted', 'name']
```

### Impact
Result set metadata is unreadable. Client code cannot map columns to fields.

### Workaround used
Use `AS` aliases for every expression and column: `p.id AS post_id`, `strftime('%s', p.creation) AS post_creation`, etc.

---

## General Observations

### What works reliably
- Single-table `SELECT`, `INSERT`, `UPDATE`, `DELETE`
- `SELECT` with sub-queries (`WHERE id IN (SELECT author FROM post WHERE thread = ?)`)
- `LIMIT`, `ORDER BY`, `WHERE` with single-table conditions
- `COUNT(*)`, `MIN()`, `MAX()` aggregates
- `strftime('%s', column)` expressions

### What fails or is fragile
- Multi-table implicit joins (`FROM a, b WHERE a.id = b.id`) **without** `AS` aliases
- `IN (list)` with literal value lists
- `table.column` syntax inside `strftime()` or similar functions in multi-table queries

### Recommendation for BaraDB team
1. **Fix column deduplication in result sets** — the executor should not use raw column names as internal keys; it should use ordinal positions or alias names.
2. **Support `IN (val1, val2, ...)`** — extend the parser to accept comma-separated expressions inside `IN (...)`.
3. **Investigate `nkPath` leak in parser** — `post.creation` inside `strftime()` should not be tokenized into `nkPath` in the column metadata output.

---

## Appendix: Test Environment

- **Client:** Custom synchronous Nim TCP client (`baradb_sync_client.nim`) using `net.Socket`
- **Wire protocol:** Binary protocol with `mkQuery` (0x02), `mkData` (0x82), `mkComplete` (0x83)
- **Result format:** `rfBinary` (0x00)
- **Connection:** Fresh socket per query (to rule out interleaving)
