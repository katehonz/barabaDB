# Legacy mixed-tier comparison

This file used to claim large “speedups” of BaraDB over PostgreSQL by comparing:

- **PostgreSQL:** client-server (psycopg2, network, SQL)
- **BaraDB:** in-process LSM (no network, no SQL)

That is **not a fair product comparison**.

## Use the fair suite instead

```bash
nim c -d:release -r benchmarks/bench_all.nim   # embedded BaraDB
python3 benchmarks/fair_bench.py               # SQLite + optional PG/HTTP
# report → benchmarks/FAIR_COMPARISON.md
```

See:

- [`FAIR_COMPARISON.md`](FAIR_COMPARISON.md) — latest multi-tier results  
- [`README.md`](README.md) — methodology and env vars  

## If you regenerate the legacy report

```bash
python3 benchmarks/generate_report.py   # without --fair
```

It will rewrite this file with an explicit **mixed tiers** warning banner.
