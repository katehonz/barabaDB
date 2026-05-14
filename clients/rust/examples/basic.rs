// BaraDB Rust Client — Basic Examples
// Make sure BaraDB is running on localhost:9472.

use baradb::{Client, QueryBuilder, WireValue};

#[tokio::main]
async fn main() {
    println!("BaraDB Rust Client Examples");
    println!("Make sure BaraDB is running on localhost:9472");
    println!();

    if let Err(e) = example_connection().await {
        eprintln!("ERROR: {}", e);
    }

    if let Err(e) = example_simple_query().await {
        eprintln!("ERROR: {}", e);
    }

    if let Err(e) = example_parameterized_query().await {
        eprintln!("ERROR: {}", e);
    }

    if let Err(e) = example_query_builder().await {
        eprintln!("ERROR: {}", e);
    }

    if let Err(e) = example_vector().await {
        eprintln!("ERROR: {}", e);
    }

    if let Err(e) = example_ddl_dml().await {
        eprintln!("ERROR: {}", e);
    }
}

async fn example_connection() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    println!("=== Connection ===");
    let mut client = Client::connect("127.0.0.1", 9472).await?;
    println!("Connected: {}", client.is_connected());
    println!("Ping: {}", client.ping().await?);
    client.close().await;
    println!("Connected after close: {}", client.is_connected());
    println!();
    Ok(())
}

async fn example_simple_query() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    println!("=== Simple Query ===");
    let mut client = Client::connect("127.0.0.1", 9472).await?;
    let result = client.query("SELECT 42 as answer, 'BaraDB' as db").await?;
    println!("Columns: {:?}", result.columns());
    println!("Row count: {}", result.row_count());
    for row in result.rows() {
        println!("  {:?}", row);
    }
    client.close().await;
    println!();
    Ok(())
}

async fn example_parameterized_query() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    println!("=== Parameterized Query ===");
    let mut client = Client::connect("127.0.0.1", 9472).await?;
    let result = client.query_params(
        "SELECT $1 as num, $2 as txt, $3 as flag",
        &[
            WireValue::Int64(123),
            WireValue::String("hello world".to_string()),
            WireValue::Bool(true),
        ],
    ).await?;
    for row in result.rows() {
        println!("  {:?}", row);
    }
    client.close().await;
    println!();
    Ok(())
}

async fn example_query_builder() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    println!("=== Query Builder ===");
    let mut client = Client::connect("127.0.0.1", 9472).await?;
    let sql = QueryBuilder::new(&mut client)
        .select(&["id", "name"])
        .from("users")
        .where_clause("active = true")
        .order_by("name", "ASC")
        .limit(5)
        .build();
    println!("Generated SQL: {}", sql);
    client.close().await;
    println!();
    Ok(())
}

async fn example_vector() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    println!("=== Vector Value ===");
    let mut client = Client::connect("127.0.0.1", 9472).await?;
    let result = client.query_params(
        "SELECT $1 as embedding",
        &[WireValue::Vector(vec![0.1, 0.2, 0.3, 0.4])],
    ).await?;
    for row in result.rows() {
        println!("  {:?}", row);
    }
    client.close().await;
    println!();
    Ok(())
}

async fn example_ddl_dml() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    println!("=== DDL & DML ===");
    let mut client = Client::connect("127.0.0.1", 9472).await?;

    let _ = client.execute("DROP TABLE IF EXISTS demo_products").await;

    client.execute(
        "CREATE TABLE demo_products (id INT PRIMARY KEY, name STRING, price FLOAT)",
    ).await?;
    let affected = client.execute(
        "INSERT INTO demo_products (id, name, price) VALUES (1, 'Widget', 9.99)",
    ).await?;
    println!("Insert affected rows: {}", affected);

    let result = client.query("SELECT * FROM demo_products").await?;
    println!("Select returned {} row(s)", result.row_count());
    for row in result.rows() {
        println!("  {:?}", row);
    }

    client.execute("DROP TABLE demo_products").await?;
    println!("Table dropped");
    client.close().await;
    println!();
    Ok(())
}