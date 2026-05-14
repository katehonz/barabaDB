use baradb::Client;

#[tokio::main]
async fn main() {
    let mut client = Client::connect("localhost", 9472).await.unwrap();
    println!("Connected: {}", client.is_connected());
    match client.ping().await {
        Ok(v) => println!("Ping: {}", v),
        Err(e) => println!("Ping error: {}", e),
    }
    client.close().await;
}
