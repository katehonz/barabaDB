# Executor.nim Split Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split the 5,398-line `src/barabadb/query/executor.nim` monolith into focused, layered modules under `src/barabadb/query/exec/` without changing any behavior or public API.

**Architecture:** Strictly layered real Nim modules (no circular imports — Nim forbids them). The mutually recursive core (eval ↔ executePlan ↔ dispatcher) is split via two typed proc-var hooks: `eval.executePlanHook` (subqueries) and `triggers.executeQueryHook` (trigger bodies). `executor.nim` becomes the top layer: the `executeQueryImpl` dispatcher + `executeQuery` wrapper, importing and re-exporting everything so existing consumers are untouched.

**Tech Stack:** Nim 2.2.10, ARC (forced by `nim.cfg`), unittest via `tests/test_all.nim` + full `nimble test`.

## Global Constraints

- Build/test command per task: `nim c -d:ssl --threads:on --path:src -o:tests/test_all tests/test_all.nim && ./tests/test_all` (must exit 0; 461+ `[OK]`).
- Final gate (last task only): `nimble test` must exit 0 with 650 `[OK]`.
- Public API freeze: `import barabadb/query/executor` must keep working with every currently exported symbol (`executeQuery`, `executePlan`, `newExecutionContext`, `cloneForConnection`, `evalExpr`, `evalExprOld`, `lowerExpr`, `lowerSelect`, `execInsert`, `execDelete`, `execUpdateRow`, `validateType`, `fireTriggers`, `validateConstraints`, `applyDefaultValues`, `computeWindowValues`, `bindParams`, `extractJoinEquality`, `parseVectorString`). Achieve this with `import exec/x; export x` in `executor.nim` (established pattern, executor.nim:59-64).
- No behavior changes. Pure code motion + import/export plumbing + the two hooks.
- No new dependencies. No `include` files — real modules only.
- Line numbers below are from the pre-split file (5,398 lines). After each extraction they shift — **always relocate procs by name** (`grep -n '^proc name' src/barabadb/query/executor.nim`), never by line number.
- Git commits: only after explicit user confirmation (session rule). Batch `git add` per task, commit when the user approves.

## Layer map (dependency order, bottom → top)

```
L0  exec/types.nim, exec/values.nim, exec/schema.nim   (existing, untouched)
L1  exec/context.nim     Task 1   — newExecutionContext, cloneForConnection, exprToSql, selectToSql
L1  exec/helpers.nim     Task 2   — cmpMax/cmpMin, extractJoinEquality, chooseJoinStrategy, parseVectorString, collectCorrelatedTables*
L1  exec/params.nim      Task 3   — doBindParams, bindParams, getSelectColumns, isDDL
L1  exec/migrations.nim  Task 4   — migration storage helpers (228–299)
L2  exec/eval.nim        Task 5   — evalExpr, evalExprOld, row conversions, hybrid search; hooks: executePlanHook, execScanHook
L3  exec/lower.nim       Task 6   — lowerExpr, lowerSelect, evalNodeToString
L4  exec/rls.nim         Task 7   — hasPrivilege, passesPolicy, checkInsertPolicy
L5  exec/scan.nim        Task 8   — execScan, execPointRead
L6  exec/dml.nim         Task 9   — execInsert, execDelete, execUpdateRow
L7  exec/fk.nim          Task 10  — enforceFkOn*, findReferencingRows
L8  exec/triggers.nim    Task 11  — fireTriggers (hook: executeQueryHook), validateConstraints, applyDefaultValues, validateType
L9  exec/window.nim      Task 12  — partitionKey, compareRowsByOrder, resolveFrameBounds, computeWindowValues, expandStarRow
L10 exec/plan_exec.nim   Task 13  — executePlan
L11 executor.nim         Task 14  — executeQueryImpl dispatcher, executeQuery, executeMigrationSql, hook wiring, re-exports
    cleanup + docs       Task 15
```

---

### Task 1: exec/context.nim

**Files:**
- Create: `src/barabadb/query/exec/context.nim`
- Modify: `src/barabadb/query/executor.nim`

**Interfaces:**
- Consumes: `exec/types.nim` (ExecutionContext, ChangeEvent), `exec/values.nim`, `exec/schema.nim`, `query/ast` (Node), `query/lexer`/`query/parser` only if exprToSql needs them (check imports at executor.nim:1-68 and copy the needed ones).
- Produces: `newExecutionContext*(...)` (copy exact signatures from executor.nim:72 and its overloads), `cloneForConnection*(ctx: ExecutionContext): ExecutionContext`, `exprToSql*(...)`, `selectToSql*(...)`.

- [ ] **Step 1: Move the procs**

Create `src/barabadb/query/exec/context.nim` starting with the module doc comment, then the imports executor.nim uses that these procs need (from executor.nim:1-68 — copy the import block and trim unused ones at the end of the task), then move, from executor.nim: the forward-decl block lines that belong to these procs, `newExecutionContext` (was ~line 72), `exprToSql`, `selectToSql`, `cloneForConnection` (was ~line 201). Every proc called from outside the module keeps its `*` export marker; private helpers stay private.

- [ ] **Step 2: Wire executor.nim**

In executor.nim: delete the moved code; add `import exec/context` + `export context` next to the existing `import exec/types; export types` lines (59-64). Delete now-unneeded forward declarations of the moved procs.

- [ ] **Step 3: Compile and test**

Run: `nim c -d:ssl --threads:on --path:src -o:tests/test_all tests/test_all.nim && ./tests/test_all`
Expected: compile clean (fix missing imports/exports until it is), exit 0, 461+ `[OK]`.

- [ ] **Step 4: Stage for commit**

```bash
git add src/barabadb/query/exec/context.nim src/barabadb/query/executor.nim
# commit only after user confirmation: git commit -m "refactor(exec): extract context management into exec/context.nim"
```

---

### Task 2: exec/helpers.nim

**Files:**
- Create: `src/barabadb/query/exec/helpers.nim`
- Modify: `src/barabadb/query/executor.nim`

**Interfaces:**
- Consumes: `exec/types`, `exec/values`, `query/ast`, `query/ir` (FromPlan for collectCorrelatedTables), stdlib.
- Produces: `cmpMax`, `cmpMin` (private or exported as currently), `extractJoinEquality*`, `chooseJoinStrategy*`, `parseVectorString*`, `collectCorrelatedTablesFromPlan*` (and any sibling collectCorrelatedTables overloads — keep their current export status).

- [ ] **Step 1: Move the procs**

Create `exec/helpers.nim`; move `cmpMax`/`cmpMin` (top of executor.nim, ~65-69) and everything in the 300–436 region: `extractJoinEquality`, `chooseJoinStrategy`, `parseVectorString`, `collectCorrelatedTables*` overloads, plus their forward decls. Copy needed imports (query/ir, query/ast, std/strutils, etc.).

- [ ] **Step 2: Wire executor.nim**

Delete moved code; add `import exec/helpers` + `export helpers`.

- [ ] **Step 3: Compile and test**

Run: `nim c -d:ssl --threads:on --path:src -o:tests/test_all tests/test_all.nim && ./tests/test_all`
Expected: exit 0, 461+ `[OK]`.

- [ ] **Step 4: Stage for commit**

```bash
git add src/barabadb/query/exec/helpers.nim src/barabadb/query/executor.nim
# commit after user confirmation: git commit -m "refactor(exec): extract join/vector helpers into exec/helpers.nim"
```

---

### Task 3: exec/params.nim

**Files:**
- Create: `src/barabadb/query/exec/params.nim`
- Modify: `src/barabadb/query/executor.nim`

**Interfaces:**
- Consumes: `exec/types`, `exec/values`, `exec/context` (`exprToSql` — called by doBindParams, was executor.nim:3878), `query/ast`.
- Produces: `bindParams*`, `getSelectColumns`, `isDDL`, `doBindParams` (private if currently private).

- [ ] **Step 1: Move the procs**

Create `exec/params.nim`; move the 3739–3906 region: `doBindParams`, `bindParams`, `getSelectColumns`, `isDDL` (+ related forward decls). Import `exec/context` for `exprToSql`.

- [ ] **Step 2: Wire executor.nim**

Delete moved code; add `import exec/params` + `export params`.

- [ ] **Step 3: Compile and test**

Run: `nim c -d:ssl --threads:on --path:src -o:tests/test_all tests/test_all.nim && ./tests/test_all`
Expected: exit 0, 461+ `[OK]`.

- [ ] **Step 4: Stage for commit**

```bash
git add src/barabadb/query/exec/params.nim src/barabadb/query/executor.nim
# commit after user confirmation: git commit -m "refactor(exec): extract param binding into exec/params.nim"
```

---

### Task 4: exec/migrations.nim

**Files:**
- Create: `src/barabadb/query/exec/migrations.nim`
- Modify: `src/barabadb/query/executor.nim`

**Interfaces:**
- Consumes: `exec/types`, `exec/values`, `storage/lsm`, `checksums/sha2` (computeChecksum — check current import), std/locks or sync primitives as currently used.
- Produces: `acquireMigrationLock`, `releaseMigrationLock`, `isMigrationApplied`, `getMigrationRecord`, `setMigrationRecord`, `computeChecksum`, `getMigrationBody`, `migrationAppliedKey`, `listMigrations` — keep each proc's current export status (they are private today but used by the dispatcher in executor.nim, so they now need `*`; export them but do NOT re-export migrations from executor.nim — dispatcher imports it directly).

- [ ] **Step 1: Move the procs**

Create `exec/migrations.nim`; move the 228–299 region (all migration storage helpers + their lock globals if any — check for module-level `var` in that range; there is none per analysis, but verify before moving).

- [ ] **Step 2: Wire executor.nim**

Delete moved code; add `import exec/migrations` (NO `export` — internal).

- [ ] **Step 3: Compile and test**

Run: `nim c -d:ssl --threads:on --path:src -o:tests/test_all tests/test_all.nim && ./tests/test_all`
Expected: exit 0, 461+ `[OK]`.

- [ ] **Step 4: Stage for commit**

```bash
git add src/barabadb/query/exec/migrations.nim src/barabadb/query/executor.nim
# commit after user confirmation: git commit -m "refactor(exec): extract migration storage into exec/migrations.nim"
```

---

### Task 5: exec/eval.nim (with hybrid search + hooks)

**Files:**
- Create: `src/barabadb/query/exec/eval.nim`
- Modify: `src/barabadb/query/executor.nim`

**Interfaces:**
- Consumes: `exec/types`, `exec/values`, `exec/schema`, `exec/helpers` (parseVectorString — called by evalExprOld), `query/ast`, `query/ir` (IRPlan for the hook type), FTS/vector engine imports used by the hybrid region (copy from executor.nim imports: `fts/engine`, `vector/engine`, etc.).
- Produces:
  - `evalExpr*` (all current overloads — Row and Table[string,string] variants), `evalExprOld*` (all overloads), `rowToStringTable`, `stringTableToValueRow`, `reciprocalRankFusion`, `realIdFromKey`, `findRealIdByDocId`, `doHybridSearch`, `doHybridSearchFiltered` (keep current export status).
  - Two hook vars (new, the ONLY non-code-motion change):
    ```nim
    ## Wired by executor.nim at module load. Breaks the eval <-> executePlan /
    ## execScan module cycle (subqueries, hybrid search).
    var executePlanHook*: proc(ctx: ExecutionContext, plan: IRPlan): ExecResult
    var execScanHook*: proc(ctx: ExecutionContext, tableName: string): seq[Row]
    ```
    Exact hook signatures MUST be copied from the real `executePlan` / `execScan` signatures in executor.nim before moving (check `proc executePlan*` and `proc execScan` — including all parameters, e.g. filters/RLS args execScan takes; if execScan has more params, the hook type gets all of them).

- [ ] **Step 1: Move eval + hybrid**

Create `exec/eval.nim`; move: `evalExpr` (587-736), `rowToStringTable`/`stringTableToValueRow` (737-755), `evalExprOld` (756-1512), and the hybrid region (437-582: `reciprocalRankFusion`, `realIdFromKey`, `findRealIdByDocId`, `doHybridSearch`, `doHybridSearchFiltered`) including the `{.gcsafe.}` closure if it lives there (~line 542 — move verbatim). Move their forward decls too.

- [ ] **Step 2: Redirect the two back-edges through hooks**

In the moved code: replace every call to `executePlan(...)` inside evalExpr/evalExprOld (was at 889, 909, 1503) with `executePlanHook(...)`; replace the two `execScan(...)` calls in the hybrid procs (was 468, 562) with `execScanHook(...)`. Add the hook var declarations with a nil-guard: first line of each call site region stays a plain call; add at module bottom:
```nim
proc requireExecutePlanHook(): proc(ctx: ExecutionContext, plan: IRPlan): ExecResult =
  if executePlanHook == nil:
    raise newException(ValueError, "executePlanHook not wired (import barabadb/query/executor)")
  executePlanHook
```
and use `requireExecutePlanHook()(...)` at call sites (same pattern for execScanHook). Keep it minimal: direct `executePlanHook(...)` calls are acceptable if the nil raise is added once inside a tiny wrapper.

- [ ] **Step 3: Wire executor.nim**

Delete moved code; add `import exec/eval` + `export eval`. In executor.nim at module scope (bottom, after all procs are defined — or wire in Task 14 if executePlan/execScan are already moved; if still local, wire now):
```nim
eval.executePlanHook = executePlan
eval.execScanHook = execScan
```

- [ ] **Step 4: Compile and test**

Run: `nim c -d:ssl --threads:on --path:src -o:tests/test_all tests/test_all.nim && ./tests/test_all`
Expected: exit 0, 461+ `[OK]` (the correlated-subquery and hybrid-search tests exercise both hooks).

- [ ] **Step 5: Stage for commit**

```bash
git add src/barabadb/query/exec/eval.nim src/barabadb/query/executor.nim
# commit after user confirmation: git commit -m "refactor(exec): extract expression evaluation + hybrid search into exec/eval.nim"
```

---

### Task 6: exec/lower.nim

**Files:**
- Create: `src/barabadb/query/exec/lower.nim`
- Modify: `src/barabadb/query/executor.nim`

**Interfaces:**
- Consumes: `exec/types`, `exec/values`, `exec/context` (`exprToSql` — called by lowerExpr, was 2530), `query/ast`, `query/ir`.
- Produces: `lowerExpr*`, `lowerSelect*`, `evalNodeToString` (keep export status).

- [ ] **Step 1: Move the procs**

Create `exec/lower.nim`; move the 2155–2557 region: `lowerExpr` (~222 lines), `evalNodeToString`, `lowerSelect` (~174 lines) + forward decls.

- [ ] **Step 2: Wire executor.nim**

Delete moved code; add `import exec/lower` + `export lower`.

- [ ] **Step 3: Compile and test**

Run: `nim c -d:ssl --threads:on --path:src -o:tests/test_all tests/test_all.nim && ./tests/test_all`
Expected: exit 0, 461+ `[OK]`.

- [ ] **Step 4: Stage for commit**

```bash
git add src/barabadb/query/exec/lower.nim src/barabadb/query/executor.nim
# commit after user confirmation: git commit -m "refactor(exec): extract AST->IR lowering into exec/lower.nim"
```

---

### Task 7: exec/rls.nim

**Files:**
- Create: `src/barabadb/query/exec/rls.nim`
- Modify: `src/barabadb/query/executor.nim`

**Interfaces:**
- Consumes: `exec/types` (PolicyDef, UserDef), `exec/eval` (`evalExpr`), `exec/lower` (`lowerExpr`) — both called in passesPolicy/checkInsertPolicy.
- Produces: `hasPrivilege`, `passesPolicy`, `checkInsertPolicy` (export all three with `*` — used by scan.nim and dml.nim next; do NOT re-export from executor unless they were exported before).

- [ ] **Step 1: Move the procs**

Create `exec/rls.nim`; move the 1520–1567 region + forward decls (there is a forward-decl block at ~1513 — move what belongs to these procs).

- [ ] **Step 2: Wire executor.nim**

Delete moved code; add `import exec/rls` (+ `export rls` only if any proc was previously exported).

- [ ] **Step 3: Compile and test**

Run: `nim c -d:ssl --threads:on --path:src -o:tests/test_all tests/test_all.nim && ./tests/test_all`
Expected: exit 0, 461+ `[OK]` (RLS/policy tests in test_all exercise this).

- [ ] **Step 4: Stage for commit**

```bash
git add src/barabadb/query/exec/rls.nim src/barabadb/query/executor.nim
# commit after user confirmation: git commit -m "refactor(exec): extract RLS/privileges into exec/rls.nim"
```

---

### Task 8: exec/scan.nim

**Files:**
- Create: `src/barabadb/query/exec/scan.nim`
- Modify: `src/barabadb/query/executor.nim`

**Interfaces:**
- Consumes: `exec/types`, `exec/values`, `exec/rls` (`passesPolicy` — was 1589), `exec/helpers` (`collectCorrelatedTablesFromPlan` — was 1600), storage imports as needed.
- Produces: `execScan`, `execPointRead` — exact current signatures; export both with `*` (needed by fk.nim, plan_exec.nim, and the eval execScanHook wiring).

- [ ] **Step 1: Move the procs**

Create `exec/scan.nim`; move the 1568–1624 region + forward decls.

- [ ] **Step 2: Wire executor.nim**

Delete moved code; add `import exec/scan` + `export scan` (export needed: eval.execScanHook assignment references execScan from executor.nim scope — importing is enough for the wiring line; re-export only if previously exported).

- [ ] **Step 3: Compile and test**

Run: `nim c -d:ssl --threads:on --path:src -o:tests/test_all tests/test_all.nim && ./tests/test_all`
Expected: exit 0, 461+ `[OK]`.

- [ ] **Step 4: Stage for commit**

```bash
git add src/barabadb/query/exec/scan.nim src/barabadb/query/executor.nim
# commit after user confirmation: git commit -m "refactor(exec): extract table scans into exec/scan.nim"
```

---

### Task 9: exec/dml.nim

**Files:**
- Create: `src/barabadb/query/exec/dml.nim`
- Modify: `src/barabadb/query/executor.nim`

**Interfaces:**
- Consumes: `exec/types`, `exec/values`, `exec/schema`, `exec/rls` (`hasPrivilege`, `checkInsertPolicy`), storage/lsm.
- Produces: `execInsert*`, `execDelete*`, `execUpdateRow*` (already exported today; keep signatures).

- [ ] **Step 1: Move the procs**

Create `exec/dml.nim`; move the 1625–1925 region: `execInsert` (~176 lines), `execDelete`, `execUpdateRow` + their private helpers + forward decls. Do NOT move validateType (belongs to triggers task).

- [ ] **Step 2: Wire executor.nim**

Delete moved code; add `import exec/dml` + `export dml`.

- [ ] **Step 3: Compile and test**

Run: `nim c -d:ssl --threads:on --path:src -o:tests/test_all tests/test_all.nim && ./tests/test_all`
Expected: exit 0, 461+ `[OK]`.

- [ ] **Step 4: Stage for commit**

```bash
git add src/barabadb/query/exec/dml.nim src/barabadb/query/executor.nim
# commit after user confirmation: git commit -m "refactor(exec): extract DML row operations into exec/dml.nim"
```

---

### Task 10: exec/fk.nim

**Files:**
- Create: `src/barabadb/query/exec/fk.nim`
- Modify: `src/barabadb/query/executor.nim`

**Interfaces:**
- Consumes: `exec/types` (ForeignKeyDef), `exec/values`, `exec/scan` (`execScan` — called by findReferencingRows, was 1928).
- Produces: `findReferencingRows`, `enforceFkOnDelete`, `enforceFkOnUpdate`, `enforceFkOnChildUpdate` (export with `*` for the dispatcher; NOT validateType — that moves in Task 11).

- [ ] **Step 1: Move the procs**

Create `exec/fk.nim`; move the 1926–2015 region (FK enforcement) — stop before `validateType` (~2016).

- [ ] **Step 2: Wire executor.nim**

Delete moved code; add `import exec/fk` (+ `export fk` only if previously exported).

- [ ] **Step 3: Compile and test**

Run: `nim c -d:ssl --threads:on --path:src -o:tests/test_all tests/test_all.nim && ./tests/test_all`
Expected: exit 0, 461+ `[OK]` (FK enforcement suite in test_all exercises this).

- [ ] **Step 4: Stage for commit**

```bash
git add src/barabadb/query/exec/fk.nim src/barabadb/query/executor.nim
# commit after user confirmation: git commit -m "refactor(exec): extract FK enforcement into exec/fk.nim"
```

---

### Task 11: exec/triggers.nim (with executeQueryHook)

**Files:**
- Create: `src/barabadb/query/exec/triggers.nim`
- Modify: `src/barabadb/query/executor.nim`

**Interfaces:**
- Consumes: `exec/types` (TriggerDef, CheckDef), `exec/values`, `exec/eval` (`evalExpr`), `exec/lower` (`lowerExpr`).
- Produces: `validateType*`, `fireTriggers*`, `validateConstraints*`, `applyDefaultValues*`, plus one new hook var:
  ```nim
  ## Wired by executor.nim at module load. fireTriggers executes trigger
  ## action statements via the dispatcher; the hook breaks the module cycle.
  var executeQueryHook*: proc(ctx: ExecutionContext, ast: Node): ExecResult
  ```
  The signature MUST match how fireTriggers calls executeQueryImpl today (was 2064 — copy the exact call: argument count/types; if it passes params, include them).

- [ ] **Step 1: Move the procs + hook**

Create `exec/triggers.nim`; move `validateType` (~2016-2052), the 2056–2154 region (`fireTriggers`, `validateConstraints`, `applyDefaultValues`) + forward decls (block at ~2053). In `fireTriggers`, replace the `executeQueryImpl(...)` call with `executeQueryHook(...)`; add the nil-guard wrapper pattern from Task 5.

- [ ] **Step 2: Wire executor.nim**

Delete moved code; add `import exec/triggers` + `export triggers`. At module scope in executor.nim (after executeQueryImpl is defined):
```nim
triggers.executeQueryHook = (proc(ctx: ExecutionContext, ast: Node): ExecResult = executeQueryImpl(ctx, ast))
```
(adjust the lambda to the real call signature; executeQueryImpl is private, so the lambda must live in executor.nim — that is exactly why the hook exists).

- [ ] **Step 3: Compile and test**

Run: `nim c -d:ssl --threads:on --path:src -o:tests/test_all tests/test_all.nim && ./tests/test_all`
Expected: exit 0, 461+ `[OK]` (trigger tests exercise the hook).

- [ ] **Step 4: Stage for commit**

```bash
git add src/barabadb/query/exec/triggers.nim src/barabadb/query/executor.nim
# commit after user confirmation: git commit -m "refactor(exec): extract triggers/constraints into exec/triggers.nim"
```

---

### Task 12: exec/window.nim

**Files:**
- Create: `src/barabadb/query/exec/window.nim`
- Modify: `src/barabadb/query/executor.nim`

**Interfaces:**
- Consumes: `exec/types`, `exec/values`, `exec/eval` (`evalExpr` — partitionKey/compareRowsByOrder/computeWindowValues).
- Produces: `partitionKey`, `compareRowsByOrder`, `resolveFrameBounds`, `computeWindowValues*`, `expandStarRow` (export computeWindowValues as today; others per current status — plan_exec.nim needs them, so export all five).

- [ ] **Step 1: Move the procs**

Create `exec/window.nim`; move the 2558–2747 region + forward decls.

- [ ] **Step 2: Wire executor.nim**

Delete moved code; add `import exec/window` + `export window`.

- [ ] **Step 3: Compile and test**

Run: `nim c -d:ssl --threads:on --path:src -o:tests/test_all tests/test_all.nim && ./tests/test_all`
Expected: exit 0, 461+ `[OK]` (window function tests exercise this).

- [ ] **Step 4: Stage for commit**

```bash
git add src/barabadb/query/exec/window.nim src/barabadb/query/executor.nim
# commit after user confirmation: git commit -m "refactor(exec): extract window functions into exec/window.nim"
```

---

### Task 13: exec/plan_exec.nim

**Files:**
- Create: `src/barabadb/query/exec/plan_exec.nim`
- Modify: `src/barabadb/query/executor.nim`

**Interfaces:**
- Consumes: `exec/types`, `exec/values`, `exec/schema`, `exec/eval`, `exec/lower`, `exec/helpers` (`chooseJoinStrategy`, `extractJoinEquality`), `exec/scan` (`execScan`), `exec/window` (`computeWindowValues`, `expandStarRow`), `query/ir`.
- Produces: `executePlan*` (exact current signature — the symbol the eval hook points at).

- [ ] **Step 1: Move the proc**

Create `exec/plan_exec.nim`; move `executePlan` (~990 lines, 2748–3738) + its private helpers + forward decls.

- [ ] **Step 2: Wire executor.nim**

Delete moved code; add `import exec/plan_exec` + `export plan_exec`. If the `eval.executePlanHook = executePlan` wiring (Task 5 Step 3) was deferred, add it now at module scope in executor.nim.

- [ ] **Step 3: Compile and test**

Run: `nim c -d:ssl --threads:on --path:src -o:tests/test_all tests/test_all.nim && ./tests/test_all`
Expected: exit 0, 461+ `[OK]`.

- [ ] **Step 4: Stage for commit**

```bash
git add src/barabadb/query/exec/plan_exec.nim src/barabadb/query/executor.nim
# commit after user confirmation: git commit -m "refactor(exec): extract IR plan execution into exec/plan_exec.nim"
```

---

### Task 14: Slim down executor.nim + verify hook wiring

**Files:**
- Modify: `src/barabadb/query/executor.nim`

**Interfaces:**
- Consumes: all new exec/* modules.
- Produces: unchanged public API: `executeQuery*`, plus re-exports of everything that was exported before.

- [ ] **Step 1: Clean up executor.nim**

executor.nim should now contain ONLY: the import block (trimmed to what the dispatcher needs), `import exec/X` + `export X` lines for all modules, remaining forward decls for `executeQueryImpl` (self-recursion), `executeQueryImpl` (the ~1,473-line dispatcher), `executeQuery` (DDL-locked wrapper — keep the `ctx.sharedLock.lock` semantics byte-identical), `executeMigrationSql`, and the two hook-wiring assignments at module scope:
```nim
eval.executePlanHook = plan_exec.executePlan
eval.execScanHook = scan.execScan
triggers.executeQueryHook = (proc(ctx: ExecutionContext, ast: Node): ExecResult = executeQueryImpl(ctx, ast))
```
(adjust to real signatures). Remove leftover dead forward decls and now-unused imports — verify with the XDeclaredButNotUsed/UnusedImport hints from the compiler output; aim for zero new hints.

- [ ] **Step 2: Compile and test**

Run: `nim c -d:ssl --threads:on --path:src -o:tests/test_all tests/test_all.nim && ./tests/test_all`
Expected: exit 0, 461+ `[OK]`.

- [ ] **Step 3: Verify the public API freeze**

Run: `grep -hoE 'qexec\.[a-zA-Z]+|executor\.[a-zA-Z]+' tests/*.nim src/baradadb.nim src/barabadb/core/server.nim src/barabadb/core/httpserver.nim src/barabadb/mcp/server.nim | sort -u` and confirm every symbol resolves from executor.nim (compile of the full server proves it):
Run: `nim c -d:ssl --threads:on --path:src -o:build/baradadb src/baradadb.nim && nim c -d:ssl --threads:on --path:src -o:build/baramcp src/baramcp.nim`
Expected: both compile clean.

- [ ] **Step 4: Stage for commit**

```bash
git add src/barabadb/query/executor.nim
# commit after user confirmation: git commit -m "refactor(exec): slim executor.nim to dispatcher + hook wiring"
```

---

### Task 15: Full verification + docs

**Files:**
- Modify: `src/barabadb/query/exec/README.md`
- Modify: `docs/superpowers/specs/2026-07-30-stability-hardening-design.md` (mark B2 done)

- [ ] **Step 1: Full test suite**

Run: `nimble test`
Expected: exit 0, 650 `[OK]`, 0 failed. This covers all 13 suites including join_tests, prop_test (uses lowerSelect/executePlan directly), test_wire_insert_stress, nimforum_smoke_test (TCP server).

- [ ] **Step 2: Update exec/README.md**

Rewrite the layering section to the final state: types → values → schema → context/helpers/params/migrations → eval → lower → rls → scan → dml/fk → triggers → window → plan_exec → executor, with a note documenting the two hooks (`executePlanHook`, `execScanHook`, `executeQueryHook`) and why they exist (Nim forbids circular imports; subqueries/trigger bodies are genuine recursion points).

- [ ] **Step 3: Report sizes**

Run: `wc -l src/barabadb/query/executor.nim src/barabadb/query/exec/*.nim | sort -n`
Expected: executor.nim ≈ 1,600 lines; no module over ~1,500 lines.

- [ ] **Step 4: Stage for commit**

```bash
git add src/barabadb/query/exec/README.md docs/superpowers/specs/2026-07-30-stability-hardening-design.md
# commit after user confirmation: git commit -m "docs(exec): document module layering after executor split"
```

---

## Self-Review Notes

- Spec coverage: every region of executor.nim (per the dependency map) is assigned to exactly one task; dispatcher + wrapper stay in Task 14.
- Type consistency: hook signatures are defined by copying the real `executePlan`/`execScan`/`executeQueryImpl` call signatures at the task site — the compiler enforces the match at each task's Step 3.
- Riskiest tasks: 5 (eval + hooks) and 11 (triggers hook) — both are covered by existing correlated-subquery/hybrid/trigger tests in test_all.
