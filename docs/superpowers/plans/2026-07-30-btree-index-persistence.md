# B-tree Index Persistence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Standalone `CREATE [UNIQUE] INDEX` (B-tree) indexes survive a server restart — same pattern as the C1 engine persistence (FTS/HNSW/graph, commits 6703ca2..8df0e02).

**Background (verified facts):**
- CREATE INDEX B-tree branch: `src/barabadb/query/executor.nim` (~line 1376-1390, after the FTS/HNSW branches): builds `ctx.btrees[colKey]` from an execScan, persists NOTHING. After restart the index is gone (planner silently falls back to full scans — performance gap, results stay correct).
- PK/UNIQUE-from-table-DDL B-trees DO survive: their definitions live in persisted table DDL and `rebuildSecondaryIndexes` (exec/schema.nim:134-168) repopulates them at startup.
- `_schema:indexes:` prefix exists ONLY as a never-written delete in DROP INDEX (executor.nim:1437) — do not reuse it; use a new consistent prefix.
- C1 established: `restoreEngines(ctx)` in executor.nim scans `_schema:ftsidx:`/`_schema:vecidx:` prefixes and replays DDL via `executeQueryImpl` (per-key try/except + warn); graphs via loader. Prefix consts live in exec/schema.nim (SchemaFtsIndexPrefix etc.).
- Replay of the B-tree CREATE INDEX branch is idempotent: it replaces `ctx.btrees[colKey]` with a fresh index and repopulates from scan — no double-insert risk against rebuildSecondaryIndexes.
- Parser facts: `parseCreateIndex` (parser.nim:1302+) — name optional (`CREATE INDEX ON t (c)` legal, ciName empty → colKey default), UNIQUE optional (`CREATE UNIQUE INDEX ...`).
- DROP INDEX btree branch (executor.nim:~1392-1439): matches `key == stmt.diName or key.endsWith("." & stmt.diName)` in ctx.btrees, deletes in-memory entry; else-branch deletes `_schema:indexes:<name>` (dead path).
- DROP TABLE sweep (executor.nim:~863-886) already deletes in-memory fts/vec entries + their `_schema:` keys for the table prefix — extend identically.

**Global constraints:**
- TDD: failing test FIRST in `tests/test_schema_persist.nim` (follow its conventions), watch it fail for the right reason, then implement.
- Test commands: `nim c -d:ssl --threads:on --path:src -o:tests/test_schema_persist tests/test_schema_persist.nim && ./tests/test_schema_persist` AND `nim c -d:ssl --threads:on --path:src -o:tests/test_all tests/test_all.nim && ./tests/test_all` — both exit 0.
- No behavior changes otherwise; old DBs unaffected (zero-key scan no-op); startup never fails (restoreEngines' existing per-key try/except covers the new prefix).
- Commits after green; source files only; no push (controller merges+pushes).

---

### Task 1: B-tree index persistence

**Files:**
- Modify: `src/barabadb/query/exec/schema.nim` (new prefix const sibling)
- Modify: `src/barabadb/query/executor.nim` (persist in btree branch, restoreEngines scan, DROP INDEX + DROP TABLE cleanup)
- Test: `tests/test_schema_persist.nim`

**Interfaces:**
- Key format: `_schema:btreeidx:<colKey>` → reconstructed DDL:
  - named: `CREATE [UNIQUE ]INDEX <ciName> ON <table> (<cols join ", ">)`
  - unnamed: `CREATE [UNIQUE ]INDEX ON <table> (<cols join ", ">)` (nameless replayable form, same as the C1 fix)
  - UNIQUE preserved iff `stmt.ciUnique` (check the actual AST field name in query/ast.nim).
- `SchemaBtreeIndexPrefix* = "_schema:btreeidx:"` in exec/schema.nim next to the C1 consts.

- [ ] **Step 1: Failing tests (write all three)**

```nim
  test "B-tree index survives reopen":
    # create table users(id INTEGER PRIMARY KEY, name TEXT, age INTEGER)
    # insert 3 rows; CREATE INDEX users_age ON users (age)
    # verify index works pre-restart: check "users.age" in ctx.btrees
    # close; reopen; check "users.age" in ctx2.btrees
    # verify the planner/lookup can use it: SELECT with WHERE age = ... succeeds
    # insert another row post-reopen, verify ctx2.btrees["users.age"] lookup sees it

  test "Unnamed B-tree index survives reopen":
    # same flow with CREATE INDEX ON users (age) — no name

  test "DROP INDEX removes B-tree index and its schema key":
    # create + index + DROP INDEX users_age; close; reopen
    # check "users.age" notin ctx2.btrees (no ghost rebuild)
```

- [ ] **Step 2: Run, watch them fail**

Expected: first two FAIL (`"users.age" in ctx2.btrees` false after reopen); third may pass or fail depending on current DROP behavior — record which.

- [ ] **Step 3: Implement**

1. exec/schema.nim: add `SchemaBtreeIndexPrefix* = "_schema:btreeidx:"` next to the C1 consts.
2. executor.nim btree CREATE INDEX branch (after the population loop, before return): persist the reconstructed DDL per the format above (UNIQUE iff the AST says so; name clause only when ciName non-empty).
3. restoreEngines: add the `_schema:btreeidx:` prefix to the scan/replay (same executeQueryImpl path).
4. DROP INDEX: in the btree found-branch, also `ctx.db.delete(SchemaBtreeIndexPrefix & targetKey)`; leave the dead `_schema:indexes:` else-branch untouched.
5. DROP TABLE: extend the existing engine sweep to also delete `_schema:btreeidx:` keys with the `dropName & "."` prefix.

- [ ] **Step 4: Run, watch them pass**

Both test commands; expected PASS + test_all green (461+ [OK]).

- [ ] **Step 5: Commit**

```bash
git add src/barabadb/query/exec/schema.nim src/barabadb/query/executor.nim tests/test_schema_persist.nim
git commit -m "feat(persist): standalone B-tree indexes survive restart"
```

---

## Self-Review Notes

- The pattern is proven (C1 fts/vec tasks); the only new surface is the btree DROP-branch key deletion and UNIQUE flag handling — tests pin both.
- UNIQUE flag: verify the AST field name before writing code (grep `ciUnique\|ciKind` src/barabadb/query/ast.nim); if no unique flag exists on the index AST, note it and persist without UNIQUE (and say so in the report).
