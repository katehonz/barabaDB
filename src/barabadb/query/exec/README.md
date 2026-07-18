# Executor package (`query/exec/`)

The original `executor.nim` was a ~5.8k-line god object. Shared pieces live here;
`../executor.nim` remains the main execution engine and **re-exports** this package
so existing `import barabadb/query/executor` keeps working.

## Modules

| Module | Responsibility |
|--------|----------------|
| `types.nim` | `ExecutionContext`, `TableDef`, `Row`, `ExecResult`, … |
| `values.nim` | Null/string conversion, row payload parse/escape, SQL escapes |
| `schema.nim` | Durable catalog (`_schema:tables:*`), restore, index rebuild |

## Import rules

- **No cycles:** `types` → nothing in `exec/`; `values` → `types`; `schema` → `types` + `values`.
- `executor.nim` imports all three and `export`s them.
- Prefer adding new shared helpers under `exec/` instead of growing `executor.nim`.

## Sensible next extractions (not done yet)

1. `dml.nim` — `execScan` / `execInsert` / `execUpdate` / `execDelete` (needs eval/triggers hooks)
2. `rls.nim` — row-level security + privileges
3. `lower.nim` — AST → IR (`lowerExpr` / `lowerSelect`)
4. `plan_exec.nim` — IR plan walker / window functions
5. `hybrid.nim` — hybrid vector+FTS search helpers

Keep statement dispatch (`executeQueryImpl`) in `executor.nim` until those land.
