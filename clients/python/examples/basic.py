#!/usr/bin/env python3
"""
BaraDB Python Client — Basic Examples

This script demonstrates common operations with the BaraDB Python client.
Run it while a BaraDB server is listening on localhost:9472.
"""

import sys

from baradb import Client, QueryBuilder, WireValue


def example_connection():
    print("=== Connection ===")
    client = Client("localhost", 9472)
    client.connect()
    print(f"Connected: {client.is_connected()}")
    print(f"Ping: {client.ping()}")
    client.close()
    print(f"Connected after close: {client.is_connected()}")
    print()


def example_context_manager():
    print("=== Context Manager ===")
    with Client("localhost", 9472) as client:
        print(f"Inside context: {client.is_connected()}")
        print(f"Ping: {client.ping()}")
    print("Outside context: closed automatically")
    print()


def example_simple_query():
    print("=== Simple Query ===")
    with Client("localhost", 9472) as client:
        result = client.query("SELECT 42 as answer, 'BaraDB' as db")
        print(f"Columns: {result.columns}")
        print(f"Rows: {result.rows}")
        print(f"Row count: {result.row_count}")
        for row in result:
            print(f"  answer={row['answer']}, db={row['db']}")
    print()


def example_parameterized_query():
    print("=== Parameterized Query ===")
    with Client("localhost", 9472) as client:
        result = client.query_params(
            "SELECT $1 as num, $2 as txt, $3 as flag",
            [
                WireValue.int64(123),
                WireValue.string("hello world"),
                WireValue.bool_val(True),
            ],
        )
        for row in result:
            print(f"  num={row['num']}, txt={row['txt']}, flag={row['flag']}")
    print()


def example_query_builder():
    print("=== Query Builder ===")
    with Client("localhost", 9472) as client:
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


def example_vector():
    print("=== Vector Value ===")
    with Client("localhost", 9472) as client:
        result = client.query_params(
            "SELECT $1 as embedding",
            [WireValue.vector([0.1, 0.2, 0.3, 0.4])],
        )
        for row in result:
            print(f"  embedding type: {type(row['embedding'])}")
    print()


def example_ddl_dml():
    print("=== DDL & DML ===")
    with Client("localhost", 9472) as client:
        # Clean up
        try:
            client.execute("DROP TABLE IF EXISTS demo_products")
        except Exception as exc:
            print(f"Cleanup warning: {exc}")

        client.execute(
            "CREATE TABLE demo_products (id INT PRIMARY KEY, name STRING, price FLOAT)"
        )
        affected = client.execute(
            "INSERT INTO demo_products (id, name, price) VALUES (1, 'Widget', 9.99)"
        )
        print(f"Insert affected rows: {affected}")

        result = client.query("SELECT * FROM demo_products")
        print(f"Select returned {result.row_count} row(s)")
        for row in result:
            print(f"  {row}")

        client.execute("DROP TABLE demo_products")
        print("Table dropped")
    print()


def main():
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
            fn()
        except Exception as exc:
            print(f"ERROR in {fn.__name__}: {exc}", file=sys.stderr)


if __name__ == "__main__":
    main()
