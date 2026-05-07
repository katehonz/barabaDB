# BaraDB Python Client

Official Python client for **BaraDB** — a multimodal database engine written in Nim.

## Features

- **Binary wire protocol** — fast, compact TCP communication
- **Sync & blocking API** — simple to use in scripts and apps
- **Query builder** — fluent SQL construction
- **Parameterized queries** — safe from SQL injection
- **Vector & JSON support** — first-class multimodal types
- **Context managers** — `with` statement support

## Installation

```bash
pip install baradb
```

Or from source:

```bash
git clone https://github.com/barabadb/baradadb.git
cd clients/python
pip install -e ".[dev]"
```

## Quick Start

```python
from baradb import Client

client = Client("localhost", 9472)
client.connect()

result = client.query("SELECT name, age FROM users WHERE age > 18")
for row in result:
    print(row["name"], row["age"])

client.close()
```

### Context Manager

```python
from baradb import Client

with Client("localhost", 9472) as client:
    result = client.query("SELECT 1")
    print(result.row_count)
```

### Parameterized Queries

```python
from baradb import Client, WireValue

with Client("localhost", 9472) as client:
    result = client.query_params(
        "SELECT * FROM users WHERE age > $1 AND country = $2",
        [WireValue.int64(18), WireValue.string("BG")],
    )
    for row in result:
        print(row)
```

### Query Builder

```python
from baradb import Client, QueryBuilder

with Client("localhost", 9472) as client:
    qb = (
        QueryBuilder(client)
        .select("name", "email")
        .from_("users")
        .where("active = true")
        .order_by("name")
        .limit(10)
    )
    result = qb.exec()
    for row in result:
        print(row)
```

### Vector Search

```python
from baradb import Client, WireValue

with Client("localhost", 9472) as client:
    result = client.query_params(
        "SELECT id, name FROM products ORDER BY embedding <-> $1 LIMIT 5",
        [WireValue.vector([0.1, 0.2, 0.3])],
    )
```

## Running Tests

Unit tests (no server):

```bash
pytest tests/test_wire_protocol.py tests/test_query_builder.py
```

Integration tests (requires server on `localhost:9472`):

```bash
# Start server
docker run -d -p 9472:9472 baradb:latest

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
| `timeout`  | `30`        | Socket timeout in seconds  |

### Methods

- `connect()` — open TCP connection
- `close()` — close connection
- `query(sql) -> QueryResult` — execute SELECT-like query
- `query_params(sql, params) -> QueryResult` — parameterized query
- `execute(sql) -> int` — execute DDL/DML, returns affected rows
- `auth(token)` — JWT authentication
- `ping() -> bool` — health check

## License

Apache-2.0
