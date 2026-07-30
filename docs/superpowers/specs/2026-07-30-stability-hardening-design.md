# BaraDB Stability Hardening — Design & Findings

Date: 2026-07-30
Status: Implemented (phase A). Phases B/C proposed, awaiting decision.

## Goal

"Make the database better" — chosen direction: **stability first**. Establish a
verified baseline, fix what is actually broken, and make the whole test suite
run with one command before attempting any large refactoring or new features.

## Baseline established

- Debug build passes cleanly on Nim 2.2.10 (`nimble build_debug`).
- The `hunos` build failure from `HUNOS_ISSUE.md` is **no longer an issue**:
  hunos 1.3.3 is installed and contains the `urandom` fix. The nimble file
  already allows `>= 1.3.0`.
- Of the 13 test files in `tests/`, only `test_all` (+ `stress_test` in CI)
  ran automatically. Baseline run of the other 11: 10 pass,
  `nimforum_smoke_test` fails.

## Changes implemented

### 1. Parser: `header` usable as a column name (bug fix)

**Root cause.** `header` is a keyword token (`tkHeader`) used by
`IMPORT/EXPORT ... HEADER`. The parser never accepted it as an identifier, so
any table with a column named `header` (e.g. the nimforum schema) failed with
`Expected identifier but got tkHeader`.

**Fix** (`src/barabadb/query/parser.nim`):
- Added `tkHeader` to `identLikeKinds` (soft-keyword set used by
  `expectIdent`, line 38).
- Added `tkHeader` to the identifier branch of `parsePrimary` (line 84) so
  `SELECT header ...` and `WHERE header = ...` work.
- Dotted-path parsing (`a.b.c`) now uses `expectIdent` instead of
  `expect(tkIdent)` so `post.header` works too.

IMPORT/EXPORT parsing is unaffected: statement dispatch keys on the leading
`tkImport`/`tkExport` and the clause parser peeks for `tkHeader` explicitly.

**Regression tests** (`tests/bugfix_test.nim`, new suite):
- CREATE TABLE / INSERT / SELECT / WHERE with a column named `header`.
- `IMPORT FROM ... HEADER no` and `EXPORT TO ... HEADER yes` still parse.

Note: `IMPORT ... FORMAT csv` currently fails because `csv` is also a keyword
(`tkCsv`) and `parseImportFrom` expects `tkIdent` after `FORMAT`. Pre-existing
limitation, **not** addressed here (out of scope; recorded for phase B).

### 2. All 13 test files wired into `nimble test` and CI

- `baradadb.nimble` `test` task now builds `build/baradadb` (the smoke test
  talks to it over TCP) and runs all 13 suites: quick embedded suites first,
  fuzz/property/stress last.
- `.github/workflows/ci.yml` runs `nimble test` (was: only `test_all`);
  the now-redundant separate stress-test steps were removed.
- Verified locally: full `nimble test` exits 0 with 648 passing checks.

### 2b. Soft-keyword cleanup (phase B3, implemented)

Extended the `header` approach to all clause-only keywords, so they work as
table/column names everywhere (DDL, DML, aliases, dotted paths, CTEs, JOINs,
MERGE, GRANT/REVOKE, SET):
`format, delimiter, batch, csv, ndjson, status, migration, apply, up, down,
dryrun, user, policy, enable, disable, recover, before, after, instead, of`.

- `identLikeKinds` and the `parsePrimary` identifier branch now include them.
- All 69 `expect(tkIdent)` call sites now use `expectIdent` — a strict
  superset, so previously valid SQL is unaffected (verified: full suite green).
- `IMPORT/EXPORT`: `FORMAT csv/ndjson/json` and `HEADER true/false` now parse
  (previously `csv`/`true`/`false` lexed as keywords and were rejected despite
  the grammar clearly intending them). Clause table names use `expectIdent`.

Structural keywords (`where`, `group`, `order`, `join`, `on`, `for`, `using`,
`view`, `trigger`, `import`, `export`, `grant`, ...) remain reserved.

**Regression tests** (`tests/bugfix_test.nim`): a table with 21 keyword-named
columns through CREATE/INSERT/UPDATE/SELECT/qualified refs, plus
IMPORT/EXPORT keyword-value parsing.

### 3. ORC crash — reproduced, bisected, three root-cause attempts failed

`nim.cfg` forces `--mm:arc` because ORC's cycle collector crashed
("markGray/trace SIGSEGV after ~20 sequential INSERTs"). The ARC cycle-breaking
in commit `ed5a719` did not fix the ORC path.

**Reproduction** (`tests/orc_repro.py`): build the server with `--mm:orc`,
drive 1000 sequential TCP INSERTs plus 10 concurrent connections. The server
dies with the exact documented signature (`handleClient` →
`nimDecRefIsLastCyclicStatic` → `collectCyclesBacon` → `markGray` → `trace` →
SIGSEGV).

**Bisect:** 200 pings + 200 SELECTs over TCP are fine; the crash lands between
20 and 500 sequential INSERTs — INSERT path only.

**Failed root-cause attempts:**
1. `ed5a719` — callback cycle breaks (shard/gossip).
2. `{.cursor.}` on `ExecutionContext.registry` — breaks the real
   `DatabaseRegistry ↔ ExecutionContext` cycle (kept: it is the correct
   ownership annotation regardless), but the crash persists unchanged.
3. Guarding `ctx.onChange` against zero WS subscribers (reverted: fixed
   nothing).

**Conclusion:** per the 3-strikes rule this is a deep ORC+async issue —
possibly an upstream Nim 2.2.x ORC bug with async closure environments and/or
complex generic types — not a single app-level cycle. ARC remains the
supported memory manager (full suite green under it). The findings are
recorded in `nim.cfg` and `tests/orc_repro.py` for a future attempt (e.g.
re-test with a newer Nim runtime, or a minimal repro filed upstream).

## Proposed next phases (not started)

- **B2. Split `query/executor.nim`** (5,398 lines) into focused modules
  (DML, DDL, select pipeline, transactions). Now safe to do: the full suite
  guards behavior. Large diff, mechanical.
- **C. Features** — real Raft network transport, persistence for
  graph/FTS/columnar engines, benchmark validation.
- **ORC (blocked):** re-test `tests/orc_repro.py` against a newer Nim runtime;
  if it persists, distill a minimal repro and file upstream. Not app-actionable
  today (see "ORC crash" section).

## Verification evidence

- `nimble test` (all 13 suites): exit 0, 650 `[OK]`, 0 failed — final run
  after all changes (phase A + B3 + cursor).
- `nimforum_smoke_test` (rebuilt server): all suites `[OK]`, including
  `NimForum schema creation` (previously `[FAILED]`).
- B3 TDD: new keyword tests failed first with the expected `tkFormat`/`tkCsv`
  errors, then passed; `test_all` stayed green (461 `[OK]`).
- ORC investigation: embedded `test_wire_insert_stress` passes even when
  compiled with `--mm:orc`; the TCP **server** compiled with `--mm:orc`
  crashes as documented above. All shipped artifacts use ARC and are green.
