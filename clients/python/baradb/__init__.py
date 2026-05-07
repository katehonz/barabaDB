"""
BaraDB Python Client

Official Python client for BaraDB — Multimodal Database Engine.
Communicates via the BaraDB Wire Protocol (binary, big-endian, TCP).

Install:
    pip install baradb

Quick Start:
    from baradb import Client
    client = Client("localhost", 9472)
    client.connect()
    result = client.query("SELECT name FROM users WHERE age > 18")
    for row in result:
        print(row["name"])
    client.close()
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

__version__ = "1.0.0"
__all__ = [
    "Client",
    "QueryBuilder",
    "QueryResult",
    "WireValue",
    "MsgKind",
    "FieldKind",
    "ResultFormat",
]
