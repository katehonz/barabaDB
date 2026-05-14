# BaraDB Async Rust Client

Official async Rust client for **BaraDB** — a multimodal database engine written in Nim.

## Features

- **Async/await** — fully non-blocking with Tokio runtime
- **Binary wire protocol** — fast TCP communication
- **Query builder** — fluent SQL construction
- **Parameterized queries** — safe from SQL injection
- **Vector & JSON support** — first-class multimodal types

## Installation

Add to your `Cargo.toml`:

```toml
[dependencies]
baradb = "1.1"
tokio = { version = "1.35", features = ["full"] }
```

Or from source:

```bash
git clone https://github.com/katehonz/barabaDB.git
cd clients/rust
cargo build
```

## Quick Start

```rust
use baradb::Client;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let mut client = Client::connect("localhost", 9472).await?;
    let result = client.query("SELECT name, age FROM users WHERE age > 18").await?;
    for row in result.rows() {
        println!("{:?}", row);
    }
    client.close().await;
    Ok(())
}
```

### Parameterized Queries

```rust
use baradb::{Client, WireValue};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let mut client = Client::connect("localhost", 9472).await?;
    let result = client.query_params(
        "SELECT * FROM users WHERE age > $1 AND country = $2",
        &[WireValue::Int64(18), WireValue::String("BG".to_string())],
    ).await?;
    for row in result.rows() {
        println!("{:?}", row);
    }
    client.close().await;
    Ok(())
}
```

### Query Builder

```rust
use baradb::{Client, QueryBuilder};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let mut client = Client::connect("localhost", 9472).await?;
    let result = QueryBuilder::new(&mut client)
        .select(&["name", "email"])
        .from("users")
        .where_clause("active = true")
        .order_by("name", "ASC")
        .limit(10)
        .exec()
        .await?;
    for row in result.rows() {
        println!("{:?}", row);
    }
    client.close().await;
    Ok(())
}
```

### Vector Search

```rust
use baradb::{Client, WireValue};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let mut client = Client::connect("localhost", 9472).await?;
    let result = client.query_params(
        "SELECT id, name FROM products ORDER BY embedding <-> $1 LIMIT 5",
        &[WireValue::Vector(vec![0.1, 0.2, 0.3])],
    ).await?;
    client.close().await;
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
docker run -d -p 9472:9472 barabadb:latest

# Run all tests
cargo test
```

## API Reference

### `Client::connect(host, port) -> Result<Client>`

Creates a new async client connected to the given host and port.

### Methods (all async)

- `await client.query(sql) -> Result<QueryResult>` — execute SELECT-like query
- `await client.query_params(sql, params) -> Result<QueryResult>` — parameterized query
- `await client.execute(sql) -> Result<usize>` — execute DDL/DML, returns affected rows
- `await client.auth(token) -> Result<()>` — JWT authentication
- `await client.ping() -> Result<bool>` — health check
- `await client.close()` — close connection

## License

Apache-2.0