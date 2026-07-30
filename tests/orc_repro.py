#!/usr/bin/env python3
"""Reproducer for the ORC cycle-collector crash (markGray/trace SIGSEGV).

Usage:
  1. Build the server with ORC:
       nim c -d:ssl --threads:on --path:src --mm:orc -o:/tmp/baradadb_orc src/baradadb.nim
  2. Start it:
       BARADB_PORT=39472 BARADB_DATA_DIR=/tmp/baradb_orc_data BARADB_LOG_LEVEL=error /tmp/baradadb_orc
  3. Run this script (from the repo root):
       python3 tests/orc_repro.py

Expected (as of 2026-07-30, Nim 2.2.10): the server dies with
  orc.nim markGray -> trace -> SIGSEGV
triggered from core/server.nim handleClient, and this script fails with
ConnectionResetError. Under ARC (the default in nim.cfg) the same load passes.

Bisect results: 200 pings + 200 SELECTs over TCP are fine; the crash lands
somewhere between 20 and 500 sequential INSERTs (INSERT path only).
Failed root-cause attempts: callback cycle breaks (ed5a719), {.cursor.} on
ExecutionContext.registry (the registry<->ctx cycle), guarding ctx.onChange
against zero WS subscribers. Conclusion: deep ORC+async issue (possibly
upstream Nim), not a single app-level cycle. ARC remains the supported MM.
"""

import asyncio
import sys

sys.path.insert(0, "clients/python")
from baradb import Client

PORT = 39472


async def worker(w: int) -> None:
    base = 1000 + w * 100
    async with Client("127.0.0.1", PORT) as c:
        for i in range(100):
            await c.query(f"INSERT INTO orc_stress (id, val) VALUES ({base + i}, 'v{base + i}')")


async def main() -> None:
    async with Client("127.0.0.1", PORT) as c:
        await c.query("CREATE TABLE orc_stress (id INT PRIMARY KEY, val STRING)")
        # Original report: SIGSEGV after ~20 sequential INSERTs under async load
        for i in range(1000):
            await c.query(f"INSERT INTO orc_stress (id, val) VALUES ({i}, 'x{i}')")
        r = await c.query("SELECT COUNT(*) AS n FROM orc_stress")
        print("after 1000 sequential INSERTs:", r.rows)
    await asyncio.gather(*[worker(w) for w in range(10)])
    async with Client("127.0.0.1", PORT) as c:
        r = await c.query("SELECT COUNT(*) AS n FROM orc_stress")
        print("final count:", r.rows)
        print("ping:", await c.ping())
    print("ORC STRESS OK")


asyncio.run(main())
