#!/usr/bin/env python3
"""
Fair multi-tier benchmarks for BaraDB.

Tiers (never mix across tiers in a single "speedup" claim):

  1. embedded     — in-process storage (BaraDB LSM from JSON, SQLite)
  2. client_server — network + SQL
       • BaraDB HTTP REST
       • BaraDB wire protocol (Python async client, TCP 9472)
       • PostgreSQL (psycopg2)

  Within each tier we measure both **row-at-a-time** and **batch multi-row INSERT**.

Usage:
  # 1) optional: run BaraDB embedded micro-benches first
  nim c -d:release -r benchmarks/bench_all.nim

  # 2) start server for HTTP/wire tiers (optional)
  ./build/baradadb

  # 3) fair suite
  python3 benchmarks/fair_bench.py

  # 4) markdown report
  python3 benchmarks/generate_report.py --fair

Env:
  BARADB_HTTP_HOST   default 127.0.0.1
  BARADB_HTTP_PORT   default 9912  (TCP 9472 + 440)
  BARADB_WIRE_HOST   default 127.0.0.1
  BARADB_WIRE_PORT   default 9472
  PGHOST / PGPORT / PGDATABASE / PGUSER / PGPASSWORD
  FAIR_N_KV          default 20000
  FAIR_N_SQL         default 5000
  FAIR_BATCH         default 100   (rows per multi-row INSERT)
  FAIR_SKIP_PG=1     skip PostgreSQL
  FAIR_SKIP_HTTP=1   skip BaraDB HTTP
  FAIR_SKIP_WIRE=1   skip BaraDB wire protocol
"""
from __future__ import annotations

import asyncio
import json
import os
import sqlite3
import sys
import tempfile
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT_JSON = ROOT / "fair_benchmark_results.json"
BARA_JSON = ROOT / "benchmark_results.json"
CLIENTS_PY = ROOT / "clients" / "python"

N_KV = int(os.environ.get("FAIR_N_KV", "20000"))
N_SQL = int(os.environ.get("FAIR_N_SQL", "5000"))
BATCH = int(os.environ.get("FAIR_BATCH", "100"))
HTTP_HOST = os.environ.get("BARADB_HTTP_HOST", "127.0.0.1")
HTTP_PORT = int(os.environ.get("BARADB_HTTP_PORT", "9912"))
WIRE_HOST = os.environ.get("BARADB_WIRE_HOST", "127.0.0.1")
WIRE_PORT = int(os.environ.get("BARADB_WIRE_PORT", "9472"))


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")


def result(name: str, system: str, tier: str, ops: int, seconds: float, **extra):
    ops_s = ops / seconds if seconds > 0 else 0.0
    r = {
        "name": name,
        "system": system,
        "tier": tier,
        "ops": ops,
        "seconds": seconds,
        "opsPerSec": ops_s,
        "timestamp": now_iso(),
    }
    r.update(extra)
    return r


def fmt_ops(x: float) -> str:
    if x >= 1_000_000:
        return f"{x/1_000_000:.2f}M"
    if x >= 1_000:
        return f"{x/1_000:.2f}K"
    return f"{x:.2f}"


# ─── Tier 1: Embedded ───────────────────────────────────────────────


def load_baradb_embedded() -> list[dict]:
    """Map bench_all.nim LSM results into fair embedded tier."""
    if not BARA_JSON.exists():
        print("  [skip] benchmark_results.json missing — run: nimble bench")
        return []
    data = json.loads(BARA_JSON.read_text())
    name_map = {
        "LSM-Write": "kv_write",
        "LSM-Read": "kv_read",
        "WAL-none": "wal_none",
        "WAL-group64": "wal_group64",
        "WAL-group256": "wal_group256",
        "WAL-every": "wal_every",
    }
    out = []
    for r in data.get("results", []):
        mapped = name_map.get(r.get("name"))
        if not mapped:
            continue
        out.append(
            result(
                mapped,
                "baradb_lsm_embedded",
                "embedded",
                r.get("ops", 0),
                r.get("seconds", 0.0),
                source="benchmark_results.json",
                gitSha=data.get("gitSha", ""),
            )
        )
    return out


def multi_values_sql(start: int, count: int) -> str:
    """Build VALUES (...),(...),... for multi-row INSERT."""
    parts = [f"({i}, 'value_{i}')" for i in range(start, start + count)]
    return ",".join(parts)


def bench_sqlite_embedded(n: int = N_KV) -> list[dict]:
    """SQLite in-process — fair peer for BaraDB embedded LSM."""
    out = []
    fd, path = tempfile.mkstemp(suffix=".db")
    os.close(fd)
    os.unlink(path)

    # --- durability: FULL (fsync) vs OFF ---
    for mode, label in (("OFF", "sqlite_off"), ("FULL", "sqlite_full")):
        if os.path.exists(path):
            os.unlink(path)
        conn = sqlite3.connect(path)
        cur = conn.cursor()
        cur.execute(f"PRAGMA synchronous = {mode}")
        cur.execute("PRAGMA journal_mode = WAL")
        cur.execute("CREATE TABLE kv (k TEXT PRIMARY KEY, v TEXT)")
        conn.commit()

        t0 = time.perf_counter()
        for i in range(n):
            cur.execute("INSERT INTO kv(k,v) VALUES(?,?)", (f"key_{i}", f"value_{i}"))
        conn.commit()
        w = time.perf_counter() - t0
        out.append(
            result(
                "kv_write",
                label,
                "embedded",
                n,
                w,
                durable=mode == "FULL",
                note=f"PRAGMA synchronous={mode}",
            )
        )

        t0 = time.perf_counter()
        found = 0
        for i in range(n):
            cur.execute("SELECT v FROM kv WHERE k=?", (f"key_{i}",))
            if cur.fetchone():
                found += 1
        r = time.perf_counter() - t0
        out.append(
            result(
                "kv_read",
                label,
                "embedded",
                n,
                r,
                found=found,
                durable=mode == "FULL",
            )
        )

        # Batch multi-row INSERT into SQL table (embedded SQL peer for batch)
        cur.execute("DROP TABLE IF EXISTS fair_batch")
        cur.execute("CREATE TABLE fair_batch (id INTEGER PRIMARY KEY, v TEXT)")
        conn.commit()
        t0 = time.perf_counter()
        for start in range(0, n, BATCH):
            cnt = min(BATCH, n - start)
            vals = multi_values_sql(start, cnt)
            cur.execute(f"INSERT INTO fair_batch (id, v) VALUES {vals}")
        conn.commit()
        bw = time.perf_counter() - t0
        out.append(
            result(
                "sql_insert_batch",
                label,
                "embedded",
                n,
                bw,
                batch=BATCH,
                durable=mode == "FULL",
                note=f"multi-row INSERT batch={BATCH}, sync={mode}",
            )
        )
        conn.close()

    if os.path.exists(path):
        os.unlink(path)
    return out


# ─── Tier 2: Client / server ────────────────────────────────────────


def bara_http_query(sql: str, host: str = HTTP_HOST, port: int = HTTP_PORT) -> dict:
    body = json.dumps({"query": sql}).encode()
    req = urllib.request.Request(
        f"http://{host}:{port}/query",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.loads(resp.read().decode())


def bara_http_available() -> bool:
    try:
        body = json.dumps({"query": "SELECT 1"}).encode()
        # health endpoint preferred
        req = urllib.request.Request(f"http://{HTTP_HOST}:{HTTP_PORT}/health", method="GET")
        with urllib.request.urlopen(req, timeout=2) as resp:
            return resp.status == 200
    except Exception:
        try:
            bara_http_query("SELECT 1")
            return True
        except Exception:
            return False


def bench_baradb_http(n: int = N_SQL) -> list[dict]:
    if os.environ.get("FAIR_SKIP_HTTP") == "1":
        print("  [skip] FAIR_SKIP_HTTP=1")
        return []
    if not bara_http_available():
        print(
            f"  [skip] BaraDB HTTP not reachable at {HTTP_HOST}:{HTTP_PORT} "
            f"(start: ./build/baradadb)"
        )
        return []

    out = []
    ep = f"http://{HTTP_HOST}:{HTTP_PORT}/query"
    # BaraDB parser may not support IF EXISTS — ignore DROP failures
    try:
        bara_http_query("DROP TABLE fair_bench")
    except Exception:
        pass
    try:
        bara_http_query("CREATE TABLE fair_bench (id INT PRIMARY KEY, v TEXT)")
    except Exception as e:
        print(f"  [warn] setup query failed: {e}")

    # Row-at-a-time INSERT
    t0 = time.perf_counter()
    errors = 0
    for i in range(n):
        try:
            r = bara_http_query(
                f"INSERT INTO fair_bench (id, v) VALUES ({i}, 'value_{i}')"
            )
            if isinstance(r, dict) and r.get("error"):
                errors += 1
        except Exception:
            errors += 1
    w = time.perf_counter() - t0
    out.append(
        result(
            "sql_insert_row",
            "baradb_http",
            "client_server",
            n,
            w,
            errors=errors,
            endpoint=ep,
        )
    )

    # Point SELECT
    t0 = time.perf_counter()
    found = 0
    for i in range(n):
        try:
            r = bara_http_query(f"SELECT v FROM fair_bench WHERE id = {i}")
            rows = r.get("rows") if isinstance(r, dict) else None
            if rows:
                found += 1
        except Exception:
            pass
    rd = time.perf_counter() - t0
    out.append(
        result(
            "sql_select_row",
            "baradb_http",
            "client_server",
            n,
            rd,
            found=found,
            endpoint=ep,
        )
    )

    # Multi-row batch INSERT
    try:
        try:
            bara_http_query("DROP TABLE fair_batch")
        except Exception:
            pass
        bara_http_query("CREATE TABLE fair_batch (id INT PRIMARY KEY, v TEXT)")
    except Exception as e:
        print(f"  [warn] batch setup failed: {e}")
        return out

    t0 = time.perf_counter()
    berr = 0
    for start in range(0, n, BATCH):
        cnt = min(BATCH, n - start)
        sql = f"INSERT INTO fair_batch (id, v) VALUES {multi_values_sql(start, cnt)}"
        try:
            r = bara_http_query(sql)
            if isinstance(r, dict) and r.get("error"):
                berr += 1
        except Exception:
            berr += 1
    bw = time.perf_counter() - t0
    out.append(
        result(
            "sql_insert_batch",
            "baradb_http",
            "client_server",
            n,
            bw,
            batch=BATCH,
            errors=berr,
            endpoint=ep,
            note=f"multi-row INSERT batch={BATCH}",
        )
    )
    return out


def _import_baradb_client():
    """Load clients/python baradb package without requiring install."""
    p = str(CLIENTS_PY)
    if p not in sys.path:
        sys.path.insert(0, p)
    from baradb import Client  # type: ignore

    return Client


def bara_wire_available() -> bool:
    if os.environ.get("FAIR_SKIP_WIRE") == "1":
        return False
    try:
        Client = _import_baradb_client()
    except Exception as e:
        print(f"  [skip] wire client import failed: {e}")
        return False

    async def _ping():
        c = Client(WIRE_HOST, WIRE_PORT, timeout=2.0)
        try:
            await c.connect()
            await c.ping()
            await c.close()
            return True
        except Exception:
            try:
                await c.close()
            except Exception:
                pass
            return False

    try:
        return asyncio.run(_ping())
    except Exception:
        return False


def bench_baradb_wire(n: int = N_SQL) -> list[dict]:
    """BaraDB binary wire protocol (TCP) — primary high-performance client path."""
    if os.environ.get("FAIR_SKIP_WIRE") == "1":
        print("  [skip] FAIR_SKIP_WIRE=1")
        return []
    try:
        Client = _import_baradb_client()
    except Exception as e:
        print(f"  [skip] wire client not available: {e}")
        return []

    if not bara_wire_available():
        print(
            f"  [skip] BaraDB wire not reachable at {WIRE_HOST}:{WIRE_PORT} "
            f"(start: ./build/baradadb)"
        )
        return []

    async def _run() -> list[dict]:
        out: list[dict] = []
        client = Client(WIRE_HOST, WIRE_PORT, timeout=60.0)
        await client.connect()
        try:
            try:
                await client.query("DROP TABLE fair_wire")
            except Exception:
                pass
            try:
                await client.query(
                    "CREATE TABLE fair_wire (id INT PRIMARY KEY, v TEXT)"
                )
            except Exception as e:
                print(f"  [warn] wire setup: {e}")

            ep = f"tcp://{WIRE_HOST}:{WIRE_PORT}"
            # Row-at-a-time INSERT (may crash older servers under load — record partial)
            t0 = time.perf_counter()
            errors = 0
            done = 0
            crashed = False
            for i in range(n):
                try:
                    await client.query(
                        f"INSERT INTO fair_wire (id, v) VALUES ({i}, 'value_{i}')"
                    )
                    done += 1
                except (ConnectionError, OSError, Exception) as e:
                    errors += 1
                    if "reset" in str(e).lower() or "closed" in str(e).lower():
                        crashed = True
                        print(f"  [warn] wire connection lost after {done} inserts: {e}")
                        break
            w = time.perf_counter() - t0
            if done > 0:
                out.append(
                    result(
                        "sql_insert_row",
                        "baradb_wire",
                        "client_server",
                        done,
                        w,
                        errors=errors,
                        requested=n,
                        endpoint=ep,
                        note="binary wire protocol"
                        + (" (partial — server disconnect)" if crashed else ""),
                    )
                )

            if crashed:
                return out

            # Point SELECT
            t0 = time.perf_counter()
            found = 0
            for i in range(done):
                try:
                    r = await client.query(
                        f"SELECT v FROM fair_wire WHERE id = {i}"
                    )
                    if r is not None and (
                        getattr(r, "row_count", 0) > 0 or getattr(r, "rows", None)
                    ):
                        found += 1
                except (ConnectionError, OSError, Exception) as e:
                    if "reset" in str(e).lower() or "closed" in str(e).lower():
                        crashed = True
                        print(f"  [warn] wire lost during SELECT: {e}")
                        break
            rd = time.perf_counter() - t0
            out.append(
                result(
                    "sql_select_row",
                    "baradb_wire",
                    "client_server",
                    max(done, 1),
                    rd,
                    found=found,
                    endpoint=ep,
                )
            )
            if crashed:
                return out

            # Batch multi-row INSERT
            try:
                try:
                    await client.query("DROP TABLE fair_wire_batch")
                except Exception:
                    pass
                await client.query(
                    "CREATE TABLE fair_wire_batch (id INT PRIMARY KEY, v TEXT)"
                )
            except Exception as e:
                print(f"  [warn] wire batch setup: {e}")
                return out

            t0 = time.perf_counter()
            berr = 0
            bdone = 0
            for start in range(0, n, BATCH):
                cnt = min(BATCH, n - start)
                sql = (
                    "INSERT INTO fair_wire_batch (id, v) VALUES "
                    + multi_values_sql(start, cnt)
                )
                try:
                    await client.query(sql)
                    bdone += cnt
                except (ConnectionError, OSError, Exception) as e:
                    berr += 1
                    if "reset" in str(e).lower() or "closed" in str(e).lower():
                        print(f"  [warn] wire lost during batch after {bdone} rows: {e}")
                        break
            bw = time.perf_counter() - t0
            if bdone > 0:
                out.append(
                    result(
                        "sql_insert_batch",
                        "baradb_wire",
                        "client_server",
                        bdone,
                        bw,
                        batch=BATCH,
                        errors=berr,
                        requested=n,
                        endpoint=ep,
                        note=f"multi-row INSERT batch={BATCH}",
                    )
                )
        finally:
            try:
                await client.close()
            except Exception:
                pass
        return out

    try:
        return asyncio.run(_run())
    except Exception as e:
        print(f"  [skip] wire bench failed: {e}")
        return []


def bench_postgresql(n: int = N_SQL) -> list[dict]:
    if os.environ.get("FAIR_SKIP_PG") == "1":
        print("  [skip] FAIR_SKIP_PG=1")
        return []
    try:
        import psycopg2
    except ImportError:
        print("  [skip] psycopg2 not installed")
        return []

    cfg = {
        "host": os.environ.get("PGHOST", "localhost"),
        "port": int(os.environ.get("PGPORT", "5432")),
        "dbname": os.environ.get("PGDATABASE", "postgres"),
        "user": os.environ.get("PGUSER", "postgres"),
        "password": os.environ.get("PGPASSWORD", os.environ.get("PG_PASSWORD", "")),
    }
    if not cfg["password"] and os.environ.get("PGPASSWORD") is None:
        cfg["password"] = os.environ.get("BARA_PG_PASSWORD", "pas+123")

    out = []
    try:
        conn = psycopg2.connect(**cfg)
    except Exception as e:
        print(f"  [skip] PostgreSQL connect failed: {e}")
        return []

    cur = conn.cursor()
    for sync, label in (("on", "postgresql_sync_on"), ("off", "postgresql_sync_off")):
        cur.execute(f"SET synchronous_commit = {sync}")
        cur.execute("DROP TABLE IF EXISTS fair_bench")
        cur.execute("CREATE TABLE fair_bench (id INTEGER PRIMARY KEY, v TEXT)")
        conn.commit()

        t0 = time.perf_counter()
        for i in range(n):
            cur.execute(
                "INSERT INTO fair_bench (id, v) VALUES (%s, %s)",
                (i, f"value_{i}"),
            )
        conn.commit()
        w = time.perf_counter() - t0
        out.append(
            result(
                "sql_insert_row",
                label,
                "client_server",
                n,
                w,
                durable=sync == "on",
                note=f"synchronous_commit={sync}",
            )
        )

        t0 = time.perf_counter()
        found = 0
        for i in range(n):
            cur.execute("SELECT v FROM fair_bench WHERE id = %s", (i,))
            if cur.fetchone():
                found += 1
        rd = time.perf_counter() - t0
        out.append(
            result(
                "sql_select_row",
                label,
                "client_server",
                n,
                rd,
                found=found,
                durable=sync == "on",
            )
        )

        # Batch multi-row INSERT (same durability setting)
        cur.execute("DROP TABLE IF EXISTS fair_batch")
        cur.execute("CREATE TABLE fair_batch (id INTEGER PRIMARY KEY, v TEXT)")
        conn.commit()
        t0 = time.perf_counter()
        for start in range(0, n, BATCH):
            cnt = min(BATCH, n - start)
            cur.execute(
                f"INSERT INTO fair_batch (id, v) VALUES {multi_values_sql(start, cnt)}"
            )
        conn.commit()
        bw = time.perf_counter() - t0
        out.append(
            result(
                "sql_insert_batch",
                label,
                "client_server",
                n,
                bw,
                batch=BATCH,
                durable=sync == "on",
                note=f"multi-row INSERT batch={BATCH}, sync={sync}",
            )
        )

    cur.close()
    conn.close()
    return out


# ─── Report ──────────────────────────────────────────────────────────


def print_tier(name: str, rows: list[dict]):
    print(f"\n=== Tier: {name} ===")
    if not rows:
        print("  (no results)")
        return
    # group by bench name
    names = []
    for r in rows:
        if r["name"] not in names:
            names.append(r["name"])
    for nm in names:
        print(f"  [{nm}]")
        for r in rows:
            if r["name"] != nm:
                continue
            print(
                f"    {r['system']:28s}  {fmt_ops(r['opsPerSec']):>10s}/s  "
                f"({r['seconds']:.3f}s, n={r['ops']})"
            )


def write_markdown(payload: dict, path: Path):
    lines = []
    lines.append("# Fair Benchmark Results")
    lines.append("")
    lines.append(f"Generated: **{payload.get('generated', '')}**")
    lines.append("")
    lines.append("## Methodology")
    lines.append("")
    for line in payload.get("methodology", []):
        lines.append(f"- {line}")
    lines.append("")
    lines.append("**Do not compare numbers across tiers.** Embedded storage is not the same")
    lines.append("workload as client-server SQL over the network.")
    lines.append("")

    for tier in ("embedded", "client_server"):
        rows = [r for r in payload.get("results", []) if r.get("tier") == tier]
        lines.append(f"## Tier: `{tier}`")
        lines.append("")
        if not rows:
            lines.append("_No results for this tier._")
            lines.append("")
            continue
        lines.append("| Bench | System | ops/s | seconds | n | notes |")
        lines.append("|-------|--------|------:|--------:|--:|-------|")
        for r in rows:
            note = r.get("note") or r.get("source") or ""
            lines.append(
                f"| {r['name']} | `{r['system']}` | {fmt_ops(r['opsPerSec'])} | "
                f"{r['seconds']:.3f} | {r['ops']} | {note} |"
            )
        lines.append("")

        # same-bench comparison within tier
        names = sorted({r["name"] for r in rows})
        lines.append(f"### Same-bench ratios (`{tier}`)")
        lines.append("")
        for nm in names:
            group = [r for r in rows if r["name"] == nm]
            if len(group) < 2:
                continue
            best = max(group, key=lambda x: x["opsPerSec"])
            lines.append(f"**{nm}** (fastest: `{best['system']}` @ {fmt_ops(best['opsPerSec'])}/s)")
            lines.append("")
            lines.append("| System | Relative to fastest |")
            lines.append("|--------|--------------------:|")
            for r in sorted(group, key=lambda x: -x["opsPerSec"]):
                rel = r["opsPerSec"] / best["opsPerSec"] if best["opsPerSec"] else 0
                lines.append(f"| `{r['system']}` | {rel:.2f}x |")
            lines.append("")

    path.write_text("\n".join(lines) + "\n")
    print(f"\nMarkdown written to {path}")


def main():
    print("BaraDB Fair Benchmark Suite")
    print(f"  N_KV={N_KV}  N_SQL={N_SQL}  BATCH={BATCH}")
    print(f"  HTTP={HTTP_HOST}:{HTTP_PORT}  WIRE={WIRE_HOST}:{WIRE_PORT}")

    methodology = [
        "Tier `embedded`: in-process only (BaraDB LSM from nimble bench JSON; SQLite via Python sqlite3).",
        "Tier `client_server`: network SQL (BaraDB HTTP /query; BaraDB binary wire TCP; PostgreSQL via psycopg2).",
        "`sql_insert_row`: one INSERT statement per row (chatty).",
        f"`sql_insert_batch`: multi-row INSERT with batch size {BATCH} (same SQL style across systems).",
        "PostgreSQL: synchronous_commit=on|off; SQLite: PRAGMA synchronous FULL|OFF.",
        "BaraDB WAL modes appear only if you ran benchmarks/bench_all.nim (WAL-* rows).",
        "Never claim 'Nx faster than Postgres' using embedded BaraDB numbers.",
    ]

    results: list[dict] = []

    print("\n--- Embedded tier ---")
    results.extend(load_baradb_embedded())
    print("  SQLite embedded (+ batch)…")
    results.extend(bench_sqlite_embedded())

    print("\n--- Client/server tier ---")
    print("  BaraDB HTTP…")
    results.extend(bench_baradb_http())
    print("  BaraDB wire (TCP)…")
    results.extend(bench_baradb_wire())
    print("  PostgreSQL…")
    results.extend(bench_postgresql())

    payload = {
        "generated": now_iso(),
        "methodology": methodology,
        "config": {
            "N_KV": N_KV,
            "N_SQL": N_SQL,
            "HTTP": f"{HTTP_HOST}:{HTTP_PORT}",
        },
        "results": results,
    }
    OUT_JSON.write_text(json.dumps(payload, indent=2))
    print(f"\nJSON written to {OUT_JSON}")

    print_tier("embedded", [r for r in results if r["tier"] == "embedded"])
    print_tier("client_server", [r for r in results if r["tier"] == "client_server"])

    write_markdown(payload, ROOT / "benchmarks" / "FAIR_COMPARISON.md")
    return 0


if __name__ == "__main__":
    sys.exit(main())
