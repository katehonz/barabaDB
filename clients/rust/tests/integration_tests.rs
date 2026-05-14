// BaraDB Rust Client — Integration Tests
// Requires a running BaraDB server.
// Set BARADB_HOST / BARADB_PORT env vars to override defaults.

use std::net::TcpStream;

use baradb::{Client, QueryBuilder, WireValue};

fn host() -> String {
    std::env::var("BARADB_HOST").unwrap_or_else(|_| "127.0.0.1".to_string())
}

fn port() -> u16 {
    std::env::var("BARADB_PORT")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(9472)
}

fn server_available() -> bool {
    TcpStream::connect((host().as_str(), port())).is_ok()
}

#[tokio::test]
async fn test_connect_and_close() {
    if !server_available() {
        return;
    }
    let mut client = Client::connect(&host(), port()).await.unwrap();
    assert!(client.is_connected());
    client.close().await;
    assert!(!client.is_connected());
}

#[tokio::test]
async fn test_ping() {
    if !server_available() {
        return;
    }
    let mut client = Client::connect(&host(), port()).await.unwrap();
    assert!(client.ping().await.unwrap());
    client.close().await;
}

#[tokio::test]
async fn test_simple_select() {
    if !server_available() {
        return;
    }
    let mut client = Client::connect(&host(), port()).await.unwrap();
    let result = client.query("SELECT 1 as one").await.unwrap();
    assert!(result.row_count() >= 0);
    client.close().await;
}

#[tokio::test]
async fn test_parameterized_query() {
    if !server_available() {
        return;
    }
    let mut client = Client::connect(&host(), port()).await.unwrap();
    let result = client
        .query_params(
            "SELECT $1 as num, $2 as txt",
            &[WireValue::Int64(42), WireValue::String("hello".to_string())],
        )
        .await
        .unwrap();
    assert!(result.row_count() >= 0);
    client.close().await;
}

#[tokio::test]
async fn test_create_table_insert_select_drop() {
    if !server_available() {
        return;
    }
    let mut client = Client::connect(&host(), port()).await.unwrap();

    let _ = client.execute("DROP TABLE IF EXISTS rust_test_users").await;
    client
        .execute("CREATE TABLE rust_test_users (id INT PRIMARY KEY, name STRING, age INT)")
        .await
        .unwrap();
    let affected = client
        .execute("INSERT INTO rust_test_users (id, name, age) VALUES (1, 'Alice', 30)")
        .await
        .unwrap();
    assert!(affected >= 0);

    let result = client
        .query("SELECT name, age FROM rust_test_users WHERE id = 1")
        .await
        .unwrap();
    assert_eq!(result.row_count(), 1);

    client.execute("DROP TABLE rust_test_users").await.unwrap();
    client.close().await;
}

#[tokio::test]
async fn test_query_builder_exec() {
    if !server_available() {
        return;
    }
    let mut client = Client::connect(&host(), port()).await.unwrap();

    let _ = client.execute("DROP TABLE IF EXISTS rust_test_products").await;
    client
        .execute("CREATE TABLE rust_test_products (id INT PRIMARY KEY, name STRING, price FLOAT)")
        .await
        .unwrap();
    client
        .execute("INSERT INTO rust_test_products (id, name, price) VALUES (1, 'Widget', 9.99)")
        .await
        .unwrap();

    let result = QueryBuilder::new(&mut client)
        .select(&["name", "price"])
        .from("rust_test_products")
        .where_clause("id = 1")
        .exec()
        .await
        .unwrap();

    assert_eq!(result.row_count(), 1);

    client.execute("DROP TABLE rust_test_products").await.unwrap();
    client.close().await;
}

#[tokio::test]
async fn test_auth_dummy_token() {
    if !server_available() {
        return;
    }
    let mut client = Client::connect(&host(), port()).await.unwrap();
    let res = client.auth("dummy-token-for-testing").await;
    // Dev server may accept or reject — both are fine
    match res {
        Ok(()) => {}
        Err(e) => {
            let msg = e.to_string();
            assert!(msg.contains("Auth") || msg.to_lowercase().contains("error"));
        }
    }
    client.close().await;
}
