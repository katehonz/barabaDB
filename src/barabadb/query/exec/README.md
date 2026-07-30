# Executor package (`query/exec/`)

The original `executor.nim` was a ~5.8k-line god object. It is now split into
focused modules here (1,578 lines remain); `../executor.nim` keeps statement
dispatch (`executeQueryImpl`), DDL, and transactions, and **re-exports** this
package so existing `import barabadb/query/executor` keeps working.

## Modules

| Module | Responsibility |
|--------|----------------|
| `types.nim` | `ExecutionContext`, `TableDef`, `Row`, `ExecResult`, … |
| `values.nim` | Null/string conversion, row payload parse/escape, SQL escapes |
| `schema.nim` | Durable catalog (`_schema:tables:*`), restore, index rebuild |
| `context.nim` | Execution-context lifecycle, per-connection cloning, AST→SQL serializer for VIEW DDL |
| `helpers.nim` | Join strategy, vector parsing, correlated-table helpers |
| `params.nim` | Parameter binding — placeholder substitution, statement column metadata |
| `migrations.nim` | Migration storage — lock keys, applied/record keys, checksums (internal, not re-exported) |
| `eval.nim` | Expression evaluation (`evalExpr` and legacy variants), hybrid vector+FTS search |
| `lower.nim` | AST → IR lowering (`lowerExpr` / `lowerSelect`) |
| `rls.nim` | Row-Level Security — privilege checks and policy evaluation |
| `scan.nim` | Table scans — full scans and point reads against the LSM store |
| `dml.nim` | DML row operations — INSERT/UPDATE/DELETE row-level execution |
| `fk.nim` | Foreign-key enforcement — referential checks and cascade actions |
| `triggers.nim` | Trigger firing, `validateType`, `validateConstraints`, `applyDefaultValues` |
| `window.nim` | Window-function computation, star-row expansion |
| `plan_exec.nim` | IR plan walker (`executePlan`) — filters, projections, aggregates, joins, pivot/unpivot, graph traversal |

## Import rules

- **No cycles.** Bottom-up dependency order:
  `types` → `values` → `schema` → `context`/`helpers`/`params`/`migrations` →
  `eval` → `lower` → `rls` → `scan` → `dml`/`fk` → `triggers` → `window` →
  `plan_exec` → `executor.nim`.
- `executor.nim` imports all modules and `export`s them (except `migrations`).
- Prefer adding new shared helpers under `exec/` instead of growing `executor.nim`.

## Recursion hooks

Nim forbids circular imports, but subqueries, hybrid search, NL→SQL, and
trigger bodies are genuine recursion points between modules: they must call
back into `executePlan`, `execScan`, or the private `executeQueryImpl`, all of
which live in (or above) `executor.nim`. Those back-edges go through proc-var
hooks, wired at module scope in `executor.nim`:

- `eval.executePlanHook`, `eval.execScanHook`, `eval.executeQueryHook` — in `eval.nim`
- `triggers.executeQueryHook` — in `triggers.nim`
