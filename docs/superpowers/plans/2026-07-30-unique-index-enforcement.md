# UNIQUE Index Enforcement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** `CREATE UNIQUE INDEX` actually enforces uniqueness (today the parser reads UNIQUE but the AST drops it — duplicates are silently accepted), and the flag persists across restarts.

**Background (verified facts):**
- `query/ast.nim:384-389` — the `nkCreateIndex` node carries `ciTarget/ciName/ciColumns/ciExpr/ciKind`, NO unique field.
- `query/parser.nim:1304-1307` — `parseCreateIndex` reads `isUnique` and never stores it.
- Standalone index storage: `ctx.btrees[colKey]`, colKey = `table.col[.col...]`; index values are `colVals.join("|")` of `valueToString(row[col])` (`\N` for missing) — see the CREATE INDEX btree branch in `src/barabadb/query/executor.nim` (~line 1376-1395) and the DML index-update paths in `src/barabadb/query/exec/dml.nim`.
- Index persistence just landed (commit 8d2d97a): `_schema:btreeidx:<colKey>` → replayable DDL, currently WITHOUT UNIQUE (flag didn't exist); replay via restoreEngines → executeQueryImpl.
- ExecutionContext lives in `src/barabadb/query/exec/types.nim`; cloneForConnection in `exec/context.nim` copies fields explicitly — a new field must be added there too.
- INSERT path: `exec/dml.nim execInsert*`; UPDATE path: `execUpdateRow*`. Both already maintain ctx.btrees entries on writes (look at how they insert/delete index entries — the enforcement check goes next to that maintenance).

**Global constraints:**
- TDD: failing tests FIRST in `tests/bugfix_test.nim` (this is a bug fix; follow that file's setupCtx/teardown conventions), watch them fail for the right reason, then implement.
- Test commands: `nim c -d:ssl --threads:on --path:src -o:tests/bugfix_test tests/bugfix_test.nim && ./tests/bugfix_test` AND `nim c -d:ssl --threads:on --path:src -o:tests/test_all tests/test_all.nim && ./tests/test_all` AND `nim c -d:ssl --threads:on --path:src -o:tests/test_schema_persist tests/test_schema_persist.nim && ./tests/test_schema_persist` — all exit 0.
- Error behavior on duplicate: the INSERT/UPDATE returns a non-success ExecResult with a clear message (match existing error style, e.g. PK-duplicate handling in exec/dml.nim) — no panic, no silent accept.
- No public API removals; additive changes only.
- Commits after green; source files only; no push (controller merges+pushes).

---

### Task 1: UNIQUE flag through the pipeline + enforcement

**Files:**
- Modify: `src/barabadb/query/ast.nim` (add `ciUnique*: bool` to the CreateIndex node)
- Modify: `src/barabadb/query/parser.nim` (`result.ciUnique = isUnique` in parseCreateIndex)
- Modify: `src/barabadb/query/exec/types.nim` (add `uniqueIndexes*: HashSet[string]` to ExecutionContext — colKey set)
- Modify: `src/barabadb/query/exec/context.nim` (init in newExecutionContext, copy in cloneForConnection)
- Modify: `src/barabadb/query/executor.nim` (register colKey in uniqueIndexes on CREATE UNIQUE INDEX; duplicate check during index build; persist UNIQUE in the `_schema:btreeidx:` DDL)
- Modify: `src/barabadb/query/exec/dml.nim` (enforcement on INSERT/UPDATE)
- Test: `tests/bugfix_test.nim`, `tests/test_schema_persist.nim`

**Interfaces:**
- `ciUnique*: bool` on the AST node (check the exact object/field style of neighboring fields — ref object with named fields).
- `uniqueIndexes*: HashSet[string]` on ExecutionContext — colKeys of UNIQUE standalone indexes. Registered at CREATE INDEX (when ciUnique), removed at DROP INDEX (btree branch) and DROP TABLE sweep (table prefix).
- Enforcement helper in dml.nim, e.g. `proc violatesUniqueIndex(ctx, table, row, excludeLsmKey = ""): string` returning the offending colKey or "" — builds idxVal with the SAME `colVals.join("|")` + `\N` convention as the CREATE INDEX population loop and checks `ctx.btrees[colKey].get(idxVal)` for an existing entry with a different lsmKey.
- Persisted DDL: named `CREATE UNIQUE INDEX <name> ON ...`, unnamed `CREATE UNIQUE INDEX ON ...` (only when ciUnique — plain indexes keep the current format).

- [ ] **Step 1: Failing tests**

In `tests/bugfix_test.nim` (new suite "Bug fixes — UNIQUE index enforcement"):

```nim
  test "CREATE UNIQUE INDEX rejects duplicate INSERT":
    var ctx = setupCtx()
    defer: teardown(ctx)
    discard executeQuery(ctx, parse("CREATE TABLE accts (id INTEGER PRIMARY KEY, email TEXT)"))
    discard executeQuery(ctx, parse("INSERT INTO accts (id, email) VALUES (1, 'a@b.c')"))
    let c = executeQuery(ctx, parse("CREATE UNIQUE INDEX accts_email ON accts (email)"))
    check c.success
    let dup = executeQuery(ctx, parse("INSERT INTO accts (id, email) VALUES (2, 'a@b.c')"))
    check not dup.success
    let ok = executeQuery(ctx, parse("INSERT INTO accts (id, email) VALUES (2, 'x@y.z')"))
    check ok.success

  test "CREATE UNIQUE INDEX rejects duplicate UPDATE":
    # accts with rows 1:'a@b.c', 2:'x@y.z' + unique index;
    # UPDATE accts SET email = 'a@b.c' WHERE id = 2 → not success;
    # UPDATE accts SET email = 'a@b.c' WHERE id = 1 → success (same row)

  test "CREATE UNIQUE INDEX over duplicate data fails":
    # insert two rows with same email FIRST, then CREATE UNIQUE INDEX → not success
```

In `tests/test_schema_persist.nim`:

```nim
  test "UNIQUE B-tree index survives reopen and still enforces":
    # create accts + unique index + 1 row; close; reopen;
    # duplicate INSERT must fail after reopen too
```

- [ ] **Step 2: Run, watch them fail**

Expected: duplicate INSERT/UPDATE succeed today (bug); CREATE-over-duplicates succeeds today. Confirm failures are those assertions, not compile errors.

- [ ] **Step 3: Implement**

1. ast.nim: add `ciUnique*: bool` to the CreateIndex node (match field style).
2. parser.nim parseCreateIndex: `result.ciUnique = isUnique` (verify the result node's construction site).
3. types.nim: add `uniqueIndexes*: HashSet[string]`; context.nim: init `initHashSet[string]()` in newExecutionContext, copy the set in cloneForConnection (copy semantics: same set or fresh copy? — cloneForConnection shares most index maps by reference; check what it does for `btrees` and match that).
4. executor.nim CREATE INDEX btree branch: if `stmt.ciUnique`: during the population loop detect duplicates (track seen idxVals with their lsmKey; on second occurrence return errResult("duplicate key ...") WITHOUT registering the index); on success `ctx.uniqueIndexes.incl(colKey)`. Persist DDL with UNIQUE per the format above.
5. executor.nim DROP INDEX btree branch: `ctx.uniqueIndexes.excl(targetKey)`; DROP TABLE sweep: excl prefixed keys.
6. dml.nim: in execInsert and execUpdateRow, before writing, for each colKey in ctx.uniqueIndexes that startsWith(table & "."): build idxVal from the incoming row (same convention), look up `ctx.btrees[colKey].get(idxVal)`; if an entry exists with a DIFFERENT lsmKey (for INSERT any entry conflicts; for UPDATE exclude the row's own lsmKey), return/record failure with a clear message like "UNIQUE constraint failed: <colKey>". IMPORTANT: find how execInsert/execUpdateRow report failures today (return count? ExecResult? exceptions?) and integrate with that mechanism — do not invent a new one; check how PK duplicates are handled and mirror it.

- [ ] **Step 4: Run, watch them pass**

All three test commands; expected PASS + test_all/test_schema_persist green.

- [ ] **Step 5: Commit**

```bash
git add src/barabadb/query/ast.nim src/barabadb/query/parser.nim src/barabadb/query/exec/types.nim src/barabadb/query/exec/context.nim src/barabadb/query/executor.nim src/barabadb/query/exec/dml.nim tests/bugfix_test.nim tests/test_schema_persist.nim
git commit -m "fix: CREATE UNIQUE INDEX actually enforces uniqueness (and persists)"
```

---

## Self-Review Notes

- The enforcement must use the EXACT idxVal convention of the CREATE INDEX population loop (`\N` for missing columns, join "|") — a mismatch means false negatives/positives; the tests pin the common cases.
- Multi-row UPDATE (UPDATE ... SET email='x' with no WHERE hitting many rows): enforcement applies per row — note in the report how the existing update loop calls execUpdateRow.
- Composite unique indexes (multi-column) work through the same idxVal convention; not separately tested (same code path).
