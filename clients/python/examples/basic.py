#!/usr/bin/env python3
"""
BaraDB Python Client — Basic Examples

This script demonstrates common operations with the BaraDB Python client.
Run it while a BaraDB server is listening on localhost:9472.
"""

import asyncio
import sys

from baradb import Client, QueryBuilder, WireValue


async def example_connection():
    print("=== Connection ===")
    client = Client("localhost", 9472)
    await client.connect()
    print(f"Connected: {client.is_connected()}")
    print(f"Ping: {await client.ping()}")
    await client.close()
    print(f"Connected after close: {client.is_connected()}")
    print()


async def example_context_manager():
    print("=== Context Manager ===")
    async with Client("localhost", 9472) as client:
        print(f"Inside context: {client.is_connected()}")
        print(f"Ping: {await client.ping()}")
    print("Outside context: closed automatically")
    print()


async def example_simple_query():
    print("=== Simple Query ===")
    async with Client("localhost", 9472) as client:
        result = await client.query("SELECT 42 as answer, 'BaraDB' as db")
        print(f"Columns: {result.columns}")
        print(f"Rows: {result.rows}")
        print(f"Row count: {result.row_count}")
        for row in result:
            print(f"  answer={row['answer']}, db={row['db']}")
    print()


async def example_parameterized_query():
    print("=== Parameterized Query ===")
    async with Client("localhost", 9472) as client:
        result = await client.query_params(
            "SELECT $1 as num, $2 as txt, $3 as flag",
            [
                WireValue.int64(123),
                WireValue.string("hello world"),
                WireValue.bool(True),
            ],
        )
        for row in result:
            print(f"  num={row['num']}, txt={row['txt']}, flag={row['flag']}")
    print()


async def example_query_builder():
    print("=== Query Builder ===")
    async with Client("localhost", 9472) as client:
        sql = (
            QueryBuilder(client)
            .select("id", "name")
            .from_("users")
            .where("active = true")
            .order_by("name", "ASC")
            .limit(5)
            .build()
        )
        print(f"Generated SQL: {sql}")
    print()


async def example_vector():
    print("=== Vector Value ===")
    async with Client("localhost", 9472) as client:
        result = await client.query_params(
            "SELECT $1 as embedding",
            [WireValue.vector([0.1, 0.2, 0.3, 0.4])],
        )
        for row in result:
            print(f"  embedding type: {type(row['embedding'])}")
    print()


async def example_ddl_dml():
    print("=== DDL & DML ===")
    async with Client("localhost", 9472) as client:
        # Clean up
        try:
            await client.execute("DROP TABLE IF EXISTS demo_products")
        except Exception as exc:
            print(f"Cleanup warning: {exc}")

        await client.execute(
            "CREATE TABLE demo_products (id INT PRIMARY KEY, name STRING, price FLOAT)"
        )
        affected = await client.execute(
            "INSERT INTO demo_products (id, name, price) VALUES (1, 'Widget', 9.99)"
        )
        print(f"Insert affected rows: {affected}")

        result = await client.query("SELECT * FROM demo_products")
        print(f"Select returned {result.row_count} row(s)")
        for row in result:
            print(f"  {row}")

        await client.execute("DROP TABLE demo_products")
        print("Table dropped")
    print()


async def main():
    print("BaraDB Python Client Examples")
    print("Make sure BaraDB is running on localhost:9472")
    print()

    examples = [
        example_connection,
        example_context_manager,
        example_simple_query,
        example_parameterized_query,
        example_query_builder,
        example_vector,
        example_ddl_dml,
    ]

    for fn in examples:
        try:
            await fn()
        except Exception as exc:
            print(f"ERROR in {fn.__name__}: {exc}", file=sys.stderr)


if __name__ == "__main__":
    asyncio.run(main())
