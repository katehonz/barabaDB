# Engine Persistence (C1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make FTS indexes, HNSW vector indexes, and graphs survive a database restart — same query results after reopen, live index updates — fixing the silent-empty-results correctness bug.

**Architecture:** Follow the existing schema-durability pattern: engine DDL is persisted under new `_schema:` key prefixes in the LSM store; at startup a new `restoreEngines*(ctx)` (living in `executor.nim`, the top module) replays it — FTS/HNSW by re-parsing + re-executing the CREATE INDEX DDL via `executeQueryImpl` (rebuild-from-scan), graphs by rebuilding the `Graph` object from the backing `_nodes`/`_edges` tables with the same row→graph mapping the DML path uses (`exec/dml.nim:155-195`). `exec/context.nim` gets one hook var `restoreEnginesHook*` called at the end of `newExecutionContext`, wired by `executor.nim` (the established hook pattern — Nim forbids circular imports; context is L1, restore logic needs L5+ modules).

**Tech Stack:** Nim 2.2.10, ARC, unittest.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-30-engine-persistence-design.md` (read it first).
- Test command per task: `nim c -d:ssl --threads:on --path:src -o:tests/test_schema_persist tests/test_schema_persist.nim && ./tests/test_schema_persist` AND `nim c -d:ssl --threads:on --path:src -o:tests/test_all tests/test_all.nim && ./tests/test_all` — both exit 0.
- TDD: write the failing test FIRST in `tests/test_schema_persist.nim`, watch it fail for the right reason, then implement.
- No behavior changes outside the persistence semantics. No new dependencies. Pure additive `_schema:` keys — old databases without the keys start exactly as before.
- Public API freeze: no changes to exported signatures; additive procs only.
- Failures during engine restore must NOT prevent startup: per-key try/except, warn via the project's logging, continue.
- Reopen pattern for tests (existing in test_schema_persist.nim — reuse its helpers): build ctx on a temp dir, close, create a NEW LSMTree + ExecutionContext on the same dir, assert.
- Commits: per task, after tests pass (user approved per-task commits for this workflow).
- Relevant code facts (verified, use them):
  - CREATE INDEX FTS branch: `src/barabadb/query/executor.nim:1285-1300`; HNSW: `1302-1334`; B-tree: `1336-1350`. AST fields: `stmt.ciKind` (`ikFullText`/`ikHNSW`), `stmt.ciName`, `stmt.ciTarget`, `stmt.ciColumns`.
  - DROP INDEX: `executor.nim:1352-1370` — currently only searches `ctx.btrees`; FTS/HNSW indexes cannot be dropped at all today.
  - CREATE GRAPH: `executor.nim:882-905` (fails if backing tables exist — hence the loader approach, not replay); DROP GRAPH: `907-922`.
  - DROP TABLE: `executor.nim:854-880` (deletes btrees + dropTableSchema + data keys; engine cleanup must be added here).
  - Graph row→object mapping to mirror in the loader: `exec/dml.nim:155-195` (`addNodeWithId` with props from non-id/node_label/properties columns; `addEdgeWithId` with parsed weight).
  - Graph engine API: `gengine.newGraph/addNodeWithId/addEdgeWithId` (`graph/engine.nim:51,71,99`).
  - `newExecutionContext` calls `restoreSchema` at `exec/context.nim:41`; hook call goes right after.
  - Hook idiom to copy: `exec/eval.nim` (var + require* nil-guard) and the wiring block at the bottom of `executor.nim`.
  - Restore must replay via `executeQueryImpl` (NO DDL lock — the lock lives only in the `executeQuery` wrapper; verify).

---

### Task 1: Hook scaffold + FTS index persistence

**Files:**
- Modify: `src/barabadb/query/exec/context.nim` (hook var + call in newExecutionContext)
- Modify: `src/barabadb/query/executor.nim` (persist key in FTS branch, restoreEngines proc, wiring)
- Modify: `src/barabadb/query/exec/schema.nim` (new key prefix const, if the pattern is followed there)
- Test: `tests/test_schema_persist.nim`

**Interfaces:**
- Consumes: existing `restoreSchema` flow; `execScan` for rebuild.
- Produces:
  - `var restoreEnginesHook*: proc(ctx: ExecutionContext)` in `exec/context.nim`, called at the end of `newExecutionContext` (nil-safe: `if restoreEnginesHook != nil: restoreEnginesHook(result)`).
  - `proc restoreEngines*(ctx: ExecutionContext)` in `executor.nim` — wired via `context.restoreEnginesHook = restoreEngines` in the existing hook-wiring block at module scope.
  - Key format: `_schema:ftsidx:<table>.<col>` → reconstructed DDL `CREATE INDEX <name> ON <table> (<cols>) USING FTS` (col list joined; ciName fallback to colKey when empty, mirroring executor.nim:1283).

- [ ] **Step 1: Write the failing test**

Add to `tests/test_schema_persist.nim` (match existing suite style):

```nim
  test "FTS index survives reopen":
    let dir = testDir & "_fts"
    removeDir(dir)
    createDir(dir)
    block:
      let db = newLSMTree(dir)
      var ctx = newExecutionContext(db)
      discard executeQuery(ctx, parse("CREATE TABLE docs (id INTEGER PRIMARY KEY, content TEXT)"))
      discard executeQuery(ctx, parse("INSERT INTO docs (id, content) VALUES (1, 'quick brown fox')"))
      discard executeQuery(ctx, parse("CREATE INDEX docs_fts ON docs (content) USING FTS"))
      ctx.db.close()
    block:
      let db = newLSMTree(dir)
      var ctx = newExecutionContext(db)
      let r = executeQuery(ctx, parse("SELECT hybrid_search_ids('docs', 'content', 'quick') AS ids"))
      check r.success
      check valueToString(r.rows[0]["ids"]).contains("docs.1")
      # index keeps updating after reopen
      discard executeQuery(ctx, parse("INSERT INTO docs (id, content) VALUES (2, 'quick red fox')"))
      let r2 = executeQuery(ctx, parse("SELECT hybrid_search_ids('docs', 'content', 'red') AS ids"))
      check r2.success
      check valueToString(r2.rows[0]["ids"]).contains("docs.2")
      ctx.db.close()
    removeDir(dir)
```

(If `hybrid_search_ids` signature differs, copy the exact working call from `tests/test_all.nim`'s Hybrid RAG Search suite. The key assertion: results are non-empty after reopen — today they are silently empty.)

- [ ] **Step 2: Run it, watch it fail**

Run: `nim c -d:ssl --threads:on --path:src -o:tests/test_schema_persist tests/test_schema_persist.nim && ./tests/test_schema_persist`
Expected: FAIL — ids string empty (index vanished after reopen).

- [ ] **Step 3: Implement**

1. `exec/context.nim`: add `var restoreEnginesHook*: proc(ctx: ExecutionContext)` with a doc comment (wired by executor.nim; breaks the module layering cycle), and call it nil-safely at the end of `newExecutionContext`.
2. `executor.nim`, FTS branch (after `ctx.ftsIndexes[colKey] = ftsIdx`, before the return): persist the reconstructed DDL:
   ```nim
   let ftsDdl = "CREATE INDEX " & idxName & " ON " & stmt.ciTarget & " (" & stmt.ciColumns.join(", ") & ") USING FTS"
   ctx.db.put("_schema:ftsidx:" & colKey, cast[seq[byte]](ftsDdl))
   ```
3. `executor.nim`: new `proc restoreEngines*(ctx: ExecutionContext)` — scans `ctx.db.scanAll()` for keys starting with `_schema:ftsidx:`, per key: try `executeQueryImpl(ctx, qpar.parse(qlex.tokenize(cast[string](value))))` (log warning + continue on failure; replay re-persists the same key idempotently). Wire `context.restoreEnginesHook = restoreEngines` in the module-scope hook block.

- [ ] **Step 4: Run tests, watch them pass**

Run both test commands from Global Constraints.
Expected: new test PASS; test_all exit 0, 461+ `[OK]`.

- [ ] **Step 5: Commit**

```bash
git add src/barabadb/query/exec/context.nim src/barabadb/query/executor.nim tests/test_schema_persist.nim
git commit -m "feat(persist): FTS indexes survive restart (schema key + restore replay)"
```

---

### Task 2: HNSW vector index persistence

**Files:**
- Modify: `src/barabadb/query/executor.nim` (persist key in HNSW branch; extend restoreEngines scan)
- Test: `tests/test_schema_persist.nim`

**Interfaces:**
- Consumes: Task 1's restoreEngines + hook.
- Produces: key format `_schema:vecidx:<table>.<col>` → `CREATE INDEX <name> ON <table> (<cols>) USING HNSW`; restoreEngines scans both prefixes.

- [ ] **Step 1: Write the failing test**

```nim
  test "HNSW vector index survives reopen":
    let dir = testDir & "_vec"
    removeDir(dir)
    createDir(dir)
    block:
      let db = newLSMTree(dir)
      var ctx = newExecutionContext(db)
      discard executeQuery(ctx, parse("CREATE TABLE vecs (id INTEGER PRIMARY KEY, embedding TEXT)"))
      discard executeQuery(ctx, parse("INSERT INTO vecs (id, embedding) VALUES (1, '[1.0, 0.0, 0.0]')"))
      discard executeQuery(ctx, parse("CREATE INDEX vecs_hnsw ON vecs (embedding) USING HNSW"))
      ctx.db.close()
    block:
      let db = newLSMTree(dir)
      var ctx = newExecutionContext(db)
      let r = executeQuery(ctx, parse("SELECT hybrid_search_ids('vecs', 'embedding', '', '[1.0, 0.0, 0.0]') AS ids"))
      check r.success
      check valueToString(r.rows[0]["ids"]).contains("vecs.1")
      ctx.db.close()
    removeDir(dir)
```

(If no pure-vector query form exists, copy the exact working vector-search call from test_all's Hybrid RAG suite — e.g. `hybrid_search_filtered` with a vector arg. Assertion: non-empty after reopen.)

- [ ] **Step 2: Run it, watch it fail**

Expected: FAIL — empty ids after reopen.

- [ ] **Step 3: Implement**

Mirror Task 1: persist `_schema:vecidx:` + reconstructed `USING HNSW` DDL in the HNSW branch; add the `_schema:vecidx:` prefix to the restoreEngines scan (same replay path).

- [ ] **Step 4: Run tests, watch them pass**

Both test commands; expected PASS + test_all green.

- [ ] **Step 5: Commit**

```bash
git add src/barabadb/query/executor.nim tests/test_schema_persist.nim
git commit -m "feat(persist): HNSW vector indexes survive restart"
```

---

### Task 3: Graph persistence

**Files:**
- Modify: `src/barabadb/query/executor.nim` (persist marker on CREATE GRAPH, delete on DROP GRAPH, graph loader in restoreEngines)
- Test: `tests/test_schema_persist.nim`

**Interfaces:**
- Consumes: Task 1's restoreEngines; graph engine API (`gengine.newGraph/addNodeWithId/addEdgeWithId`); row→graph mapping from `exec/dml.nim:155-195`.
- Produces: key format `_schema:graphs:<name>` → original-ish DDL `CREATE GRAPH <name>` (marker + introspection); graph loader that rebuilds `ctx.graphs[name]` from `<name>_nodes` / `<name>_edges` rows.

- [ ] **Step 1: Write the failing test**

```nim
  test "Graph survives reopen":
    let dir = testDir & "_graph"
    removeDir(dir)
    createDir(dir)
    block:
      let db = newLSMTree(dir)
      var ctx = newExecutionContext(db)
      discard executeQuery(ctx, parse("CREATE GRAPH social"))
      discard executeQuery(ctx, parse("INSERT INTO social_nodes (id, node_label) VALUES (1, 'person')"))
      discard executeQuery(ctx, parse("INSERT INTO social_nodes (id, node_label) VALUES (2, 'person')"))
      discard executeQuery(ctx, parse("INSERT INTO social_edges (source_id, dest_id, edge_label, weight) VALUES (1, 2, 'knows', 1.0)"))
      ctx.db.close()
    block:
      let db = newLSMTree(dir)
      var ctx = newExecutionContext(db)
      check "social" in ctx.graphs
      check gengine.nodeCount(ctx.graphs["social"]) == 2
      check gengine.edgeCount(ctx.graphs["social"]) == 1
      ctx.db.close()
    removeDir(dir)
```

(Adjust imports: the test file needs `barabadb/graph/engine as gengine`. If a higher-level graph query is easily available from test_all's graph suites, prefer asserting on that instead/in addition.)

- [ ] **Step 2: Run it, watch it fail**

Expected: FAIL — `"social" in ctx.graphs` is false after reopen.

- [ ] **Step 3: Implement**

1. CREATE GRAPH branch (executor.nim:882-905): on success, `ctx.db.put("_schema:graphs:" & name, cast[seq[byte]]("CREATE GRAPH " & name))`. On the failure paths, no key is written.
2. DROP GRAPH branch (907-922): `ctx.db.delete("_schema:graphs:" & name)`.
3. restoreEngines: for each `_schema:graphs:` key — extract name; skip if already in `ctx.graphs`; build:
   ```nim
   var g = gengine.newGraph()
   # mirror exec/dml.nim:155-195 mapping
   for row in execScan(ctx, name & "_nodes"):
     # id, node_label, props = all other columns except id/node_label/properties
     ...
   for row in execScan(ctx, name & "_edges"):
     # source_id, dest_id, edge_label, weight (parseFloat, default 1.0)
     ...
   ctx.graphs[name] = g
   ```
   Per-key try/except with warning + continue. Use `gengine.addNodeWithId` / `addEdgeWithId` with the SAME failure tolerance as dml.nim (except CatchableError: discard per row).

- [ ] **Step 4: Run tests, watch them pass**

Both test commands; expected PASS + test_all green.

- [ ] **Step 5: Commit**

```bash
git add src/barabadb/query/executor.nim tests/test_schema_persist.nim
git commit -m "feat(persist): graphs survive restart (rebuild from backing tables)"
```

---

### Task 4: DROP paths completeness

**Files:**
- Modify: `src/barabadb/query/executor.nim` (DROP INDEX for FTS/HNSW, DROP TABLE engine cleanup)
- Test: `tests/test_schema_persist.nim`

**Interfaces:**
- Consumes: Tasks 1-3 key formats.
- Produces: DROP INDEX removes in-memory FTS/HNSW index + its `_schema:` key; DROP TABLE removes engine indexes/keys for that table.

- [ ] **Step 1: Write the failing tests**

```nim
  test "DROP INDEX removes FTS index and its schema key":
    let dir = testDir & "_dropfts"
    removeDir(dir)
    createDir(dir)
    block:
      let db = newLSMTree(dir)
      var ctx = newExecutionContext(db)
      discard executeQuery(ctx, parse("CREATE TABLE docs (id INTEGER PRIMARY KEY, content TEXT)"))
      discard executeQuery(ctx, parse("INSERT INTO docs (id, content) VALUES (1, 'quick brown fox')"))
      discard executeQuery(ctx, parse("CREATE INDEX docs_fts ON docs (content) USING FTS"))
      let d = executeQuery(ctx, parse("DROP INDEX docs_fts"))
      check d.success
      check "docs.content" notin ctx.ftsIndexes
      ctx.db.close()
    block:
      let db = newLSMTree(dir)
      var ctx = newExecutionContext(db)
      check "docs.content" notin ctx.ftsIndexes  # no ghost rebuild
      ctx.db.close()
    removeDir(dir)

  test "DROP TABLE removes engine indexes for that table":
    # same flow without the DROP INDEX; DROP TABLE docs instead;
    # after reopen, ctx.ftsIndexes must not contain docs.content
    # and the _schema:ftsidx:docs.content key must be gone
```

(Write both fully, mirroring the first test's structure; adjust colKey format to the actual one — `table.col`.)

- [ ] **Step 2: Run them, watch them fail**

Expected: DROP INDEX test FAILS (FTS index can't be dropped today — `d.success` false or index still present / ghost rebuild after reopen). DROP TABLE test likely FAILS on the ghost-rebuild assertion.

- [ ] **Step 3: Implement**

1. DROP INDEX (executor.nim:1352-1370): before/after the btree search, also check `ctx.ftsIndexes` and `ctx.vectorIndexes` for a key == stmt.diName or ending with "." & stmt.diName or whose idxName matches (mirror the colKey/idxName convention from CREATE INDEX: idxName defaults to colKey); on hit: delete in-memory entry AND `ctx.db.delete("_schema:ftsidx:" / "_schema:vecidx:" & key)`. Keep the existing btree + `_schema:indexes:` behavior untouched.
2. DROP TABLE (executor.nim:854-880): alongside the btree sweep — delete `ctx.ftsIndexes`/`ctx.vectorIndexes` entries whose key starts with `dropName & "."`, and delete the corresponding `_schema:ftsidx:`/`_schema:vecidx:` keys (scan for prefix, same style as the data-keys sweep).

- [ ] **Step 4: Run tests, watch them pass**

Both test commands; expected PASS + test_all green.

- [ ] **Step 5: Commit**

```bash
git add src/barabadb/query/executor.nim tests/test_schema_persist.nim
git commit -m "fix: DROP INDEX/TABLE clean up FTS/HNSW indexes and their schema keys"
```

---

### Task 5: Full verification + docs

**Files:**
- Modify: `docs/superpowers/specs/2026-07-30-engine-persistence-design.md` (status → done)
- Modify: README.md feature claims ONLY IF it explicitly says FTS/vector/graph persistence is missing/optional (check first; minimal edit)

- [ ] **Step 1: Full suite**

Run: `nimble test`
Expected: exit 0, 650+ `[OK]` (new tests add to the count), 0 failed.

- [ ] **Step 2: Docs**

Update the spec status line. Check README for "persistence optional"-style claims about graph/FTS (`grep -n -i 'persist' README.md docs/en/*.md | head -20`); update only lines that are now false, minimally.

- [ ] **Step 3: Commit**

```bash
git add docs/ README.md
git commit -m "docs: engine persistence (C1) done"
```

---

## Self-Review Notes

- Spec coverage: §1 (persist DDL) → Tasks 1-3; §2 (restore) → Tasks 1-3 via restoreEngines; DROP paths → Task 4; testing § → each task's Step 1; failure tolerance → restoreEngines try/except; lock concern → replay via executeQueryImpl (lock lives in the executeQuery wrapper only).
- CREATE GRAPH replay rejected (fails on existing backing tables) → loader approach, per spec's "pick whichever is smaller" clause.
- Riskiest spot: the colKey/idxName conventions in DROP INDEX (Task 4) — tests pin them down.
- Type consistency: hook type `proc(ctx: ExecutionContext)` matches restoreEngines; copied hook idiom from exec/eval.nim.
