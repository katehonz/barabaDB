//! BaraDB Rust Client
//!
//! Binary protocol client for BaraDB database.
//! Zero external dependencies — uses only `std`.
//!
//! # Example
//! ```no_run
//! use baradb::{Client, WireValue};
//!
//! let mut client = Client::connect("localhost", 9472).unwrap();
//! let result = client.query("SELECT name FROM users WHERE age > 18").unwrap();
//! for row in result.rows() {
//!     if let Some(WireValue::String(name)) = row.get("name") {
//!         println!("{}", name);
//!     }
//! }
//! client.close();
//! ```
//!
//! # Parameterized Queries
//! ```no_run
//! use baradb::{Client, WireValue};
//!
//! let mut client = Client::connect("localhost", 9472).unwrap();
//! let result = client.query_params(
//!     "SELECT * FROM users WHERE age > $1",
//!     &[WireValue::Int64(18)],
//! ).unwrap();
//! ```

use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::TcpStream;

// Client message kinds
const MK_CLIENT_HANDSHAKE: u32 = 0x01;
const MK_QUERY: u32 = 0x02;
const MK_QUERY_PARAMS: u32 = 0x03;
const MK_EXECUTE: u32 = 0x04;
const MK_BATCH: u32 = 0x05;
const MK_TRANSACTION: u32 = 0x06;
const MK_CLOSE: u32 = 0x07;
const MK_PING: u32 = 0x08;
const MK_AUTH: u32 = 0x09;

// Server message kinds
const MK_SERVER_HANDSHAKE: u32 = 0x80;
const MK_READY: u32 = 0x81;
const MK_DATA: u32 = 0x82;
const MK_COMPLETE: u32 = 0x83;
const MK_ERROR: u32 = 0x84;
const MK_AUTH_CHALLENGE: u32 = 0x85;
const MK_AUTH_OK: u32 = 0x86;
const MK_SCHEMA_CHANGE: u32 = 0x87;
const MK_PONG: u32 = 0x88;
const MK_TRANSACTION_STATE: u32 = 0x89;

// Field kinds
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

/// A typed wire value matching the BaraDB wire protocol.
#[derive(Debug, Clone)]
pub enum WireValue {
    Null,
    Bool(bool),
    Int8(i8),
    Int16(i16),
    Int32(i32),
    Int64(i64),
    Float32(f32),
    Float64(f64),
    String(String),
    Bytes(Vec<u8>),
    Array(Vec<WireValue>),
    Object(Vec<(String, WireValue)>),
    Vector(Vec<f32>),
    Json(String),
}

impl WireValue {
    pub fn to_string_lossy(&self) -> String {
        match self {
            WireValue::Null => String::new(),
            WireValue::Bool(v) => v.to_string(),
            WireValue::Int8(v) => v.to_string(),
            WireValue::Int16(v) => v.to_string(),
            WireValue::Int32(v) => v.to_string(),
            WireValue::Int64(v) => v.to_string(),
            WireValue::Float32(v) => v.to_string(),
            WireValue::Float64(v) => v.to_string(),
            WireValue::String(v) => v.clone(),
            WireValue::Bytes(v) => format!("<bytes:{}>", v.len()),
            WireValue::Array(v) => format!("<array:{}>", v.len()),
            WireValue::Object(v) => format!("<object:{}>", v.len()),
            WireValue::Vector(v) => format!("<vector:{}>", v.len()),
            WireValue::Json(v) => v.clone(),
        }
    }

    pub fn serialize(&self) -> Vec<u8> {
        let mut buf = Vec::new();
        self.serialize_into(&mut buf);
        buf
    }

    fn serialize_into(&self, buf: &mut Vec<u8>) {
        match self {
            WireValue::Null => buf.push(FK_NULL),
            WireValue::Bool(v) => { buf.push(FK_BOOL); buf.push(if *v { 1 } else { 0 }); }
            WireValue::Int8(v) => { buf.push(FK_INT8); buf.push(*v as u8); }
            WireValue::Int16(v) => { buf.push(FK_INT16); buf.extend_from_slice(&v.to_be_bytes()); }
            WireValue::Int32(v) => { buf.push(FK_INT32); buf.extend_from_slice(&v.to_be_bytes()); }
            WireValue::Int64(v) => { buf.push(FK_INT64); buf.extend_from_slice(&v.to_be_bytes()); }
            WireValue::Float32(v) => { buf.push(FK_FLOAT32); buf.extend_from_slice(&v.to_be_bytes()); }
            WireValue::Float64(v) => { buf.push(FK_FLOAT64); buf.extend_from_slice(&v.to_be_bytes()); }
            WireValue::String(v) => {
                buf.push(FK_STRING);
                buf.extend_from_slice(&(v.len() as u32).to_be_bytes());
                buf.extend_from_slice(v.as_bytes());
            }
            WireValue::Bytes(v) => {
                buf.push(FK_BYTES);
                buf.extend_from_slice(&(v.len() as u32).to_be_bytes());
                buf.extend_from_slice(v);
            }
            WireValue::Array(v) => {
                buf.push(FK_ARRAY);
                buf.extend_from_slice(&(v.len() as u32).to_be_bytes());
                for item in v {
                    item.serialize_into(buf);
                }
            }
            WireValue::Object(v) => {
                buf.push(FK_OBJECT);
                buf.extend_from_slice(&(v.len() as u32).to_be_bytes());
                for (key, val) in v {
                    buf.extend_from_slice(&(key.len() as u32).to_be_bytes());
                    buf.extend_from_slice(key.as_bytes());
                    val.serialize_into(buf);
                }
            }
            WireValue::Vector(v) => {
                buf.push(FK_VECTOR);
                buf.extend_from_slice(&(v.len() as u32).to_be_bytes());
                for f in v {
                    buf.extend_from_slice(&f.to_be_bytes());
                }
            }
            WireValue::Json(v) => {
                buf.push(FK_JSON);
                buf.extend_from_slice(&(v.len() as u32).to_be_bytes());
                buf.extend_from_slice(v.as_bytes());
            }
        }
    }
}

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
    column_types: Vec<u8>,
    rows: Vec<HashMap<String, WireValue>>,
    affected_rows: usize,
}

impl QueryResult {
    pub fn columns(&self) -> &[String] {
        &self.columns
    }

    pub fn column_types(&self) -> &[u8] {
        &self.column_types
    }

    pub fn rows(&self) -> &[HashMap<String, WireValue>] {
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
    pub fn connect(host: &str, port: u16) -> Result<Self, Box<dyn std::error::Error>> {
        let config = Config {
            host: host.to_string(),
            port,
            ..Default::default()
        };
        Self::connect_with_config(config)
    }

    pub fn connect_with_config(config: Config) -> Result<Self, Box<dyn std::error::Error>> {
        let addr = format!("{}:{}", config.host, config.port);
        let stream = TcpStream::connect(&addr)?;
        stream.set_nodelay(true)?;
        Ok(Client {
            config,
            stream,
            connected: true,
            request_id: 0,
        })
    }

    pub fn close(&mut self) {
        if self.connected {
            let _ = self.send_close();
        }
        self.connected = false;
    }

    pub fn is_connected(&self) -> bool {
        self.connected
    }

    fn next_id(&mut self) -> u32 {
        self.request_id += 1;
        self.request_id
    }

    fn send_close(&mut self) -> Result<(), Box<dyn std::error::Error>> {
        let msg = build_message(MK_CLOSE, self.next_id(), &[]);
        self.stream.write_all(&msg)?;
        Ok(())
    }

    fn read_header(&mut self) -> Result<(u32, u32, u32), Box<dyn std::error::Error>> {
        let mut header = [0u8; 12];
        self.stream.read_exact(&mut header)?;
        let kind = u32::from_be_bytes([header[0], header[1], header[2], header[3]]);
        let length = u32::from_be_bytes([header[4], header[5], header[6], header[7]]);
        let req_id = u32::from_be_bytes([header[8], header[9], header[10], header[11]]);
        Ok((kind, length, req_id))
    }

    fn read_payload(&mut self, length: u32) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
        let mut payload = vec![0u8; length as usize];
        if length > 0 {
            self.stream.read_exact(&mut payload)?;
        }
        Ok(payload)
    }

    fn read_error_message(payload: &[u8]) -> String {
        if payload.len() >= 8 {
            let code = u32::from_be_bytes([payload[0], payload[1], payload[2], payload[3]]);
            let msg_len = u32::from_be_bytes([payload[4], payload[5], payload[6], payload[7]]) as usize;
            if payload.len() >= 8 + msg_len {
                let msg = String::from_utf8_lossy(&payload[8..8 + msg_len]);
                return format!("BaraDB error {}: {}", code, msg);
            }
        }
        "Query error".to_string()
    }

    fn read_data_response(&mut self, payload: &[u8]) -> Result<QueryResult, Box<dyn std::error::Error>> {
        let mut pos = 0usize;
        let col_count = read_u32(payload, &mut pos) as usize;

        let mut columns = Vec::with_capacity(col_count);
        for _ in 0..col_count {
            columns.push(read_string(payload, &mut pos));
        }

        let mut col_types = Vec::with_capacity(col_count);
        for _ in 0..col_count {
            col_types.push(payload[pos]);
            pos += 1;
        }

        let row_count = read_u32(payload, &mut pos) as usize;
        let mut rows = Vec::with_capacity(row_count);
        for _ in 0..row_count {
            let mut row = HashMap::new();
            for c in 0..col_count {
                let val = read_wire_value(payload, &mut pos);
                row.insert(columns[c].clone(), val);
            }
            rows.push(row);
        }

        let mut affected = 0usize;
        let (comp_kind, comp_len, _) = self.read_header()?;
        if comp_kind == MK_COMPLETE {
            let comp_payload = self.read_payload(comp_len)?;
            if comp_payload.len() >= 4 {
                affected = u32::from_be_bytes([comp_payload[0], comp_payload[1], comp_payload[2], comp_payload[3]]) as usize;
            }
        }

        Ok(QueryResult { columns, column_types: col_types, rows, affected_rows: affected })
    }

    pub fn auth(&mut self, token: &str) -> Result<(), Box<dyn std::error::Error>> {
        if !self.connected {
            return Err("Not connected".into());
        }
        let payload = encode_string(token);
        let msg = build_message(MK_AUTH, self.next_id(), &payload);
        self.stream.write_all(&msg)?;

        let (kind, length, _) = self.read_header()?;
        match kind {
            MK_AUTH_OK => Ok(()),
            MK_ERROR => {
                let p = self.read_payload(length)?;
                Err(Self::read_error_message(&p).into())
            }
            _ => Err(format!("Unexpected auth response: 0x{:02x}", kind).into()),
        }
    }

    pub fn ping(&mut self) -> Result<bool, Box<dyn std::error::Error>> {
        if !self.connected {
            return Err("Not connected".into());
        }
        let msg = build_message(MK_PING, self.next_id(), &[]);
        self.stream.write_all(&msg)?;

        let (kind, length, _) = self.read_header()?;
        match kind {
            MK_PONG => Ok(true),
            MK_ERROR => {
                let p = self.read_payload(length)?;
                Err(Self::read_error_message(&p).into())
            }
            _ => Ok(false),
        }
    }

    pub fn query(&mut self, sql: &str) -> Result<QueryResult, Box<dyn std::error::Error>> {
        if !self.connected {
            return Err("Not connected".into());
        }

        let mut payload = encode_string(sql);
        payload.push(0x00); // ResultFormat::BINARY

        let msg = build_message(MK_QUERY, self.next_id(), &payload);
        self.stream.write_all(&msg)?;

        let (kind, length, _) = self.read_header()?;
        let resp_payload = self.read_payload(length)?;

        match kind {
            MK_READY => Ok(QueryResult { columns: vec![], column_types: vec![], rows: vec![], affected_rows: 0 }),
            MK_DATA => self.read_data_response(&resp_payload),
            MK_COMPLETE => {
                let affected = if resp_payload.len() >= 4 {
                    u32::from_be_bytes([resp_payload[0], resp_payload[1], resp_payload[2], resp_payload[3]]) as usize
                } else { 0 };
                Ok(QueryResult { columns: vec![], column_types: vec![], rows: vec![], affected_rows: affected })
            }
            MK_ERROR => Err(Self::read_error_message(&resp_payload).into()),
            _ => Err(format!("Unknown response kind: {}", kind).into()),
        }
    }

    pub fn query_params(&mut self, sql: &str, params: &[WireValue]) -> Result<QueryResult, Box<dyn std::error::Error>> {
        if !self.connected {
            return Err("Not connected".into());
        }

        let mut payload = encode_string(sql);
        payload.push(0x00); // ResultFormat::BINARY
        payload.extend_from_slice(&(params.len() as u32).to_be_bytes());
        for p in params {
            p.serialize_into(&mut payload);
        }

        let msg = build_message(MK_QUERY_PARAMS, self.next_id(), &payload);
        self.stream.write_all(&msg)?;

        let (kind, length, _) = self.read_header()?;
        let resp_payload = self.read_payload(length)?;

        match kind {
            MK_READY => Ok(QueryResult { columns: vec![], column_types: vec![], rows: vec![], affected_rows: 0 }),
            MK_DATA => self.read_data_response(&resp_payload),
            MK_COMPLETE => {
                let affected = if resp_payload.len() >= 4 {
                    u32::from_be_bytes([resp_payload[0], resp_payload[1], resp_payload[2], resp_payload[3]]) as usize
                } else { 0 };
                Ok(QueryResult { columns: vec![], column_types: vec![], rows: vec![], affected_rows: affected })
            }
            MK_ERROR => Err(Self::read_error_message(&resp_payload).into()),
            _ => Err(format!("Unknown response kind: {}", kind).into()),
        }
    }

    pub fn execute(&mut self, sql: &str) -> Result<usize, Box<dyn std::error::Error>> {
        let result = self.query(sql)?;
        Ok(result.affected_rows())
    }
}

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

fn read_wire_value(data: &[u8], pos: &mut usize) -> WireValue {
    let kind = data[*pos];
    *pos += 1;
    match kind {
        FK_NULL => WireValue::Null,
        FK_BOOL => {
            let val = data[*pos] != 0;
            *pos += 1;
            WireValue::Bool(val)
        }
        FK_INT8 => {
            let val = data[*pos] as i8;
            *pos += 1;
            WireValue::Int8(val)
        }
        FK_INT16 => {
            let val = i16::from_be_bytes([data[*pos], data[*pos + 1]]);
            *pos += 2;
            WireValue::Int16(val)
        }
        FK_INT32 => {
            let val = i32::from_be_bytes([data[*pos], data[*pos + 1], data[*pos + 2], data[*pos + 3]]);
            *pos += 4;
            WireValue::Int32(val)
        }
        FK_INT64 => {
            let val = i64::from_be_bytes([
                data[*pos], data[*pos + 1], data[*pos + 2], data[*pos + 3],
                data[*pos + 4], data[*pos + 5], data[*pos + 6], data[*pos + 7],
            ]);
            *pos += 8;
            WireValue::Int64(val)
        }
        FK_FLOAT32 => {
            let val = f32::from_be_bytes([data[*pos], data[*pos + 1], data[*pos + 2], data[*pos + 3]]);
            *pos += 4;
            WireValue::Float32(val)
        }
        FK_FLOAT64 => {
            let val = f64::from_be_bytes([
                data[*pos], data[*pos + 1], data[*pos + 2], data[*pos + 3],
                data[*pos + 4], data[*pos + 5], data[*pos + 6], data[*pos + 7],
            ]);
            *pos += 8;
            WireValue::Float64(val)
        }
        FK_STRING => WireValue::String(read_string(data, pos)),
        FK_BYTES => {
            let len = read_u32(data, pos) as usize;
            let bytes = data[*pos..*pos + len].to_vec();
            *pos += len;
            WireValue::Bytes(bytes)
        }
        FK_ARRAY => {
            let count = read_u32(data, pos) as usize;
            let mut arr = Vec::with_capacity(count);
            for _ in 0..count {
                arr.push(read_wire_value(data, pos));
            }
            WireValue::Array(arr)
        }
        FK_OBJECT => {
            let count = read_u32(data, pos) as usize;
            let mut obj = Vec::with_capacity(count);
            for _ in 0..count {
                let key = read_string(data, pos);
                let val = read_wire_value(data, pos);
                obj.push((key, val));
            }
            WireValue::Object(obj)
        }
        FK_VECTOR => {
            let dim = read_u32(data, pos) as usize;
            let mut vec = Vec::with_capacity(dim);
            for _ in 0..dim {
                let f = f32::from_be_bytes([data[*pos], data[*pos + 1], data[*pos + 2], data[*pos + 3]]);
                *pos += 4;
                vec.push(f);
            }
            WireValue::Vector(vec)
        }
        FK_JSON => WireValue::Json(read_string(data, pos)),
        _ => WireValue::Null,
    }
}
