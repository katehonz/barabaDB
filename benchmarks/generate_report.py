#!/usr/bin/env python3
"""Generate benchmark reports.

Modes:
  python3 benchmarks/generate_report.py           # legacy PG vs embedded (with warning)
  python3 benchmarks/generate_report.py --fair    # multi-tier fair report from fair_bench.py
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def format_ops(ops_per_sec: float) -> str:
    if ops_per_sec >= 1_000_000:
        return f"{ops_per_sec/1_000_000:.2f}M"
    if ops_per_sec >= 1_000:
        return f"{ops_per_sec/1_000:.2f}K"
    return f"{ops_per_sec:.2f}"


def format_time(seconds: float) -> str:
    if seconds < 0.001:
        return f"{seconds*1000:.3f}ms"
    if seconds < 1:
        return f"{seconds*1000:.1f}ms"
    return f"{seconds:.3f}s"


def gen_fair(out: Path) -> int:
    fair_path = ROOT / "fair_benchmark_results.json"
    if not fair_path.exists():
        print("Missing fair_benchmark_results.json — run: python3 benchmarks/fair_bench.py")
        return 1
    payload = json.loads(fair_path.read_text())
    # fair_bench already writes FAIR_COMPARISON.md; re-emit for consistency
    sys.path.insert(0, str(ROOT / "benchmarks"))
    from fair_bench import write_markdown  # type: ignore

    write_markdown(payload, out)
    return 0


def gen_legacy() -> int:
    """Legacy report: PG client-server vs BaraDB *embedded* — always labeled unfair."""
    bara_path = ROOT / "benchmark_results.json"
    pg_path = ROOT / "pg_benchmark_results.json"
    if not bara_path.exists() or not pg_path.exists():
        print("Need benchmark_results.json and pg_benchmark_results.json")
        print("  nimble bench && python3 benchmarks/pg_bench.py")
        return 1

    with open(bara_path) as f:
        bara = json.load(f)
    with open(pg_path) as f:
        pg = json.load(f)

    bara_map = {r["name"]: r for r in bara["results"]}
    # pg_bench may write list or dict
    if isinstance(pg, dict) and "results" in pg:
        pg_map = {r["name"]: r for r in pg["results"]}
    elif isinstance(pg, list):
        pg_map = {r["name"]: r for r in pg}
    else:
        pg_map = pg  # old flat dict by name

    report = []
    report.append("# BaraDB vs PostgreSQL — LEGACY (mixed tiers)")
    report.append("")
    report.append("> ⚠️ **Unfair comparison warning**")
    report.append(">")
    report.append("> PostgreSQL numbers include **client-server** round-trips.")
    report.append("> BaraDB numbers are **in-process embedded** LSM (no network, no SQL).")
    report.append("> Use `python3 benchmarks/fair_bench.py` + `--fair` for honest tiers.")
    report.append("")
    report.append(f"- **BaraDB git:** `{bara.get('gitSha', 'unknown')}`")
    report.append("")
    report.append("| Test | PostgreSQL (C/S) | BaraDB (embedded) | Ratio (not a fair speedup) |")
    report.append("|------|------------------|-------------------|----------------------------|")

    rows = [
        ("KV Write", pg_map.get("KV Write"), bara_map.get("LSM-Write")),
        ("KV Read", pg_map.get("KV Read"), bara_map.get("LSM-Read")),
        ("BTree Insert", pg_map.get("BTree Insert"), bara_map.get("BTree-Insert")),
        ("BTree Get", pg_map.get("BTree Get"), bara_map.get("BTree-Get")),
        ("BTree Scan", pg_map.get("BTree Scan"), bara_map.get("BTree-Scan")),
        ("FTS Index", pg_map.get("FTS Index"), bara_map.get("FTS-Index")),
        ("FTS Search", pg_map.get("FTS Search"), bara_map.get("FTS-Search")),
    ]

    for name, p, b in rows:
        if p is None or b is None:
            continue
        pg_ops = p["opsPerSec"]
        ba_ops = b["opsPerSec"]
        ratio = ba_ops / pg_ops if pg_ops else 0
        report.append(
            f"| {name} | {format_ops(pg_ops)}/s ({format_time(p['seconds'])}) | "
            f"{format_ops(ba_ops)}/s ({format_time(b['seconds'])}) | "
            f"{ratio:.1f}x (mixed tiers) |"
        )

    report.append("")
    report.append("## Prefer fair suite")
    report.append("")
    report.append("```bash")
    report.append("nim c -d:release -r benchmarks/bench_all.nim")
    report.append("python3 benchmarks/fair_bench.py")
    report.append("python3 benchmarks/generate_report.py --fair")
    report.append("```")
    report.append("")

    out = ROOT / "benchmarks" / "REAL_COMPARISON.md"
    out.write_text("\n".join(report) + "\n")
    print(f"Wrote {out} (legacy mixed-tier; see warning banner)")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--fair",
        action="store_true",
        help="Emit multi-tier fair report from fair_benchmark_results.json",
    )
    ap.add_argument(
        "-o",
        "--output",
        default=str(ROOT / "benchmarks" / "FAIR_COMPARISON.md"),
        help="Output path for --fair mode",
    )
    args = ap.parse_args()
    if args.fair:
        return gen_fair(Path(args.output))
    return gen_legacy()


if __name__ == "__main__":
    sys.exit(main())
