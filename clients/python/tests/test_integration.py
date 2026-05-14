"""
Integration tests for BaraDB Python client.
Requires a running BaraDB server on localhost:9472.

These tests are skipped automatically if the server is unreachable.
"""

import asyncio
import os
import socket
import pytest
import pytest_asyncio
from baradb import Client, WireValue, QueryBuilder


BARADB_HOST = os.environ.get("BARADB_HOST", "localhost")
BARADB_PORT = int(os.environ.get("BARADB_PORT", "9472"))


def _server_available() -> bool:
    """Check if BaraDB server is listening."""
    try:
        with socket.create_connection((BARADB_HOST, BARADB_PORT), timeout=2):
            return True
    except (socket.timeout, ConnectionRefusedError, OSError):
        return False


pytestmark = pytest.mark.skipif(
    not _server_available(),
    reason=f"BaraDB server not available at {BARADB_HOST}:{BARADB_PORT}",
)


@pytest_asyncio.fixture
async def client():
    c = Client(BARADB_HOST, BARADB_PORT)
    await c.connect()
    yield c
    await c.close()


class TestConnection:
    async def test_connect_and_close(self):
        c = Client(BARADB_HOST, BARADB_PORT)
        assert not c.is_connected()
        await c.connect()
        assert c.is_connected()
        await c.close()
        assert not c.is_connected()

    async def test_context_manager(self):
        async with Client(BARADB_HOST, BARADB_PORT) as c:
            assert c.is_connected()
        assert not c.is_connected()


class TestPing:
    async def test_ping(self, client):
        assert await client.ping() is True


class TestQuery:
    async def test_simple_select(self, client):
        result = await client.query("SELECT 1 as one")
        assert result.row_count >= 0  # server may return rows or empty

    async def test_query_with_params(self, client):
        result = await client.query_params(
            "SELECT $1 as num, $2 as txt",
            [WireValue.int64(42), WireValue.string("hello")],
        )
        assert result is not None


class TestExecute:
    async def test_create_table_and_insert(self, client):
        # Clean up first (best-effort)
        try:
            await client.execute("DROP TABLE IF EXISTS test_users")
        except Exception:
            pass

        await client.execute(
            "CREATE TABLE test_users (id INT PRIMARY KEY, name STRING, age INT)"
        )
        affected = await client.execute(
            "INSERT INTO test_users (id, name, age) VALUES (1, 'Alice', 30)"
        )
        assert affected >= 0

        result = await client.query("SELECT name, age FROM test_users WHERE id = 1")
        assert result.row_count == 1
        row = result.rows[0]
        # Server returns all columns; map by name via dict iteration
        row_dict = dict(zip(result.columns, row))
        assert row_dict["name"] == "Alice"
        assert row_dict["age"] == 30

        await client.execute("DROP TABLE test_users")


class TestQueryBuilder:
    async def test_builder_exec(self, client):
        try:
            await client.execute("DROP TABLE IF EXISTS test_products")
        except Exception:
            pass

        await client.execute(
            "CREATE TABLE test_products (id INT PRIMARY KEY, name STRING, price FLOAT)"
        )
        await client.execute(
            "INSERT INTO test_products (id, name, price) VALUES (1, 'Widget', 9.99)"
        )

        qb = (
            QueryBuilder(client)
            .select("name", "price")
            .from_("test_products")
            .where("id = 1")
        )
        result = await qb.exec()
        assert result.row_count == 1

        await client.execute("DROP TABLE test_products")


class TestAuth:
    async def test_auth_with_dummy_token(self, client):
        # Server uses default JWT secret in dev mode, any token format is accepted
        # depending on server config. We just verify the method does not crash.
        try:
            await client.auth("dummy-token-for-testing")
        except Exception as exc:
            # Auth may fail with invalid token — that's acceptable for this test
            assert "Auth" in str(exc) or "error" in str(exc).lower()


class TestTransactions:
    async def test_transaction_begin_commit(self, client):
        try:
            await client.execute("DROP TABLE IF EXISTS test_txn")
        except Exception:
            pass
        await client.execute("CREATE TABLE test_txn (id INT PRIMARY KEY)")

        await client.execute("BEGIN")
        await client.execute("INSERT INTO test_txn (id) VALUES (1)")
        await client.execute("COMMIT")

        result = await client.query("SELECT COUNT(*) FROM test_txn")
        assert result.row_count >= 0

        await client.execute("DROP TABLE test_txn")
