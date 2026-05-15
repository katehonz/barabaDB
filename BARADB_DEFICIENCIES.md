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

**Problem:** Unlike SQLite, BaraDB does not automatically pick an arbitrary row value for columns that are neither in `GROUP BY` nor inside an aggregate function.

```sql
SELECT u.id, u.name, count(*)
FROM person u, post p
WHERE p.author = u.id AND p.thread = ?
GROUP BY name
```

**Result:** `u.id`, `u.email`, `u.usrStatus`, etc. return empty strings, while `name` and `count(*)` are correct.

**Fix:** (Workaround in forum code) Replaced `GROUP BY` queries with `DISTINCT` + separate subqueries where ordering by count is not critical:

```sql
SELECT DISTINCT u.id, u.name, u.email, ...
FROM person u, post p
WHERE p.author = u.id AND p.thread = ?
LIMIT 5
```

---

## 6. Inconsistent Aggregate Column Names

**Problem:** Aggregate functions produce column names that omit the argument expression:

- `SELECT count(*)` → column name `count()`
- `SELECT max(id)` → column name `max()`
- `SELECT min(creation)` → column name `min()`

Code that relies on exact column names (e.g. `getValue` looking up `count(*)`) can be confused.

**Fix:** (Workaround in forum code) Avoided name-dependent lookup and rewrote queries to use positional access via `getRow()` / `getAllRows()`.

---

## 7. Async Client + waitFor in Async Context = Connection Instability

**Problem:** The original `baradb_client.nim` used `AsyncSocket` wrapped in `SyncClient` via `waitFor`. When called from inside Jester's async handlers, nested `waitFor` + `poll()` created race conditions on the single socket. `recv(12)` occasionally returned 0 bytes, causing "Connection closed" exceptions.

**Result:** Login and other routes crashed intermittently with 502 Bad Gateway.

**Fix:** Built a new synchronous client (`forum/src/baradb_sync_client.nim`) using blocking `net.Socket` from Nim's standard library. This eliminates all async event loop interactions.

Key differences from the async client:
- Uses `net.Socket` instead of `asyncnet.AsyncSocket`
- Uses blocking `recv()` with an explicit `recvExact()` helper
- No dependency on `asyncdispatch` or `waitFor`
- Fully compatible with the existing wire protocol

---

## 8. Lack of Thread Safety in the Adapter

**Problem:** A single `SyncClient` instance was shared across all HTTP requests. NimForum runs on Jester's async event loop, which can interleave request handlers in the same thread. Without synchronization, two handlers could send queries over the same socket simultaneously, corrupting the wire protocol stream.

**Fix:** Added a global `Lock` and `withDbLock` template in `forum/src/baradb_sqlite.nim`:

```nim
var dbLock: Lock
initLock(dbLock)

template withDbLock(body: untyped) =
  acquire(dbLock)
  try: body
  finally: release(dbLock)
```

All DB operations (`query`, `getRow`, `exec`, etc.) are wrapped in this lock.

---

## Summary Table

| # | Issue | Location | Type |
|---|-------|----------|------|
| 1 | Comma join parsing | `query/parser.nim` | Parser bug |
| 2 | DEFAULT not evaluated | `query/executor.nim` | Schema bug |
| 3 | Duplicate column overwrite | `query/executor.nim` | Data structure bug |
| 4 | Empty result = no columns | `core/server.nim` | Protocol bug |
| 5 | GROUP BY empty values | N/A (engine behavior) | Semantic difference |
| 6 | Inconsistent agg names | N/A (engine behavior) | Naming convention |
| 7 | Async client unstable | `forum/src/baradb_client.nim` | Client design |
| 8 | No thread safety | `forum/src/baradb_sqlite.nim` | Adapter design |

---

*Document version: 2026-05-15*
