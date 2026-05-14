# BaraDB Python Async Client

Official async Python client for **BaraDB** — a multimodal database engine written in Nim.

## Features

- **Async/await** — fully non-blocking, concurrent query support
- **Binary wire protocol** — fast, compact TCP communication
- **Request queueing** — sequential processing with concurrent execution
- **Query builder** — fluent SQL construction
- **Parameterized queries** — safe from SQL injection
- **Vector & JSON support** — first-class multimodal types
- **Context managers** — async `async with` statement support

## Installation

```bash
pip install baradb
```

Or from source:

```bash
git clone https://github.com/katehonz/barabaDB.git
cd clients/python
pip install -e ".[dev]"
```

## Quick Start

```python
import asyncio
from baradb import Client

async def main():
    client = Client("localhost", 9472)
    await client.connect()

    result = await client.query("SELECT name, age FROM users WHERE age > 18")
    for row in result:
        print(row["name"], row["age"])

    await client.close()

asyncio.run(main())
```

### Context Manager

```python
import asyncio
from baradb import Client

async def main():
    async with Client("localhost", 9472) as client:
        result = await client.query("SELECT 1")
        print(result.row_count)

asyncio.run(main())
```

### Parameterized Queries

```python
import asyncio
from baradb import Client, WireValue

async def main():
    async with Client("localhost", 9472) as client:
        result = await client.query_params(
            "SELECT * FROM users WHERE age > $1 AND country = $2",
            [WireValue.int64(18), WireValue.string("BG")],
        )
        for row in result:
            print(row)

asyncio.run(main())
```

### Query Builder

```python
import asyncio
from baradb import Client, QueryBuilder

async def main():
    async with Client("localhost", 9472) as client:
        qb = (
            QueryBuilder(client)
            .select("name", "email")
            .from_("users")
            .where("active = true")
            .order_by("name")
            .limit(10)
        )
        result = await qb.exec()
        for row in result:
            print(row)

asyncio.run(main())
```

### Vector Search

```python
import asyncio
from baradb import Client, WireValue

async def main():
    async with Client("localhost", 9472) as client:
        result = await client.query_params(
            "SELECT id, name FROM products ORDER BY embedding <-> $1 LIMIT 5",
            [WireValue.vector([0.1, 0.2, 0.3])],
        )
        print(result.rows)

asyncio.run(main())
```

## Running Tests

Unit tests (no server):

```bash
pytest tests/test_wire_protocol.py tests/test_query_builder.py
```

Integration tests (requires server on `localhost:9472`):

```bash
# Start server
docker run -d -p 9472:9472 barabadb:latest

# Run all tests
pytest
```

## API Reference

### `Client(host, port, database, username, password, timeout)`

| Parameter  | Default     | Description                |
|------------|-------------|----------------------------|
| `host`     | `localhost` | Server hostname            |
| `port`     | `9472`      | TCP wire protocol port     |
| `database` | `default`   | Default database           |
| `username` | `admin`     | Username                   |
| `password` | `""`        | Password                   |
| `timeout`  | `30.0`      | Socket timeout in seconds   |

### Methods (all async)

- `await client.connect()` — open TCP connection
- `await client.close()` — close connection
- `await client.query(sql) -> QueryResult` — execute SELECT-like query
- `await client.query_params(sql, params) -> QueryResult` — parameterized query
- `await client.execute(sql) -> int` — execute DDL/DML, returns affected rows
- `await client.auth(token)` — JWT authentication
- `await client.ping() -> bool` — health check

## License

Apache-2.0