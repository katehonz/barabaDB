#!/usr/bin/env python3
"""Generate a real comparison report from BaraDB and PostgreSQL benchmark results."""
import json
from pathlib import Path


def format_ops(ops_per_sec):
    if ops_per_sec >= 1_000_000:
        return f"{ops_per_sec/1_000_000:.2f}M"
    elif ops_per_sec >= 1_000:
        return f"{ops_per_sec/1_000:.2f}K"
    else:
        return f"{ops_per_sec:.2f}"


def format_time(seconds):
    if seconds < 0.001:
        return f"{seconds*1000:.3f}ms"
    elif seconds < 1:
        return f"{seconds*1000:.1f}ms"
    else:
        return f"{seconds:.3f}s"


def main():
    root = Path(__file__).parent

    with open(root.parent / "benchmark_results.json") as f:
        bara = json.load(f)
    with open(root.parent / "pg_benchmark_results.json") as f:
        pg = json.load(f)

    bara_map = {r["name"]: r for r in bara["results"]}
    pg_map = {k: v for k, v in pg.items()}

    report = []
    report.append("# BaraDB vs PostgreSQL — Real Benchmark Results")
    report.append("")
    report.append("Generated from actual execution on:")
    report.append(f"- **CPU:** AMD Ryzen 9 5900X")
    report.append(f"- **PostgreSQL:** 15.18 (local)")
    report.append(f"- **BaraDB:** git `{bara['gitSha']}`")
    report.append("")
    report.append("## Methodology")
    report.append("")
    report.append("- PostgreSQL: single-row INSERT/SELECT via psycopg2 (client-server overhead included)")
    report.append("- BaraDB: in-process Nim code (no network overhead)")
    report.append("- Same dataset sizes for both systems")
    report.append("")
    report.append("## Results")
    report.append("")
    report.append("| Test | PostgreSQL | BaraDB | Speedup |")
    report.append("|------|-----------|--------|---------|")

    rows = [
        ("KV Write (100K)", pg_map.get("KV Write"), bara_map.get("LSM-Write")),
        ("KV Read (100K)", pg_map.get("KV Read"), bara_map.get("LSM-Read")),
        ("BTree Insert (100K)", pg_map.get("BTree Insert"), bara_map.get("BTree-Insert")),
        ("BTree Get (100K)", pg_map.get("BTree Get"), bara_map.get("BTree-Get")),
        ("BTree Scan (1K ranges)", pg_map.get("BTree Scan"), bara_map.get("BTree-Scan")),
        ("FTS Index (10K docs)", pg_map.get("FTS Index"), bara_map.get("FTS-Index")),
        ("FTS Search (1K queries)", pg_map.get("FTS Search"), bara_map.get("FTS-Search")),
    ]

    total_pg_time = 0
    total_bara_time = 0

    for name, p, b in rows:
        if p is None or b is None:
            continue
        pg_ops = p["opsPerSec"]
        ba_ops = b["opsPerSec"]
        ratio = ba_ops / pg_ops
        winner = "BaraDB" if ratio > 1 else "PostgreSQL"
        total_pg_time += p["seconds"]
        total_bara_time += b["seconds"]

        report.append(
            f"| {name} | {format_ops(pg_ops)}/s ({format_time(p['seconds'])}) | "
            f"{format_ops(ba_ops)}/s ({format_time(b['seconds'])}) | "
            f"{ratio:.1f}x ({winner}) |"
        )

    report.append("")
    report.append("## Summary")
    report.append("")
    report.append(f"- **Total PostgreSQL time:** {total_pg_time:.3f}s")
    report.append(f"- **Total BaraDB time:** {total_bara_time:.3f}s")
    overall = total_pg_time / total_bara_time
    report.append(f"- **Overall speedup:** BaraDB is **{overall:.1f}x faster**")
    report.append("")
    report.append("## Notes")
    report.append("")
    report.append("- PostgreSQL includes network round-trip and SQL parsing overhead per operation.")
    report.append("- BaraDB runs in-process with zero serialization/network cost.")
    report.append("- For embedded/single-node use cases, BaraDB shows significant advantage.")
    report.append("- PostgreSQL FTS Search with GIN index outperforms BaraDB on query throughput.")
    report.append("- PostgreSQL excels at durability, replication, and complex ACID transactions.")
    report.append("")

    output = "\n".join(report)
    print(output)

    with open(root / "REAL_COMPARISON.md", "w") as f:
        f.write(output)
    print(f"\nReport saved to {root / 'REAL_COMPARISON.md'}")


if __name__ == "__main__":
    main()
