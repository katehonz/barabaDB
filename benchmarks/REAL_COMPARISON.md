# BaraDB vs PostgreSQL — Real Benchmark Results

Generated from actual execution on:
- **CPU:** AMD Ryzen 9 5900X
- **PostgreSQL:** 15.18 (local)
- **BaraDB:** git `42043f3`

## Methodology

- PostgreSQL: single-row INSERT/SELECT via psycopg2 (client-server overhead included)
- BaraDB: in-process Nim code (no network overhead)
- Same dataset sizes for both systems

## Results

| Test | PostgreSQL | BaraDB | Speedup |
|------|-----------|--------|---------|
| KV Write (100K) | 16.82K/s (5.946s) | 32.23K/s (3.103s) | 1.9x (BaraDB) |
| KV Read (100K) | 15.08K/s (6.630s) | 3.95M/s (25.3ms) | 261.9x (BaraDB) |
| BTree Insert (100K) | 17.66K/s (5.664s) | 2.52M/s (39.7ms) | 142.8x (BaraDB) |
| BTree Get (100K) | 14.50K/s (6.899s) | 2.34M/s (42.7ms) | 161.4x (BaraDB) |
| BTree Scan (1K ranges) | 2.39K/s (419.2ms) | 11.03M/s (1.0ms) | 4623.3x (BaraDB) |
| FTS Index (10K docs) | 17.98K/s (556.3ms) | 119.99K/s (83.3ms) | 6.7x (BaraDB) |
| FTS Search (1K queries) | 784.12/s (1.275s) | 1.36K/s (734.0ms) | 1.7x (BaraDB) |

## Summary

- **Total PostgreSQL time:** 27.389s
- **Total BaraDB time:** 4.029s
- **Overall speedup:** BaraDB is **6.8x faster**

## Notes

- PostgreSQL includes network round-trip and SQL parsing overhead per operation.
- BaraDB runs in-process with zero serialization/network cost.
- For embedded/single-node use cases, BaraDB shows significant advantage.
- BaraDB now outperforms PostgreSQL on all tested metrics including FTS search after optimizations.
- PostgreSQL excels at durability, replication, and complex ACID transactions.
