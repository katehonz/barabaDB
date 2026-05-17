# BaraDB Deficiencies Fixed During NimForum Migration

This document summarizes the bugs and design deficiencies discovered in BaraDB while porting NimForum from SQLite to BaraDB's TCP wire protocol.

---

## 1. Comma Join Not Supported in Parser

**Problem:** The BaraQL parser did not recognize comma-separated table lists in the `FROM` clause.

```sql
SELECT * FROM thread t, category c WHERE t.category = c.id
```

This would fail with "unknown tokens" after the first comma.

**Root Cause:** `parseSelect()` only parsed a single table after `FROM` and ignored everything after a comma.

**Fix:** Modified `database/src/barabadb/query/parser.nim` to loop over comma-separated tables and treat each additional table as an implicit `CROSS JOIN`.

```nim
while p.peek().kind == tkComma:
  discard p.advance()
  let nextTableTok = p.expect(tkIdent)
  # ... build joinNode with jkCross and add to result.selJoins
```

---

## 2. DEFAULT Constraints Not Evaluated at Schema Creation Time

**Problem:** `CREATE TABLE` with `DEFAULT <expr>` stored the raw AST node instead of the evaluated string value. During `INSERT`, `applyDefaultValues()` checked `colDef.defaultVal.len > 0`, but `defaultVal` was empty because the AST was never evaluated to a string.

**Result:** Explicitly omitted columns in `INSERT` raised `NOT NULL constraint violation` even when a `DEFAULT` was defined.

**Fix:** Added `evalNodeToString()` in `database/src/barabadb/query/executor.nim` to evaluate `DEFAULT` AST nodes to their string representation during schema restoration.

```nim
proc evalNodeToString(node: Node): string =
  let ir = lowerExpr(node)
  return evalExpr(ir, initTable[string, string](), nil)
```

---

## 3. Join Column Resolution Overwrites Duplicate Column Names

**Problem:** `Row` is defined as `Table[string, string]`. When a query selects columns with identical names from joined tables:

```sql
SELECT t.id, c.id FROM thread t INNER JOIN category c ON t.category = c.id
```

The `Project` operator in `executePlan()` builds `newRow` as a `Table`. The second `id` overwrites the first, so both columns end up with the value from the right-hand table.

**Result:** `t.id` returns `0` (category id) instead of `1` (thread id).

**Fix:** Two changes in `database/src/barabadb/query/executor.nim`:

1. `lowerSelect()` — for `nkPath` expressions, use the full path (`t.id`) as the alias instead of just the last segment (`id`).
2. Added uniqueness logic for all aliases: if a duplicate alias is detected, append `_1`, `_2`, etc. This also fixes `strftime()` appearing multiple times in the same select list.

```nim
# Before
projectPlan.projectAliases.add(e.pathParts[^1])        # -> "id"
# After
projectPlan.projectAliases.add(e.pathParts.join(".")) # -> "t.id"
```

---

## 4. Empty Result Sets Do Not Send Column Metadata

**Problem:** In `database/src/barabadb/core/server.nim`, the server only sent the `mkData` message when `result.rows.len > 0`:

```nim
if result.rows.len > 0:
  let dataMsg = serializeResult(result, header.requestId)
  await client.send(...)
```

For queries with zero matching rows (e.g. `WHERE id IN (SELECT ...)` with no subquery matches), the client received only `mkComplete` and no `mkData`.

**Result:** The client saw `columns: @[]` and `rows: @[]`. When `getRow()` fell back to `newSeq[string](qr.columns.len)`, it returned an empty seq, causing "index out of bounds" errors when the application tried to access `row[0]`.

**Fix:** Removed the `if result.rows.len > 0` guard. `serializeResult()` is now always sent, including the correct column names even when `rowCount = 0`.

---

## 5. GROUP BY Returns Empty Values for Non-Aggregated Columns

**Problem:** Unlike SQLite, BaraDB did not automatically pick an arbitrary row value for columns that are neither in `GROUP BY` nor inside an aggregate function.

```sql
SELECT u.id, u.name, count(*)
FROM person u, post p
WHERE p.author = u.id AND p.thread = ?
GROUP BY name
```

**Result:** `u.id`, `u.email`, `u.usrStatus`, etc. returned empty strings, while `name` and `count(*)` were correct.

**Fix:** Modified `query/executor.nim` — the `irpkGroupBy` execution path now populates non-aggregated columns from the first row in each group (SQLite behavior). The forum workaround using `DISTINCT` is no longer necessary.

```nim
# Populate non-aggregated columns from first row in group
if groupRows.len > 0:
  for k, v in groupRows[0]:
    if not k.startsWith("$") and k notin aggRow:
      aggRow[k] = v
```

---

## 6. Inconsistent Aggregate Column Names

**Problem:** Aggregate functions produced column names that omitted the argument expression:

- `SELECT count(*)` → column name `count()`
- `SELECT max(id)` → column name `max()`
- `SELECT min(creation)` → column name `min()`

Code that relies on exact column names (e.g. `getValue` looking up `count(*)`) could be confused.

**Fix:** Modified `query/executor.nim` — `lowerSelect()` now builds aliases using `exprToSql(arg)` for function arguments:

```nim
elif e.kind == nkFuncCall:
  var aliasArgs: seq[string] = @[]
  for arg in e.funcArgs: aliasArgs.add(exprToSql(arg))
  projectPlan.projectAliases.add(e.funcName & "(" & aliasArgs.join(", ") & ")")
```

Result: `SELECT count(*)` now produces column name `count(*)`, matching user expectations.

---

## 7. Async Client + waitFor in Async Context = Connection Instability

**Problem:** The original `baradb_client.nim` used `AsyncSocket` wrapped in `SyncClient` via `waitFor`. When called from inside Jester's async handlers, nested `waitFor` + `poll()` created race conditions on the single socket. `recv(12)` occasionally returned 0 bytes, causing "Connection closed" exceptions.

**Result:** Login and other routes crashed intermittently with 502 Bad Gateway.

**Fix:** Rewrote `SyncClient` in both `clients/nim/src/baradb/client.nim` and `src/barabadb/client/client.nim` to use blocking `net.Socket` from Nim's standard library. This eliminates all async event loop interactions.

Key changes:
- `SyncClient.socket` is now `net.Socket` instead of `AsyncSocket`
- `connect()` uses blocking `net.connect()` instead of `waitFor asyncClient.connect()`
- `query()` uses blocking `recv()` via a `recvExact()` helper instead of `waitFor`
- No dependency on `asyncdispatch` or `waitFor` in sync path
- Fully compatible with the existing wire protocol

---

## 8. Lack of Thread Safety in the Adapter

**Problem:** A single `SyncClient` instance was shared across all HTTP requests. NimForum runs on Jester's async event loop, which can interleave request handlers in the same thread. Without synchronization, two handlers could send queries over the same socket simultaneously, corrupting the wire protocol stream.

**Fix:** Integrated a `Lock` directly into `SyncClient` in both client libraries. Every public operation (`query`, `exec`, `auth`, `ping`, `close`) acquires the lock before touching the socket:

```nim
type
  SyncClient* = ref object
    config: ClientConfig
    socket: net.Socket
    connected: bool
    requestId: uint32
    lock: Lock

proc query*(client: SyncClient, sql: string): QueryResult =
  acquire(client.lock)
  try:
    ... socket I/O ...
  finally:
    release(client.lock)
```

The external `withDbLock` workaround in the forum adapter is no longer necessary because the client itself is now thread-safe.

---

## 9. `key` is a Reserved SQL Keyword

**Problem:** BaraDB's SQL parser treats `key` as a reserved keyword. Using it as a column or table name causes parse errors:

```
Expected tkIdent but got tkKey
```

**Result:** The `settings` table could not use `key varchar(100) primary key`.

**Fix:** Added backtick-quoted identifier support in `query/lexer.nim`. Users can now escape reserved keywords using backticks:

```sql
CREATE TABLE settings(
  `key` varchar(100) primary key,
  value varchar(500) default ''
);
```

Changes made:
- Added `readBacktickIdent()` proc in `lexer.nim`
- Added backtick case in `nextToken()` to recognize `` `identifier` `` as `tkIdent`

---

## 10. Empty String (`""`) Treated as NULL

**Problem:** BaraDB normalized empty strings to `NULL` internally. A column defined as `NOT NULL` rejected empty string inserts, even when the application explicitly passed `''`.

**Result:** SMTP settings saved via the admin panel failed with constraint violations when fields were left blank:

```sql
INSERT INTO settings (skey, value) VALUES ('smtpUser', '');
-- ERROR: NOT NULL constraint violation
```

**Fix:** Changed internal NULL representation from empty string `""` to `\N` in `query/executor.nim`:

1. `isNull()` now checks for `\N` instead of `value.len == 0`
2. NULL literals in INSERT/UPDATE store `\N` instead of `""`
3. Missing columns return `\N` instead of `""`
4. `getValue()` returns `\N` for missing fields
5. JOIN padding uses `\N` for unmatched rows
6. Server wire protocol uses `\N` sentinel to send `fkNull`
7. HTTP server sends JSON `null` for NULL values

This allows empty strings to be stored in NOT NULL columns while still properly supporting NULL values.

---

## Summary Table

| # | Issue | Location | Type |
|---|-------|----------|------|
| 1 | Comma join parsing | `query/parser.nim` | Parser bug |
| 2 | DEFAULT not evaluated | `query/executor.nim` | Schema bug |
| 3 | Duplicate column overwrite | `query/executor.nim` | Data structure bug |
| 4 | Empty result = no columns | `core/server.nim` | Protocol bug |
| 5 | GROUP BY empty values | `query/executor.nim` | Semantic difference |
| 6 | Inconsistent agg names | `query/executor.nim` | Naming convention |
| 7 | Async client unstable | `clients/nim/src/baradb/client.nim` | Client design |
| 8 | No thread safety | `clients/nim/src/baradb/client.nim` | Adapter design |
| 9 | `key` reserved keyword | `query/lexer.nim` | Parser limitation |
| 10 | Empty string = NULL | `query/executor.nim` | Data handling bug |

---

*Document version: 2026-05-17*
