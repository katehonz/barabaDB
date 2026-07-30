# Engine Persistence (C1) — Design

Date: 2026-07-30
Status: Approved direction (user: "продължи"); implementation follows.

## Problem

After a server restart, FTS indexes, HNSW vector indexes, and graph objects
silently vanish while the underlying rows survive (LSM+WAL):

- `CREATE INDEX ... USING FTS` builds an in-memory `InvertedIndex` only
  (`ctx.ftsIndexes`); the DDL is never persisted under `_schema:`.
  DML keeps updating it in memory (`exec/dml.nim:81-89, 295-304`), but nothing
  writes it down.
- Same for HNSW (`ctx.vectorIndexes`) and graphs (`ctx.graphs`; only the
  backing `<name>_nodes`/`_edges` tables are durable).
- `restoreSchema` (`exec/schema.nim:167-231`) restores tables, views,
  triggers, users, policies and rebuilds B-tree secondary indexes — but not
  these three engines. Their `CREATE` DDL is not even stored.
- User-visible effect: hybrid search and graph queries return **silently
  empty results** after restart (guards in `exec/eval.nim:103,150,968-984`),
  and new inserts no longer update the lost indexes. This is a correctness
  bug, not a performance gap.

## Goal

FTS indexes, HNSW vector indexes, and graphs survive a restart: after
reopening the database, the same queries return the same results, and new
DML keeps the indexes up to date.

Non-goals (later phases): snapshot-based persistence for fast startup (C2),
columnar persistence (no `ctx` integration exists yet), Raft transport (C3).

## Design

Follow the existing schema-durability pattern: DDL is serialized under
stable `_schema:<kind>:<name>` keys in the LSM store and replayed at startup
by `restoreSchema`.

### 1. Persist engine DDL

New key prefixes (mirroring `SchemaTablePrefix` etc. in `exec/schema.nim:14-20`):

- `_schema:ftsidx:<table>.<column>` → the original `CREATE INDEX ... USING FTS` DDL
- `_schema:vecidx:<table>.<column>` → the original `CREATE INDEX ... USING HNSW/VECTOR` DDL
- `_schema:graphs:<name>` → the original `CREATE GRAPH ...` DDL

Written by the corresponding `CREATE` execution paths in the dispatcher
(`executeQueryImpl`), deleted by `DROP INDEX` / `DROP GRAPH`, and cleaned up
on `DROP TABLE` for keys belonging to that table (same sweep the current
code does for `_schema:tables:` and secondary-index metadata — check and
extend that path).

### 2. Restore on startup

`restoreSchema` runs after tables are restored and B-tree indexes rebuilt.
New step, in this order:

1. Scan `_schema:ftsidx:` / `_schema:vecidx:` keys, parse each DDL, and
   **re-execute it through `executeQuery`** (the same way table DDL is
   re-applied). The CREATE INDEX path already builds the in-memory index
   from a full table scan, so replay == rebuild, no new build logic.
2. Scan `_schema:graphs:` keys and re-execute the CREATE GRAPH DDL.
   Caveat to resolve at implementation time: replaying CREATE GRAPH must
   not fail when the backing `<name>_nodes`/`_edges` tables already exist
   (they were restored as regular tables). If the CREATE GRAPH execution
   errors on existing tables, the restore path instead rebuilds the in-memory
   `Graph` object by scanning those tables (small new loader in the graph
   engine usage site — the engine has no table-scan loader today, only
   unused binary file save/load). Pick whichever is smaller and matches
   existing behavior; document the choice in the plan.

Failures during engine restore must not prevent startup: log a warning and
continue (a corrupt engine DDL must not take the database down — matches
the defensive style of `restoreSchema`).

### 3. Ordering constraints

- Table restore + row data available BEFORE engine replay (indexes build
  from scans; graphs build from `_nodes`/`_edges`).
- Engine replay runs before the context is served to connections
  (it is part of `newExecutionContext` → `restoreSchema`).

### 4. What does NOT change

- In-memory update paths in `exec/dml.nim` (insert/update/delete keeping
  indexes current) — untouched; they work once the indexes exist again.
- LSM/WAL mechanics; `_schema` table format; B-tree index rebuild.
- Public API: none.

## Testing

New suite in `tests/test_schema_persist.nim` (the existing persistence test
file), TDD — each test fails before the fix:

1. FTS: create table, insert docs, `CREATE INDEX ... USING FTS`, close DB,
   reopen, `hybrid_search`-style query / FTS MATCH query returns the doc
   (pre-fix: silently empty). Insert another doc after reopen and verify it
   is found too (index updates live again).
2. Vector: same flow with an HNSW index and a vector search query.
3. Graph: create graph, add nodes/edges, close, reopen, graph query returns
   the traversal (pre-fix: `"[]"`).
4. DROP INDEX removes the `_schema:ftsidx:`/`:vecidx:` key (no ghost rebuild
   after reopen). DROP TABLE removes engine keys for that table.
5. Existing persistence tests keep passing (regression).

Verification gate: full `nimble test` green (currently 650 `[OK]`).

## Risks

- CREATE GRAPH replay semantics (see §2) — resolved during planning with a
  concrete read of the dispatcher's graph DDL path.
- Startup cost: full-scan rebuilds are O(table size) per index, same as
  today's B-tree rebuild. Acceptable for C1; C2 (snapshots) addresses it.
- Re-executing DDL through `executeQuery` inside `restoreSchema` — must not
  deadlock on `ctx.sharedLock` (DDL lock is taken by `executeQuery`;
  `restoreSchema` runs during context construction, before serving — verify
  no lock is held at that point).
