# Fair Benchmark Results

Generated: **2026-07-18 13:53:46 UTC**

## Methodology

- Tier `embedded`: in-process only (BaraDB LSM from nimble bench JSON; SQLite via Python sqlite3).
- Tier `client_server`: network SQL (BaraDB HTTP /query; BaraDB binary wire TCP; PostgreSQL via psycopg2).
- `sql_insert_row`: one INSERT statement per row (chatty).
- `sql_insert_batch`: multi-row INSERT with batch size 50 (same SQL style across systems).
- PostgreSQL: synchronous_commit=on|off; SQLite: PRAGMA synchronous FULL|OFF.
- BaraDB WAL modes appear only if you ran benchmarks/bench_all.nim (WAL-* rows).
- Never claim 'Nx faster than Postgres' using embedded BaraDB numbers.

**Do not compare numbers across tiers.** Embedded storage is not the same
workload as client-server SQL over the network.

## Tier: `embedded`

| Bench | System | ops/s | seconds | n | notes |
|-------|--------|------:|--------:|--:|-------|
| kv_write | `baradb_lsm_embedded` | 41.50K | 2.410 | 100000 | benchmark_results.json |
| kv_read | `baradb_lsm_embedded` | 3.77M | 0.026 | 100000 | benchmark_results.json |
| wal_none | `baradb_lsm_embedded` | 232.65K | 0.215 | 50000 | benchmark_results.json |
| wal_group64 | `baradb_lsm_embedded` | 42.25K | 1.183 | 50000 | benchmark_results.json |
| wal_group256 | `baradb_lsm_embedded` | 107.16K | 0.467 | 50000 | benchmark_results.json |
| wal_every | `baradb_lsm_embedded` | 825.27 | 60.586 | 50000 | benchmark_results.json |
| kv_write | `sqlite_off` | 402.61K | 0.002 | 1000 | PRAGMA synchronous=OFF |
| kv_read | `sqlite_off` | 195.60K | 0.005 | 1000 |  |
| sql_insert_batch | `sqlite_off` | 559.66K | 0.002 | 1000 | multi-row INSERT batch=50, sync=OFF |
| kv_write | `sqlite_full` | 272.62K | 0.004 | 1000 | PRAGMA synchronous=FULL |
| kv_read | `sqlite_full` | 196.16K | 0.005 | 1000 |  |
| sql_insert_batch | `sqlite_full` | 370.18K | 0.003 | 1000 | multi-row INSERT batch=50, sync=FULL |

### Same-bench ratios (`embedded`)

**kv_read** (fastest: `baradb_lsm_embedded` @ 3.77M/s)

| System | Relative to fastest |
|--------|--------------------:|
| `baradb_lsm_embedded` | 1.00x |
| `sqlite_full` | 0.05x |
| `sqlite_off` | 0.05x |

**kv_write** (fastest: `sqlite_off` @ 402.61K/s)

| System | Relative to fastest |
|--------|--------------------:|
| `sqlite_off` | 1.00x |
| `sqlite_full` | 0.68x |
| `baradb_lsm_embedded` | 0.10x |

**sql_insert_batch** (fastest: `sqlite_off` @ 559.66K/s)

| System | Relative to fastest |
|--------|--------------------:|
| `sqlite_off` | 1.00x |
| `sqlite_full` | 0.66x |

## Tier: `client_server`

| Bench | System | ops/s | seconds | n | notes |
|-------|--------|------:|--------:|--:|-------|
| sql_insert_row | `baradb_http` | 979.31 | 0.511 | 500 |  |
| sql_select_row | `baradb_http` | 235.20 | 2.126 | 500 |  |
| sql_insert_batch | `baradb_http` | 10.19K | 0.049 | 500 | multi-row INSERT batch=50 |
| sql_insert_row | `baradb_wire` | 4.65K | 0.108 | 500 | binary wire protocol |
| sql_select_row | `baradb_wire` | 642.04 | 0.779 | 500 |  |
| sql_insert_batch | `baradb_wire` | 20.47K | 0.024 | 500 | multi-row INSERT batch=50 |

### Same-bench ratios (`client_server`)

**sql_insert_batch** (fastest: `baradb_wire` @ 20.47K/s)

| System | Relative to fastest |
|--------|--------------------:|
| `baradb_wire` | 1.00x |
| `baradb_http` | 0.50x |

**sql_insert_row** (fastest: `baradb_wire` @ 4.65K/s)

| System | Relative to fastest |
|--------|--------------------:|
| `baradb_wire` | 1.00x |
| `baradb_http` | 0.21x |

**sql_select_row** (fastest: `baradb_wire` @ 642.04/s)

| System | Relative to fastest |
|--------|--------------------:|
| `baradb_wire` | 1.00x |
| `baradb_http` | 0.37x |

