#!/usr/bin/env python3
"""Real PostgreSQL benchmarks to compare against BaraDB."""
import time
import psycopg2
import json
import os

DB_CONFIG = {
    "host": "localhost",
    "database": "postgres",
    "user": "postgres",
    "password": "pas+123",
}


def pg_conn():
    return psycopg2.connect(**DB_CONFIG)


def drop_tables(cur):
    cur.execute("DROP TABLE IF EXISTS bench_kv, bench_btree, bench_fts CASCADE;")


def bench_kv_write(n=100_000):
    """Compare with LSM-Tree write."""
    conn = pg_conn()
    cur = conn.cursor()
    drop_tables(cur)
    cur.execute("CREATE TABLE bench_kv (k TEXT PRIMARY KEY, v TEXT);")
    conn.commit()

    start = time.perf_counter()
    for i in range(n):
        cur.execute(
            "INSERT INTO bench_kv (k, v) VALUES (%s, %s);",
            (f"key_{i}", f"value_{i}"),
        )
    conn.commit()
    elapsed = time.perf_counter() - start

    conn.close()
    return {"name": "KV Write", "ops": n, "seconds": elapsed, "opsPerSec": n / elapsed}


def bench_kv_read(n=100_000):
    """Compare with LSM-Tree read."""
    conn = pg_conn()
    cur = conn.cursor()
    start = time.perf_counter()
    found = 0
    for i in range(n):
        cur.execute("SELECT v FROM bench_kv WHERE k = %s;", (f"key_{i}",))
        if cur.fetchone():
            found += 1
    elapsed = time.perf_counter() - start
    conn.close()
    return {"name": "KV Read", "ops": n, "seconds": elapsed, "opsPerSec": n / elapsed, "found": found}


def bench_btree_insert(n=100_000):
    """Compare with BTree insert."""
    conn = pg_conn()
    cur = conn.cursor()
    drop_tables(cur)
    cur.execute("CREATE TABLE bench_btree (id INTEGER PRIMARY KEY, v TEXT);")
    conn.commit()

    start = time.perf_counter()
    for i in range(n):
        cur.execute(
            "INSERT INTO bench_btree (id, v) VALUES (%s, %s);",
            (i, f"value_{i}"),
        )
    conn.commit()
    elapsed = time.perf_counter() - start
    conn.close()
    return {"name": "BTree Insert", "ops": n, "seconds": elapsed, "opsPerSec": n / elapsed}


def bench_btree_get(n=100_000):
    """Compare with BTree point lookup."""
    conn = pg_conn()
    cur = conn.cursor()
    start = time.perf_counter()
    found = 0
    for i in range(n):
        cur.execute("SELECT v FROM bench_btree WHERE id = %s;", (i,))
        if cur.fetchone():
            found += 1
    elapsed = time.perf_counter() - start
    conn.close()
    return {"name": "BTree Get", "ops": n, "seconds": elapsed, "opsPerSec": n / elapsed, "found": found}


def bench_btree_scan(n=1000):
    """Compare with BTree range scan."""
    conn = pg_conn()
    cur = conn.cursor()
    start = time.perf_counter()
    total = 0
    for _ in range(n):
        cur.execute(
            "SELECT * FROM bench_btree WHERE id BETWEEN %s AND %s;",
            (1000, 2000),
        )
        total += len(cur.fetchall())
    elapsed = time.perf_counter() - start
    conn.close()
    return {"name": "BTree Scan", "ops": n, "seconds": elapsed, "opsPerSec": n / elapsed, "results": total}


def bench_fts_index(n=10_000):
    """Compare with FTS index."""
    conn = pg_conn()
    cur = conn.cursor()
    drop_tables(cur)
    cur.execute("CREATE TABLE bench_fts (id SERIAL PRIMARY KEY, body TEXT);")
    conn.commit()

    docs = [
        "Nim is a statically typed compiled systems programming language",
        "It combines the speed of C with an expressive syntax like Python",
        "Memory management is deterministic with reference counting",
        "The compiler produces optimized native code for all platforms",
        "Metaprogramming and generics enable powerful abstractions",
    ]

    start = time.perf_counter()
    for i in range(n):
        cur.execute(
            "INSERT INTO bench_fts (body) VALUES (%s);",
            (docs[i % len(docs)],),
        )
    conn.commit()
    elapsed = time.perf_counter() - start
    conn.close()
    return {"name": "FTS Index", "ops": n, "seconds": elapsed, "opsPerSec": n / elapsed}


def bench_fts_search(n=1000):
    """Compare with FTS search."""
    conn = pg_conn()
    cur = conn.cursor()
    # Create GIN index for tsvector search
    cur.execute("CREATE INDEX idx_fts ON bench_fts USING GIN (to_tsvector('english', body));")
    conn.commit()

    start = time.perf_counter()
    for _ in range(n):
        cur.execute(
            "SELECT * FROM bench_fts WHERE to_tsvector('english', body) @@ plainto_tsquery('english', %s);",
            ("Nim programming language",),
        )
        cur.fetchall()
    elapsed = time.perf_counter() - start
    conn.close()
    return {"name": "FTS Search", "ops": n, "seconds": elapsed, "opsPerSec": n / elapsed}


def load_baradb_results():
    with open("benchmark_results.json") as f:
        return json.load(f)


def format_ops(ops_per_sec):
    if ops_per_sec >= 1_000_000:
        return f"{ops_per_sec/1_000_000:.2f}M"
    elif ops_per_sec >= 1_000:
        return f"{ops_per_sec/1_000:.2f}K"
    else:
        return f"{ops_per_sec:.2f}"


def print_comparison(pg_results, bara_data):
    bara = {r["name"]: r for r in bara_data["results"]}
    print("\n╔══════════════════════════════════════════════════════════════════════╗")
    print("║           BaraDB vs PostgreSQL — Real Benchmark Results              ║")
    print("╚══════════════════════════════════════════════════════════════════════╝\n")

    rows = [
        ("KV Write (100K)", pg_results.get("KV Write"), bara.get("LSM-Write")),
        ("KV Read (100K)", pg_results.get("KV Read"), bara.get("LSM-Read")),
        ("BTree Insert (100K)", pg_results.get("BTree Insert"), bara.get("BTree-Insert")),
        ("BTree Get (100K)", pg_results.get("BTree Get"), bara.get("BTree-Get")),
        ("BTree Scan (1K ranges)", pg_results.get("BTree Scan"), bara.get("BTree-Scan")),
        ("FTS Index (10K docs)", pg_results.get("FTS Index"), bara.get("FTS-Index")),
        ("FTS Search (1K queries)", pg_results.get("FTS Search"), bara.get("FTS-Search")),
    ]

    print(f"{'Test':<26} {'PostgreSQL':>18} {'BaraDB':>18} {'Winner':>10}")
    print("─" * 76)

    for name, pg, ba in rows:
        if pg is None or ba is None:
            continue
        pg_ops = pg["opsPerSec"]
        ba_ops = ba["opsPerSec"]
        winner = "BaraDB" if ba_ops > pg_ops else "PostgreSQL"
        ratio = max(ba_ops, pg_ops) / min(ba_ops, pg_ops)
        print(
            f"{name:<26} {format_ops(pg_ops)+'/s':>18} {format_ops(ba_ops)+'/s':>18} {winner+' ('+f'{ratio:.1f}x'+')':>10}"
        )

    print("\n" + "─" * 76)
    # Summary
    pg_total = sum(r["seconds"] for _, r, _ in rows if r is not None)
    ba_total = sum(b["seconds"] for _, _, b in rows if b is not None)
    print(f"\nTotal time PostgreSQL: {pg_total:.3f}s")
    print(f"Total time BaraDB:     {ba_total:.3f}s")
    if ba_total < pg_total:
        print(f"BaraDB is {pg_total/ba_total:.1f}x faster overall")
    else:
        print(f"PostgreSQL is {ba_total/pg_total:.1f}x faster overall")


def main():
    print("Running PostgreSQL benchmarks...")
    print("=" * 50)

    pg_results = {}

    print("[1/7] KV Write 100K records...")
    pg_results["KV Write"] = bench_kv_write()
    print(f"      -> {format_ops(pg_results['KV Write']['opsPerSec'])}/s ({pg_results['KV Write']['seconds']:.3f}s)")

    print("[2/7] KV Read 100K records...")
    pg_results["KV Read"] = bench_kv_read()
    print(f"      -> {format_ops(pg_results['KV Read']['opsPerSec'])}/s ({pg_results['KV Read']['seconds']:.3f}s)")

    print("[3/7] BTree Insert 100K keys...")
    pg_results["BTree Insert"] = bench_btree_insert()
    print(f"      -> {format_ops(pg_results['BTree Insert']['opsPerSec'])}/s ({pg_results['BTree Insert']['seconds']:.3f}s)")

    print("[4/7] BTree Get 100K keys...")
    pg_results["BTree Get"] = bench_btree_get()
    print(f"      -> {format_ops(pg_results['BTree Get']['opsPerSec'])}/s ({pg_results['BTree Get']['seconds']:.3f}s)")

    print("[5/7] BTree Scan 1K ranges...")
    pg_results["BTree Scan"] = bench_btree_scan()
    print(f"      -> {format_ops(pg_results['BTree Scan']['opsPerSec'])}/s ({pg_results['BTree Scan']['seconds']:.3f}s)")

    print("[6/7] FTS Index 10K docs...")
    pg_results["FTS Index"] = bench_fts_index()
    print(f"      -> {format_ops(pg_results['FTS Index']['opsPerSec'])}/s ({pg_results['FTS Index']['seconds']:.3f}s)")

    print("[7/7] FTS Search 1K queries...")
    pg_results["FTS Search"] = bench_fts_search()
    print(f"      -> {format_ops(pg_results['FTS Search']['opsPerSec'])}/s ({pg_results['FTS Search']['seconds']:.3f}s)")

    bara_data = load_baradb_results()
    print_comparison(pg_results, bara_data)

    # Save raw results
    with open("pg_benchmark_results.json", "w") as f:
        json.dump(pg_results, f, indent=2)
    print("\nPostgreSQL results saved to pg_benchmark_results.json")


if __name__ == "__main__":
    main()
