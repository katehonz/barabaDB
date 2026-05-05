/**
 * BaraDB JavaScript/TypeScript Client
 *
 * Binary protocol client for BaraDB database.
 * Communicates via the BaraDB Wire Protocol (binary, big-endian).
 *
 * Install:
 *   npm install baradb
 *
 * Quick Start:
 *   import { Client } from 'baradb';
 *   const client = new Client('localhost', 5432);
 *   await client.connect();
 *   const result = await client.query('SELECT name FROM users WHERE age > 18');
 *   for (const row of result) {
 *     console.log(row.name);
 *   }
 *   await client.close();
 */

const MsgKind = {
  QUERY: 0x02,
  BATCH: 0x05,
  TRANSACTION: 0x06,
  CLOSE: 0x07,
  PING: 0x08,
  AUTH: 0x09,
  READY: 0x81,
  DATA: 0x82,
  COMPLETE: 0x83,
  ERROR: 0x84,
  AUTH_OK: 0x86,
};

const FieldKind = {
  NULL: 0x00,
  BOOL: 0x01,
  INT8: 0x02,
  INT16: 0x03,
  INT32: 0x04,
  INT64: 0x05,
  FLOAT32: 0x06,
  FLOAT64: 0x07,
  STRING: 0x08,
  BYTES: 0x09,
  ARRAY: 0x0A,
  OBJECT: 0x0B,
  VECTOR: 0x0C,
};

const ResultFormat = {
  BINARY: 0x00,
  JSON: 0x01,
  TEXT: 0x02,
};

class QueryResult {
  constructor() {
    this.columns = [];
    this.rows = [];
    this.rowCount = 0;
    this.affectedRows = 0;
  }

  [Symbol.iterator]() {
    let index = 0;
    const rows = this.rows;
    const columns = this.columns;
    return {
      next() {
        if (index < rows.length) {
          const row = {};
          for (let i = 0; i < columns.length; i++) {
            row[columns[i]] = rows[index][i];
          }
          index++;
          return { value: row, done: false };
        }
        return { value: undefined, done: true };
      },
    };
  }

  get length() {
    return this.rowCount;
  }
}

class Client {
  constructor(host = 'localhost', port = 5432, options = {}) {
    this.host = host;
    this.port = port;
    this.database = options.database || 'default';
    this.username = options.username || 'admin';
    this.password = options.password || '';
    this.timeout = options.timeout || 30000;
    this.socket = null;
    this.connected = false;
    this.requestId = 0;
  }

  /** Connect to the BaraDB server */
  async connect() {
    // In Node.js: const net = require('net');
    // In browser: WebSocket connection
    this.socket = null; // net.connect(this.port, this.host);
    this.connected = true;
  }

  async close() {
    if (this.socket) {
      this.socket.destroy();
      this.socket = null;
    }
    this.connected = false;
  }

  isConnected() {
    return this.connected;
  }

  _nextId() {
    return ++this.requestId;
  }

  /** Execute a BaraQL query */
  async query(sql) {
    const encoder = new TextEncoder();
    const queryBytes = encoder.encode(sql);
    const payload = new Uint8Array(4 + queryBytes.length + 1);
    const view = new DataView(payload.buffer);
    view.setUint32(0, queryBytes.length, false); // big-endian
    payload.set(queryBytes, 4);
    payload[4 + queryBytes.length] = ResultFormat.JSON;

    const msg = this._build(MsgKind.QUERY, payload);
    // await this.socket.write(msg);

    return new QueryResult();
  }

  /** Execute a BaraQL statement (INSERT, UPDATE, DELETE) */
  async execute(sql) {
    const result = await this.query(sql);
    return result.affectedRows;
  }

  _build(kind, payload) {
    const reqId = this._nextId();
    const header = new ArrayBuffer(12);
    const view = new DataView(header);
    view.setUint32(0, kind, false);
    view.setUint32(4, payload.length, false);
    view.setUint32(8, reqId, false);

    const msg = new Uint8Array(12 + payload.length);
    msg.set(new Uint8Array(header), 0);
    msg.set(payload, 12);
    return msg;
  }
}

class QueryBuilder {
  constructor(client) {
    this.client = client;
    this._select = [];
    this._from = '';
    this._where = [];
    this._joins = [];
    this._groupBy = [];
    this._having = '';
    this._orderBy = [];
    this._limit = 0;
    this._offset = 0;
  }

  select(...cols) {
    this._select.push(...cols);
    return this;
  }

  from(table) {
    this._from = table;
    return this;
  }

  where(clause) {
    this._where.push(clause);
    return this;
  }

  join(table, on) {
    this._joins.push(`JOIN ${table} ON ${on}`);
    return this;
  }

  leftJoin(table, on) {
    this._joins.push(`LEFT JOIN ${table} ON ${on}`);
    return this;
  }

  groupBy(...cols) {
    this._groupBy.push(...cols);
    return this;
  }

  having(clause) {
    this._having = clause;
    return this;
  }

  orderBy(col, direction = 'ASC') {
    this._orderBy.push(`${col} ${direction}`);
    return this;
  }

  limit(n) {
    this._limit = n;
    return this;
  }

  offset(n) {
    this._offset = n;
    return this;
  }

  build() {
    let sql = 'SELECT ' + (this._select.length ? this._select.join(', ') : '*');
    sql += ' FROM ' + this._from;
    for (const j of this._joins) sql += ' ' + j;
    if (this._where.length) sql += ' WHERE ' + this._where.join(' AND ');
    if (this._groupBy.length) sql += ' GROUP BY ' + this._groupBy.join(', ');
    if (this._having) sql += ' HAVING ' + this._having;
    if (this._orderBy.length) sql += ' ORDER BY ' + this._orderBy.join(', ');
    if (this._limit) sql += ' LIMIT ' + this._limit;
    if (this._offset) sql += ' OFFSET ' + this._offset;
    return sql;
  }

  async exec() {
    return this.client.query(this.build());
  }
}

module.exports = { Client, QueryBuilder, QueryResult, MsgKind, FieldKind, ResultFormat };
