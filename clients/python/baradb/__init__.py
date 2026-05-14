"""
BaraDB Python Async Client

Official async Python client for BaraDB — Multimodal Database Engine.
Communicates via the BaraDB Wire Protocol (binary, big-endian, TCP).

Install:
    pip install baradb

Quick Start:
    import asyncio
    from baradb import Client

    async def main():
        client = Client("localhost", 9472)
        await client.connect()
        result = await client.query("SELECT name FROM users WHERE age > 18")
        for row in result:
            print(row["name"])
        await client.close()

    asyncio.run(main())

Parameterized Queries:
    result = await client.query_params(
        "SELECT * FROM users WHERE age > $1",
        [WireValue.int64(18)]
    )

Authentication:
    await client.auth("jwt-token-here")
"""

from .core import (
    Client,
    QueryBuilder,
    QueryResult,
    WireValue,
    MsgKind,
    FieldKind,
    ResultFormat,
)

__version__ = "1.1.0"
__all__ = [
    "Client",
    "QueryBuilder",
    "QueryResult",
    "WireValue",
    "MsgKind",
    "FieldKind",
    "ResultFormat",
]