use baradb::Client;

fn main() {
    let mut client = Client::connect("localhost", 9472).unwrap();
    println!("Connected: {}", client.is_connected());
    match client.ping() {
        Ok(v) => println!("Ping: {}", v),
        Err(e) => println!("Ping error: {}", e),
    }
    client.close();
}
