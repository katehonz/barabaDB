//! BaraDB Rust Client
//!
//! Binary protocol client for BaraDB database.
//!
//! # Example
//! ```no_run
//! use baradb::Client;
//!
//! let mut client = Client::connect("localhost", 9472).unwrap();
//! let result = client.query("SELECT name FROM users WHERE age > 18").unwrap();
//! for row in result.rows() {
//!     println!("{}", row["name"]);
//! }
//! client.close();
//! ```

use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::TcpStream;

// Wire protocol constants
const MK_QUERY: u32 = 0x02;
const MK_READY: u32 = 0x81;
const MK_DATA: u32 = 0x82;
const MK_COMPLETE: u32 = 0x83;
const MK_ERROR: u32 = 0x84;
const MK_PING: u32 = 0x08;

const FK_NULL: u8 = 0x00;
const FK_BOOL: u8 = 0x01;
const FK_INT8: u8 = 0x02;
const FK_INT16: u8 = 0x03;
const FK_INT32: u8 = 0x04;
const FK_INT64: u8 = 0x05;
const FK_FLOAT32: u8 = 0x06;
const FK_FLOAT64: u8 = 0x07;
const FK_STRING: u8 = 0x08;
const FK_BYTES: u8 = 0x09;
const FK_ARRAY: u8 = 0x0A;
const FK_OBJECT: u8 = 0x0B;
const FK_VECTOR: u8 = 0x0C;
const FK_JSON: u8 = 0x0D;

/// Connection configuration
#[derive(Debug, Clone)]
pub struct Config {
    pub host: String,
    pub port: u16,
    pub database: String,
    pub username: String,
    pub password: String,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            host: "127.0.0.1".to_string(),
            port: 9472,
            database: "default".to_string(),
            username: "admin".to_string(),
            password: String::new(),
        }
    }
}

/// Query result
#[derive(Debug)]
pub struct QueryResult {
    columns: Vec<String>,
    column_types: Vec<String>,
    rows: Vec<HashMap<String, String>>,
    affected_rows: usize,
}

impl QueryResult {
    pub fn columns(&self) -> &[String] {
        &self.columns
    }

    pub fn column_types(&self) -> &[String] {
        &self.column_types
    }

    pub fn rows(&self) -> &[HashMap<String, String>] {
        &self.rows
    }

    pub fn row_count(&self) -> usize {
        self.rows.len()
    }

    pub fn affected_rows(&self) -> usize {
        self.affected_rows
    }
}

/// BaraDB client
pub struct Client {
    config: Config,
    stream: TcpStream,
    connected: bool,
    request_id: u32,
}

impl Client {
    /// Connect to BaraDB server
    pub fn connect(host: &str, port: u16) -> Result<Self, Box<dyn std::error::Error>> {
        let config = Config {
            host: host.to_string(),
            port,
            ..Default::default()
        };
        Self::connect_with_config(config)
    }

    /// Connect with custom configuration
    pub fn connect_with_config(config: Config) -> Result<Self, Box<dyn std::error::Error>> {
        let addr = format!("{}:{}", config.host, config.port);
        let stream = TcpStream::connect(&addr)?;
        Ok(Client {
            config,
            stream,
            connected: true,
            request_id: 0,
        })
    }

    /// Close the connection
    pub fn close(&mut self) {
        self.connected = false;
    }

    /// Check if connected
    pub fn is_connected(&self) -> bool {
        self.connected
    }

    fn next_id(&mut self) -> u32 {
        self.request_id += 1;
        self.request_id
    }

    /// Execute a BaraQL query
    pub fn query(&mut self, sql: &str) -> Result<QueryResult, Box<dyn std::error::Error>> {
        if !self.connected {
            return Err("Not connected".into());
        }

        let payload = encode_string(sql);
        let msg = build_message(MK_QUERY, self.next_id(), &payload);
        self.stream.write_all(&msg)?;

        // Read header
        let mut header = [0u8; 12];
        self.stream.read_exact(&mut header)?;

        let kind = u32::from_be_bytes([header[0], header[1], header[2], header[3]]);
        let length = u32::from_be_bytes([header[4], header[5], header[6], header[7]]) as usize;

        // Read payload
        let mut payload = vec![0u8; length];
        if length > 0 {
            self.stream.read_exact(&mut payload)?;
        }

        match kind {
            MK_READY => Ok(QueryResult { columns: vec![], column_types: vec![], rows: vec![], affected_rows: 0 }),
            MK_DATA => {
                let mut pos = 0usize;
                let col_count = read_u32(&payload, &mut pos) as usize;
                let mut columns = Vec::with_capacity(col_count);
                for _ in 0..col_count {
                    columns.push(read_string(&payload, &mut pos));
                }
                let mut col_types = Vec::with_capacity(col_count);
                for _ in 0..col_count {
                    col_types.push(format!("{}", payload[pos]));
                    pos += 1;
                }
                let row_count = read_u32(&payload, &mut pos) as usize;
                let mut rows = Vec::with_capacity(row_count);
                for _ in 0..row_count {
                    let mut row = HashMap::new();
                    for c in 0..col_count {
                        let val = read_value(&payload, &mut pos);
                        row.insert(columns[c].clone(), val);
                    }
                    rows.push(row);
                }
                // Read following COMPLETE message
                let mut comp_header = [0u8; 12];
                self.stream.read_exact(&mut comp_header)?;
                let comp_kind = u32::from_be_bytes([comp_header[0], comp_header[1], comp_header[2], comp_header[3]]);
                let comp_len = u32::from_be_bytes([comp_header[4], comp_header[5], comp_header[6], comp_header[7]]) as usize;
                let mut comp_payload = vec![0u8; comp_len];
                if comp_len > 0 {
                    self.stream.read_exact(&mut comp_payload)?;
                }
                let affected = if comp_kind == MK_COMPLETE && comp_payload.len() >= 4 {
                    u32::from_be_bytes([comp_payload[0], comp_payload[1], comp_payload[2], comp_payload[3]]) as usize
                } else { 0 };
                Ok(QueryResult { columns, column_types: col_types, rows, affected_rows: affected })
            }
            MK_COMPLETE => {
                let affected = if payload.len() >= 4 {
                    u32::from_be_bytes([payload[0], payload[1], payload[2], payload[3]]) as usize
                } else { 0 };
                Ok(QueryResult { columns: vec![], column_types: vec![], rows: vec![], affected_rows: affected })
            }
            MK_ERROR => Err("Query error".into()),
            _ => Err(format!("Unknown response kind: {}", kind).into()),
        }
    }

    /// Execute a statement
    pub fn execute(&mut self, sql: &str) -> Result<usize, Box<dyn std::error::Error>> {
        let result = self.query(sql)?;
        Ok(result.affected_rows())
    }

    /// Ping the server
    pub fn ping(&mut self) -> Result<(), Box<dyn std::error::Error>> {
        let msg = build_message(MK_PING, self.next_id(), &[]);
        self.stream.write_all(&msg)?;
        Ok(())
    }
}

/// Query builder for fluent API
pub struct QueryBuilder<'a> {
    client: &'a mut Client,
    select_cols: Vec<String>,
    from_table: String,
    where_clauses: Vec<String>,
    joins: Vec<String>,
    group_by: Vec<String>,
    having: String,
    order_by: Vec<String>,
    limit: usize,
    offset: usize,
}

impl<'a> QueryBuilder<'a> {
    pub fn new(client: &'a mut Client) -> Self {
        QueryBuilder {
            client,
            select_cols: vec![],
            from_table: String::new(),
            where_clauses: vec![],
            joins: vec![],
            group_by: vec![],
            having: String::new(),
            order_by: vec![],
            limit: 0,
            offset: 0,
        }
    }

    pub fn select(mut self, cols: &[&str]) -> Self {
        self.select_cols.extend(cols.iter().map(|s| s.to_string()));
        self
    }

    pub fn from(mut self, table: &str) -> Self {
        self.from_table = table.to_string();
        self
    }

    pub fn where_clause(mut self, clause: &str) -> Self {
        self.where_clauses.push(clause.to_string());
        self
    }

    pub fn join(mut self, table: &str, on: &str) -> Self {
        self.joins.push(format!("JOIN {} ON {}", table, on));
        self
    }

    pub fn left_join(mut self, table: &str, on: &str) -> Self {
        self.joins.push(format!("LEFT JOIN {} ON {}", table, on));
        self
    }

    pub fn group_by(mut self, cols: &[&str]) -> Self {
        self.group_by.extend(cols.iter().map(|s| s.to_string()));
        self
    }

    pub fn having(mut self, clause: &str) -> Self {
        self.having = clause.to_string();
        self
    }

    pub fn order_by(mut self, col: &str, dir: &str) -> Self {
        self.order_by.push(format!("{} {}", col, dir));
        self
    }

    pub fn limit(mut self, n: usize) -> Self {
        self.limit = n;
        self
    }

    pub fn offset(mut self, n: usize) -> Self {
        self.offset = n;
        self
    }

    pub fn build(&self) -> String {
        let mut sql = String::from("SELECT ");
        if self.select_cols.is_empty() {
            sql.push('*');
        } else {
            sql.push_str(&self.select_cols.join(", "));
        }
        sql.push_str(&format!(" FROM {}", self.from_table));
        for j in &self.joins {
            sql.push(' ');
            sql.push_str(j);
        }
        if !self.where_clauses.is_empty() {
            sql.push_str(&format!(" WHERE {}", self.where_clauses.join(" AND ")));
        }
        if !self.group_by.is_empty() {
            sql.push_str(&format!(" GROUP BY {}", self.group_by.join(", ")));
        }
        if !self.having.is_empty() {
            sql.push_str(&format!(" HAVING {}", self.having));
        }
        if !self.order_by.is_empty() {
            sql.push_str(&format!(" ORDER BY {}", self.order_by.join(", ")));
        }
        if self.limit > 0 {
            sql.push_str(&format!(" LIMIT {}", self.limit));
        }
        if self.offset > 0 {
            sql.push_str(&format!(" OFFSET {}", self.offset));
        }
        sql
    }

    pub fn exec(self) -> Result<QueryResult, Box<dyn std::error::Error>> {
        let sql = self.build();
        self.client.query(&sql)
    }
}

fn build_message(kind: u32, req_id: u32, payload: &[u8]) -> Vec<u8> {
    let mut msg = Vec::with_capacity(12 + payload.len());
    msg.extend_from_slice(&kind.to_be_bytes());
    msg.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    msg.extend_from_slice(&req_id.to_be_bytes());
    msg.extend_from_slice(payload);
    msg
}

fn encode_string(s: &str) -> Vec<u8> {
    let bytes = s.as_bytes();
    let mut result = Vec::with_capacity(4 + bytes.len());
    result.extend_from_slice(&(bytes.len() as u32).to_be_bytes());
    result.extend_from_slice(bytes);
    result
}


fn read_u32(data: &[u8], pos: &mut usize) -> u32 {
    let val = u32::from_be_bytes([data[*pos], data[*pos + 1], data[*pos + 2], data[*pos + 3]]);
    *pos += 4;
    val
}

fn read_string(data: &[u8], pos: &mut usize) -> String {
    let len = read_u32(data, pos) as usize;
    let s = String::from_utf8_lossy(&data[*pos..*pos + len]).to_string();
    *pos += len;
    s
}

fn read_value(data: &[u8], pos: &mut usize) -> String {
    let kind = data[*pos];
    *pos += 1;
    match kind {
        FK_NULL => String::new(),
        FK_BOOL => {
            let val = data[*pos] != 0;
            *pos += 1;
            val.to_string()
        }
        FK_INT8 => {
            let val = data[*pos] as i8;
            *pos += 1;
            val.to_string()
        }
        FK_INT16 => {
            let val = i16::from_be_bytes([data[*pos], data[*pos + 1]]);
            *pos += 2;
            val.to_string()
        }
        FK_INT32 => {
            let val = i32::from_be_bytes([data[*pos], data[*pos + 1], data[*pos + 2], data[*pos + 3]]);
            *pos += 4;
            val.to_string()
        }
        FK_INT64 => {
            let val = i64::from_be_bytes([data[*pos], data[*pos + 1], data[*pos + 2], data[*pos + 3],
                                          data[*pos + 4], data[*pos + 5], data[*pos + 6], data[*pos + 7]]);
            *pos += 8;
            val.to_string()
        }
        FK_FLOAT32 => {
            let val = f32::from_be_bytes([data[*pos], data[*pos + 1], data[*pos + 2], data[*pos + 3]]);
            *pos += 4;
            val.to_string()
        }
        FK_FLOAT64 => {
            let val = f64::from_be_bytes([data[*pos], data[*pos + 1], data[*pos + 2], data[*pos + 3],
                                          data[*pos + 4], data[*pos + 5], data[*pos + 6], data[*pos + 7]]);
            *pos += 8;
            val.to_string()
        }
        FK_STRING => read_string(data, pos),
        FK_BYTES => {
            let len = read_u32(data, pos) as usize;
            *pos += len;
            format!("<bytes:{}>", len)
        }
        FK_ARRAY => {
            let count = read_u32(data, pos);
            for _ in 0..count {
                let _ = read_value(data, pos);
            }
            format!("<array:{}>", count)
        }
        FK_OBJECT => {
            let count = read_u32(data, pos);
            for _ in 0..count {
                let _ = read_string(data, pos);
                let _ = read_value(data, pos);
            }
            format!("<object:{}>", count)
        }
        FK_VECTOR => {
            let dim = read_u32(data, pos);
            *pos += (dim * 4) as usize;
            format!("<vector:{}>", dim)
        }
        FK_JSON => read_string(data, pos),
        _ => String::new(),
    }
}
