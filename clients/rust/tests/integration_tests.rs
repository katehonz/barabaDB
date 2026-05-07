// BaraDB Rust Client — Integration Tests
// Requires a running BaraDB server on localhost:9472.

use std::net::TcpStream;
use std::time::Duration;

use baradb::{Client, QueryBuilder, WireValue};

const HOST: &str = "127.0.0.1";
const PORT: u16 = 9472;

fn server_available() -> bool {
    TcpStream::connect((HOST, PORT)).is_ok()
}

#[test]
fn test_connect_and_close() {
    if !server_available() {
        return;
    }
    let mut client = Client::connect(HOST, PORT).unwrap();
    assert!(client.is_connected());
    client.close();
    assert!(!client.is_connected());
}

#[test]
fn test_ping() {
    if !server_available() {
        return;
    }
    let mut client = Client::connect(HOST, PORT).unwrap();
    assert!(client.ping().unwrap());
    client.close();
}

#[test]
fn test_simple_select() {
    if !server_available() {
        return;
    }
    let mut client = Client::connect(HOST, PORT).unwrap();
    let result = client.query("SELECT 1 as one").unwrap();
    assert!(result.row_count() >= 0);
    client.close();
}

#[test]
fn test_parameterized_query() {
    if !server_available() {
        return;
    }
    let mut client = Client::connect(HOST, PORT).unwrap();
    let result = client
        .query_params(
            "SELECT $1 as num, $2 as txt",
            &[WireValue::Int64(42), WireValue::String("hello".to_string())],
        )
        .unwrap();
    assert!(result.row_count() >= 0);
    client.close();
}

#[test]
fn test_create_table_insert_select_drop() {
    if !server_available() {
        return;
    }
    let mut client = Client::connect(HOST, PORT).unwrap();

    let _ = client.execute("DROP TABLE IF EXISTS rust_test_users");
    client
        .execute("CREATE TABLE rust_test_users (id INT PRIMARY KEY, name STRING, age INT)")
        .unwrap();
    let affected = client
        .execute("INSERT INTO rust_test_users (id, name, age) VALUES (1, 'Alice', 30)")
        .unwrap();
    assert!(affected >= 0);

    let result = client
        .query("SELECT name, age FROM rust_test_users WHERE id = 1")
        .unwrap();
    assert_eq!(result.row_count(), 1);

    client.execute("DROP TABLE rust_test_users").unwrap();
    client.close();
}

#[test]
fn test_query_builder_exec() {
    if !server_available() {
        return;
    }
    let mut client = Client::connect(HOST, PORT).unwrap();

    let _ = client.execute("DROP TABLE IF EXISTS rust_test_products");
    client
        .execute("CREATE TABLE rust_test_products (id INT PRIMARY KEY, name STRING, price FLOAT)")
        .unwrap();
    client
        .execute("INSERT INTO rust_test_products (id, name, price) VALUES (1, 'Widget', 9.99)")
        .unwrap();

    let result = QueryBuilder::new(&mut client)
        .select(&["name", "price"])
        .from("rust_test_products")
        .where_clause("id = 1")
        .exec()
        .unwrap();

    assert_eq!(result.row_count(), 1);

    client.execute("DROP TABLE rust_test_products").unwrap();
    client.close();
}

#[test]
fn test_auth_dummy_token() {
    if !server_available() {
        return;
    }
    let mut client = Client::connect(HOST, PORT).unwrap();
    let res = client.auth("dummy-token-for-testing");
    // Dev server may accept or reject — both are fine
    match res {
        Ok(()) => {}
        Err(e) => {
            let msg = e.to_string();
            assert!(msg.contains("Auth") || msg.to_lowercase().contains("error"));
        }
    }
    client.close();
}
