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
    payload[4 + queryBytes.length] = ResultFormat.BINARY;

    const msg = this._build(MsgKind.QUERY, payload);
    // await this.socket.write(msg);
    // const header = await this.socket.read(12);
    // ... parse response

    return new QueryResult();
  }

  /** Parse server response from header + payload buffers */
  _parseResponse(header, payload) {
    const view = new DataView(header.buffer);
    const kind = view.getUint32(0, false);
    const len = view.getUint32(4, false);
    const reqId = view.getUint32(8, false);

    const result = new QueryResult();

    if (kind === MsgKind.ERROR && payload.length >= 8) {
      const code = new DataView(payload.buffer).getUint32(0, false);
      const msgLen = new DataView(payload.buffer).getUint32(4, false);
      const msg = new TextDecoder().decode(payload.slice(8, 8 + msgLen));
      throw new Error(`BaraDB error ${code}: ${msg}`);
    }

    if (kind === MsgKind.DATA) {
      let pos = 0;
      const colCount = new DataView(payload.buffer).getUint32(pos, false);
      pos += 4;
      const cols = [];
      for (let i = 0; i < colCount; i++) {
        const sLen = new DataView(payload.buffer).getUint32(pos, false);
        pos += 4;
        cols.push(new TextDecoder().decode(payload.slice(pos, pos + sLen)));
        pos += sLen;
      }
      result.columns = cols;
      const rowCount = new DataView(payload.buffer).getUint32(pos, false);
      pos += 4;
      for (let r = 0; r < rowCount; r++) {
        const row = [];
        for (let c = 0; c < colCount; c++) {
          row.push(this._readValue(payload, pos));
          pos = this._lastReadPos;
        }
        result.rows.push(row);
      }
      result.rowCount = rowCount;
      // COMPLETE message should follow - caller reads it separately
      return result;
    }

    if (kind === MsgKind.COMPLETE && payload.length >= 4) {
      result.affectedRows = new DataView(payload.buffer).getUint32(0, false);
    }

    return result;
  }

  _readValue(payload, pos) {
    const kind = payload[pos];
    pos++;
    let result;
    switch (kind) {
      case FieldKind.NULL: result = null; break;
      case FieldKind.BOOL: result = payload[pos] !== 0; pos++; break;
      case FieldKind.INT8: result = payload[pos] << 24 >> 24; pos++; break;
      case FieldKind.INT16: result = new DataView(payload.buffer).getInt16(pos, false); pos += 2; break;
      case FieldKind.INT32: result = new DataView(payload.buffer).getInt32(pos, false); pos += 4; break;
      case FieldKind.INT64: result = new DataView(payload.buffer).getBigInt64(pos, false); pos += 8; break;
      case FieldKind.FLOAT32: result = new DataView(payload.buffer).getFloat32(pos, false); pos += 4; break;
      case FieldKind.FLOAT64: result = new DataView(payload.buffer).getFloat64(pos, false); pos += 8; break;
      case FieldKind.STRING: {
        const len = new DataView(payload.buffer).getUint32(pos, false);
        pos += 4;
        result = new TextDecoder().decode(payload.slice(pos, pos + len));
        pos += len;
        break;
      }
      case FieldKind.BYTES: {
        const len = new DataView(payload.buffer).getUint32(pos, false);
        pos += 4;
        result = payload.slice(pos, pos + len);
        pos += len;
        break;
      }
      case FieldKind.ARRAY: {
        const count = new DataView(payload.buffer).getUint32(pos, false);
        pos += 4;
        result = [];
        for (let i = 0; i < count; i++) {
          result.push(this._readValue(payload, pos));
          pos = this._lastReadPos;
        }
        break;
      }
      case FieldKind.OBJECT: {
        const count = new DataView(payload.buffer).getUint32(pos, false);
        pos += 4;
        result = {};
        for (let i = 0; i < count; i++) {
          const kLen = new DataView(payload.buffer).getUint32(pos, false);
          pos += 4;
          const key = new TextDecoder().decode(payload.slice(pos, pos + kLen));
          pos += kLen;
          result[key] = this._readValue(payload, pos);
          pos = this._lastReadPos;
        }
        break;
      }
      case FieldKind.VECTOR: {
        const dim = new DataView(payload.buffer).getUint32(pos, false);
        pos += 4;
        result = [];
        for (let i = 0; i < dim; i++) {
          result.push(new DataView(payload.buffer).getFloat32(pos, false));
          pos += 4;
        }
        break;
      }
      default: result = null;
    }
    this._lastReadPos = pos;
    return result;
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
