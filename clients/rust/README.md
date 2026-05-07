# BaraDB Rust Client

Official Rust client for **BaraDB** — a multimodal database engine written in Nim.

## Features

- **Binary wire protocol** — fast TCP communication using only `std`
- **Zero dependencies** — no external crates required
- **Sync API** — blocking I/O suitable for most applications
- **Query builder** — fluent SQL construction
- **Vector & JSON support** — first-class multimodal types

## Installation

Add to your `Cargo.toml`:

```toml
[dependencies]
baradb = "1.0"
```

Or from source:

```bash
git clone https://github.com/barabadb/baradadb.git
cd clients/rust
cargo build
```

## Quick Start

```rust
use baradb::Client;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut client = Client::connect("localhost", 9472)?;
    let result = client.query("SELECT name, age FROM users WHERE age > 18")?;
    for row in result.rows() {
        println!("{:?}", row);
    }
    client.close();
    Ok(())
}
```

### Parameterized Queries

```rust
use baradb::{Client, WireValue};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut client = Client::connect("localhost", 9472)?;
    let result = client.query_params(
        "SELECT * FROM users WHERE age > $1 AND country = $2",
        &[WireValue::Int64(18), WireValue::String("BG".to_string())],
    )?;
    for row in result.rows() {
        println!("{:?}", row);
    }
    client.close();
    Ok(())
}
```

### Query Builder

```rust
use baradb::Client;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut client = Client::connect("localhost", 9472)?;
    let result = baradb::QueryBuilder::new(&mut client)
        .select(&["name", "email"])
        .from("users")
        .where_clause("active = true")
        .order_by("name", "ASC")
        .limit(10)
        .exec()?;
    for row in result.rows() {
        println!("{:?}", row);
    }
    client.close();
    Ok(())
}
```

### Vector Search

```rust
use baradb::{Client, WireValue};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut client = Client::connect("localhost", 9472)?;
    let result = client.query_params(
        "SELECT id, name FROM products ORDER BY embedding <-> $1 LIMIT 5",
        &[WireValue::Vector(vec![0.1, 0.2, 0.3])],
    )?;
    client.close();
    Ok(())
}
```

## Running Tests

Unit tests (no server):

```bash
cargo test --lib
```

Integration tests (requires server on `localhost:9472`):

```bash
# Start server
docker run -d -p 9472:9472 baradb:latest

# Run all tests
cargo test
```

## API Reference

### `Client::connect(host, port)`

Creates a new client connected to the given host and port.

### Methods

- `query(sql) -> Result<QueryResult>` — execute SELECT-like query
- `query_params(sql, params) -> Result<QueryResult>` — parameterized query
- `execute(sql) -> Result<usize>` — execute DDL/DML, returns affected rows
- `auth(token) -> Result<()>` — JWT authentication
- `ping() -> Result<bool>` — health check
- `close()` — close connection

## License

Apache-2.0
