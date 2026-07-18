# BaraDB Benchmarks

## Tiers (read this first)

| Tier | What is measured | Fair peers |
|------|------------------|------------|
| **embedded** | In-process storage API | BaraDB LSM ↔ SQLite |
| **client_server** | Network + query protocol | BaraDB HTTP / **wire** ↔ PostgreSQL |

**Never** quote “BaraDB is Nx faster than Postgres” using embedded LSM numbers.
That comparison mixes tiers and is meaningless as a product claim.

## Quick start

```bash
# 1) Embedded micro-benches (Nim, in-process)
nimble bench
# or: nim c -d:release -r benchmarks/bench_all.nim

# 2) Optional: start server for client_server tier (HTTP + wire)
./build/baradadb

# 3) Fair multi-tier suite (Python)
#    - always: SQLite embedded (+ batch)
#    - optional: BaraDB HTTP (:9912), wire TCP (:9472), PostgreSQL
python3 benchmarks/fair_bench.py

# 3) Markdown report
nimble bench_report
# or: python3 benchmarks/generate_report.py --fair
```

Outputs:

- `benchmark_results.json` — Nim embedded suite  
- `fair_benchmark_results.json` — multi-tier fair suite  
- `benchmarks/FAIR_COMPARISON.md` — human-readable fair report  
- `pg_benchmark_results.json` — optional PG-only micro suite  

## Environment

| Variable | Default | Meaning |
|----------|---------|---------|
| `FAIR_N_KV` | 20000 | embedded KV ops |
| `FAIR_N_SQL` | 5000 | SQL loops (HTTP/wire/PG) |
| `FAIR_BATCH` | 100 | multi-row INSERT batch size |
| `BARADB_HTTP_HOST` | 127.0.0.1 | HTTP host |
| `BARADB_HTTP_PORT` | 9912 | HTTP port (`TCP+440`) |
| `BARADB_WIRE_HOST` | 127.0.0.1 | wire protocol host |
| `BARADB_WIRE_PORT` | 9472 | wire protocol TCP port |
| `FAIR_SKIP_HTTP=1` | — | skip BaraDB HTTP |
| `FAIR_SKIP_WIRE=1` | — | skip BaraDB wire |
| `FAIR_SKIP_PG=1` | — | skip PostgreSQL |
| `PGHOST` / `PGUSER` / `PGPASSWORD` / … | — | libpq-style |

## Files

| File | Role |
|------|------|
| `bench_all.nim` | Embedded: LSM, WAL modes, BTree, vector, FTS, graph |
| `fair_bench.py` | Fair multi-tier runner + markdown |
| `pg_bench.py` | PostgreSQL client-server micro suite |
| `generate_report.py` | `--fair` report; legacy mixed report without flag |
| `compare.nim` | **Synthetic** — do not publish |
| `search_bench.nim` | Search-focused micro suite |

## Durability knobs

- BaraDB: `wal_sync_mode` = `none` \| `group` \| `every` (see WAL-* rows from `bench_all`)  
- SQLite: `PRAGMA synchronous = OFF` vs `FULL`  
- PostgreSQL: `synchronous_commit = off` vs `on`  

Match durability stories when claiming write speedups.

## Wire protocol note

The Python wire client (`clients/python`) is exercised by `fair_bench.py`.
Builds use **`--mm:arc`** (see `nim.cfg`) because Nim **ORC** cycle collection
crashed under async wire INSERT load (`markGray` SIGSEGV). With ARC, sequential
wire INSERTs + batch multi-row INSERT are stable.
