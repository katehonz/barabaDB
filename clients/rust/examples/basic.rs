// BaraDB Rust Client — Basic Examples
// Make sure BaraDB is running on localhost:9472.

use baradb::{Client, QueryBuilder, WireValue};

fn example_connection() -> Result<(), Box<dyn std::error::Error>> {
    println!("=== Connection ===");
    let mut client = Client::connect("127.0.0.1", 9472)?;
    println!("Connected: {}", client.is_connected());
    println!("Ping: {}", client.ping()?);
    client.close();
    println!("Connected after close: {}", client.is_connected());
    println!();
    Ok(())
}

fn example_simple_query() -> Result<(), Box<dyn std::error::Error>> {
    println!("=== Simple Query ===");
    let mut client = Client::connect("127.0.0.1", 9472)?;
    let result = client.query("SELECT 42 as answer, 'BaraDB' as db")?;
    println!("Columns: {:?}", result.columns());
    println!("Row count: {}", result.row_count());
    for row in result.rows() {
        println!("  {:?}", row);
    }
    client.close();
    println!();
    Ok(())
}

fn example_parameterized_query() -> Result<(), Box<dyn std::error::Error>> {
    println!("=== Parameterized Query ===");
    let mut client = Client::connect("127.0.0.1", 9472)?;
    let result = client.query_params(
        "SELECT $1 as num, $2 as txt, $3 as flag",
        &[
            WireValue::Int64(123),
            WireValue::String("hello world".to_string()),
            WireValue::Bool(true),
        ],
    )?;
    for row in result.rows() {
        println!("  {:?}", row);
    }
    client.close();
    println!();
    Ok(())
}

fn example_query_builder() -> Result<(), Box<dyn std::error::Error>> {
    println!("=== Query Builder ===");
    let mut client = Client::connect("127.0.0.1", 9472)?;
    let sql = QueryBuilder::new(&mut client)
        .select(&["id", "name"])
        .from("users")
        .where_clause("active = true")
        .order_by("name", "ASC")
        .limit(5)
        .build();
    println!("Generated SQL: {}", sql);
    client.close();
    println!();
    Ok(())
}

fn example_vector() -> Result<(), Box<dyn std::error::Error>> {
    println!("=== Vector Value ===");
    let mut client = Client::connect("127.0.0.1", 9472)?;
    let result = client.query_params(
        "SELECT $1 as embedding",
        &[WireValue::Vector(vec![0.1, 0.2, 0.3, 0.4])],
    )?;
    for row in result.rows() {
        println!("  {:?}", row);
    }
    client.close();
    println!();
    Ok(())
}

fn example_ddl_dml() -> Result<(), Box<dyn std::error::Error>> {
    println!("=== DDL & DML ===");
    let mut client = Client::connect("127.0.0.1", 9472)?;

    let _ = client.execute("DROP TABLE IF EXISTS demo_products");

    client.execute(
        "CREATE TABLE demo_products (id INT PRIMARY KEY, name STRING, price FLOAT)",
    )?;
    let affected = client.execute(
        "INSERT INTO demo_products (id, name, price) VALUES (1, 'Widget', 9.99)",
    )?;
    println!("Insert affected rows: {}", affected);

    let result = client.query("SELECT * FROM demo_products")?;
    println!("Select returned {} row(s)", result.row_count());
    for row in result.rows() {
        println!("  {:?}", row);
    }

    client.execute("DROP TABLE demo_products")?;
    println!("Table dropped");
    client.close();
    println!();
    Ok(())
}

fn main() {
    println!("BaraDB Rust Client Examples");
    println!("Make sure BaraDB is running on localhost:9472");
    println!();

    let examples: Vec<fn() -> Result<(), Box<dyn std::error::Error>>> = vec![
        example_connection,
        example_simple_query,
        example_parameterized_query,
        example_query_builder,
        example_vector,
        example_ddl_dml,
    ];

    for example in examples {
        if let Err(e) = example() {
            eprintln!("ERROR: {}", e);
        }
    }
}
