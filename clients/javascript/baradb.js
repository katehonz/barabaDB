/**
 * BaraDB JavaScript/TypeScript Client
 *
 * Binary protocol client for BaraDB database.
 * Communicates via the BaraDB Wire Protocol (binary, big-endian).
 * Requires Node.js (uses 'net' module for TCP).
 *
 * Install:
 *   npm install baradb
 *
 * Quick Start:
 *   import { Client } from 'baradb';
 *   const client = new Client('localhost', 9472);
 *   await client.connect();
 *   const result = await client.query('SELECT name FROM users WHERE age > 18');
 *   for (const row of result) {
 *     console.log(row.name);
 *   }
 *   await client.close();
 *
 * Parameterized Queries:
 *   const result = await client.queryParams(
 *     'SELECT * FROM users WHERE age > $1',
 *     [WireValue.int64(18)]
 *   );
 *
 * Authentication:
 *   await client.auth('jwt-token-here');
 */

const net = require('net');

const MsgKind = Object.freeze({
  CLIENT_HANDSHAKE: 0x01,
  QUERY: 0x02,
  QUERY_PARAMS: 0x03,
  EXECUTE: 0x04,
  BATCH: 0x05,
  TRANSACTION: 0x06,
  CLOSE: 0x07,
  PING: 0x08,
  AUTH: 0x09,
  SERVER_HANDSHAKE: 0x80,
  READY: 0x81,
  DATA: 0x82,
  COMPLETE: 0x83,
  ERROR: 0x84,
  AUTH_CHALLENGE: 0x85,
  AUTH_OK: 0x86,
  SCHEMA_CHANGE: 0x87,
  PONG: 0x88,
  TRANSACTION_STATE: 0x89,
});

const FieldKind = Object.freeze({
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
  JSON: 0x0D,
});

const ResultFormat = Object.freeze({
  BINARY: 0x00,
  JSON: 0x01,
  TEXT: 0x02,
});

class WireValue {
  constructor(kind, value) {
    this.kind = kind;
    this.value = value;
  }

  static null() { return new WireValue(FieldKind.NULL); }
  static bool(val) { return new WireValue(FieldKind.BOOL, val); }
  static int8(val) { return new WireValue(FieldKind.INT8, val); }
  static int16(val) { return new WireValue(FieldKind.INT16, val); }
  static int32(val) { return new WireValue(FieldKind.INT32, val); }
  static int64(val) { return new WireValue(FieldKind.INT64, val); }
  static float32(val) { return new WireValue(FieldKind.FLOAT32, val); }
  static float64(val) { return new WireValue(FieldKind.FLOAT64, val); }
  static string(val) { return new WireValue(FieldKind.STRING, val); }
  static bytes(val) { return new WireValue(FieldKind.BYTES, val); }
  static array(val) { return new WireValue(FieldKind.ARRAY, val); }
  static object(val) { return new WireValue(FieldKind.OBJECT, val); }
  static vector(val) { return new WireValue(FieldKind.VECTOR, val); }
  static json(val) { return new WireValue(FieldKind.JSON, val); }

  serialize() {
    const parts = [Buffer.from([this.kind])];
    switch (this.kind) {
      case FieldKind.NULL:
        break;
      case FieldKind.BOOL:
        parts.push(Buffer.from([this.value ? 1 : 0]));
        break;
      case FieldKind.INT8: {
        const b = Buffer.alloc(1);
        b.writeInt8(this.value, 0);
        parts.push(b);
        break;
      }
      case FieldKind.INT16: {
        const b = Buffer.alloc(2);
        b.writeInt16BE(this.value, 0);
        parts.push(b);
        break;
      }
      case FieldKind.INT32: {
        const b = Buffer.alloc(4);
        b.writeInt32BE(this.value, 0);
        parts.push(b);
        break;
      }
      case FieldKind.INT64: {
        const b = Buffer.alloc(8);
        b.writeBigInt64BE(BigInt(this.value), 0);
        parts.push(b);
        break;
      }
      case FieldKind.FLOAT32: {
        const b = Buffer.alloc(4);
        b.writeFloatBE(this.value, 0);
        parts.push(b);
        break;
      }
      case FieldKind.FLOAT64: {
        const b = Buffer.alloc(8);
        b.writeDoubleBE(this.value, 0);
        parts.push(b);
        break;
      }
      case FieldKind.STRING: {
        const strBuf = Buffer.from(this.value, 'utf-8');
        const len = Buffer.alloc(4);
        len.writeUInt32BE(strBuf.length, 0);
        parts.push(len, strBuf);
        break;
      }
      case FieldKind.BYTES: {
        const len = Buffer.alloc(4);
        len.writeUInt32BE(this.value.length, 0);
        parts.push(len, this.value);
        break;
      }
      case FieldKind.ARRAY: {
        const count = Buffer.alloc(4);
        count.writeUInt32BE(this.value.length, 0);
        parts.push(count);
        for (const item of this.value) {
          parts.push(item.serialize());
        }
        break;
      }
      case FieldKind.OBJECT: {
        const entries = Object.entries(this.value);
        const count = Buffer.alloc(4);
        count.writeUInt32BE(entries.length, 0);
        parts.push(count);
        for (const [key, val] of entries) {
          const keyBuf = Buffer.from(key, 'utf-8');
          const keyLen = Buffer.alloc(4);
          keyLen.writeUInt32BE(keyBuf.length, 0);
          parts.push(keyLen, keyBuf, val.serialize());
        }
        break;
      }
      case FieldKind.VECTOR: {
        const dim = Buffer.alloc(4);
        dim.writeUInt32BE(this.value.length, 0);
        parts.push(dim);
        for (const f of this.value) {
          const fb = Buffer.alloc(4);
          fb.writeFloatBE(f, 0);
          parts.push(fb);
        }
        break;
      }
      case FieldKind.JSON: {
        const strBuf = Buffer.from(this.value, 'utf-8');
        const len = Buffer.alloc(4);
        len.writeUInt32BE(strBuf.length, 0);
        parts.push(len, strBuf);
        break;
      }
    }
    return Buffer.concat(parts);
  }
}

class QueryResult {
  constructor() {
    this.columns = [];
    this.columnTypes = [];
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
  constructor(host = 'localhost', port = 9472, options = {}) {
    this.host = host;
    this.port = port;
    this.database = options.database || 'default';
    this.username = options.username || 'admin';
    this.password = options.password || '';
    this.timeout = options.timeout || 30000;
    this.socket = null;
    this.connected = false;
    this.requestId = 0;
    this._buffer = Buffer.alloc(0);
    this._pendingResolve = null;
    this._requestQueue = [];
    this._requestLock = false;
  }

  async connect() {
    return new Promise((resolve, reject) => {
      this.socket = net.createConnection({ host: this.host, port: this.port });
      this.socket.setTimeout(this.timeout);

      this.socket.on('connect', () => {
        this.connected = true;
        resolve();
      });

      this.socket.on('data', (data) => {
        this._buffer = Buffer.concat([this._buffer, data]);
        if (this._pendingResolve) {
          this._pendingResolve();
        }
      });

      this.socket.on('error', (err) => {
        this.connected = false;
        reject(err);
      });

      this.socket.on('close', () => {
        this.connected = false;
      });

      this.socket.on('timeout', () => {
        this.socket.destroy();
        this.connected = false;
      });
    });
  }

  async close() {
    if (this.socket && this.connected) {
      try {
        const msg = this._build(MsgKind.CLOSE, Buffer.alloc(0));
        this.socket.write(msg);
      } catch (_) {}
    }
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

  async _recvExact(size) {
    while (this._buffer.length < size) {
      await new Promise((resolve, reject) => {
        this._pendingResolve = resolve;
        const timer = setTimeout(() => {
          this._pendingResolve = null;
          reject(new Error('Receive timeout'));
        }, this.timeout);
        this._pendingResolve = () => {
          clearTimeout(timer);
          this._pendingResolve = null;
          resolve();
        };
      });
    }
    const data = this._buffer.subarray(0, size);
    this._buffer = this._buffer.subarray(size);
    return data;
  }

  async _readHeader() {
    const header = await this._recvExact(12);
    return {
      kind: header.readUInt32BE(0),
      length: header.readUInt32BE(4),
      requestId: header.readUInt32BE(8),
    };
  }

  async _readError(length) {
    const data = await this._recvExact(length);
    const code = data.readUInt32BE(0);
    const msgLen = data.readUInt32BE(4);
    const msg = data.subarray(8, 8 + msgLen).toString('utf-8');
    return new Error(`BaraDB error ${code}: ${msg}`);
  }

  async _readDataResponse(length) {
    const data = await this._recvExact(length);
    const result = new QueryResult();
    let pos = 0;

    const colCount = data.readUInt32BE(pos);
    pos += 4;

    const cols = [];
    for (let i = 0; i < colCount; i++) {
      const sLen = data.readUInt32BE(pos);
      pos += 4;
      cols.push(data.subarray(pos, pos + sLen).toString('utf-8'));
      pos += sLen;
    }

    const colTypes = [];
    for (let i = 0; i < colCount; i++) {
      colTypes.push(data[pos]);
      pos++;
    }

    const rowCount = data.readUInt32BE(pos);
    pos += 4;

    for (let r = 0; r < rowCount; r++) {
      const row = [];
      for (let c = 0; c < colCount; c++) {
        const { value, newPos } = this._readValue(data, pos);
        row.push(value);
        pos = newPos;
      }
      result.rows.push(row);
    }

    result.columns = cols;
    result.columnTypes = colTypes;
    result.rowCount = rowCount;

    const comp = await this._readHeader();
    if (comp.kind === MsgKind.COMPLETE) {
      const compData = await this._recvExact(comp.length);
      result.affectedRows = compData.readUInt32BE(0);
    } else if (comp.kind === MsgKind.ERROR) {
      throw await this._readError(comp.length);
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
      case FieldKind.INT8: result = payload.readInt8(pos); pos++; break;
      case FieldKind.INT16: result = payload.readInt16BE(pos); pos += 2; break;
      case FieldKind.INT32: result = payload.readInt32BE(pos); pos += 4; break;
      case FieldKind.INT64: result = payload.readBigInt64BE(pos); pos += 8; break;
      case FieldKind.FLOAT32: result = payload.readFloatBE(pos); pos += 4; break;
      case FieldKind.FLOAT64: result = payload.readDoubleBE(pos); pos += 8; break;
      case FieldKind.STRING: {
        const len = payload.readUInt32BE(pos);
        pos += 4;
        result = payload.subarray(pos, pos + len).toString('utf-8');
        pos += len;
        break;
      }
      case FieldKind.BYTES: {
        const len = payload.readUInt32BE(pos);
        pos += 4;
        result = payload.subarray(pos, pos + len);
        pos += len;
        break;
      }
      case FieldKind.ARRAY: {
        const count = payload.readUInt32BE(pos);
        pos += 4;
        result = [];
        for (let i = 0; i < count; i++) {
          const { value, newPos } = this._readValue(payload, pos);
          result.push(value);
          pos = newPos;
        }
        break;
      }
      case FieldKind.OBJECT: {
        const count = payload.readUInt32BE(pos);
        pos += 4;
        result = {};
        for (let i = 0; i < count; i++) {
          const kLen = payload.readUInt32BE(pos);
          pos += 4;
          const key = payload.subarray(pos, pos + kLen).toString('utf-8');
          pos += kLen;
          const { value, newPos } = this._readValue(payload, pos);
          result[key] = value;
          pos = newPos;
        }
        break;
      }
      case FieldKind.VECTOR: {
        const dim = payload.readUInt32BE(pos);
        pos += 4;
        result = [];
        for (let i = 0; i < dim; i++) {
          result.push(payload.readFloatBE(pos));
          pos += 4;
        }
        break;
      }
      case FieldKind.JSON: {
        const len = payload.readUInt32BE(pos);
        pos += 4;
        result = payload.subarray(pos, pos + len).toString('utf-8');
        pos += len;
        break;
      }
      default: result = null;
    }
    return { value: result, newPos: pos };
  }

  async auth(token) {
    if (!this.connected) throw new Error('Not connected');
    const tokenBuf = Buffer.from(token, 'utf-8');
    const payload = Buffer.alloc(4 + tokenBuf.length);
    payload.writeUInt32BE(tokenBuf.length, 0);
    tokenBuf.copy(payload, 4);
    const msg = this._build(MsgKind.AUTH, payload);
    this.socket.write(msg);

    const header = await this._readHeader();
    if (header.kind === MsgKind.AUTH_OK) return;
    if (header.kind === MsgKind.ERROR) throw await this._readError(header.length);
    throw new Error(`Unexpected auth response: 0x${header.kind.toString(16)}`);
  }

  async _processQueue() {
    if (this._requestLock || this._requestQueue.length === 0) return;
    this._requestLock = true;
    const { task, resolve, reject } = this._requestQueue.shift();
    try {
      const result = await task();
      resolve(result);
    } catch (err) {
      reject(err);
    } finally {
      this._requestLock = false;
      setImmediate(() => this._processQueue());
    }
  }

  _enqueue(task) {
    return new Promise((resolve, reject) => {
      this._requestQueue.push({ task, resolve, reject });
      this._processQueue();
    });
  }

  async ping() {
    if (!this.connected) throw new Error('Not connected');
    return this._enqueue(async () => {
      const msg = this._build(MsgKind.PING, Buffer.alloc(0));
      this.socket.write(msg);

      const header = await this._readHeader();
      if (header.kind === MsgKind.PONG) return true;
      if (header.kind === MsgKind.ERROR) throw await this._readError(header.length);
      return false;
    });
  }

  async query(sql) {
    if (!this.connected) throw new Error('Not connected');
    return this._enqueue(async () => {
      const queryBuf = Buffer.from(sql, 'utf-8');
      const payload = Buffer.alloc(4 + queryBuf.length + 1);
      payload.writeUInt32BE(queryBuf.length, 0);
      queryBuf.copy(payload, 4);
      payload[4 + queryBuf.length] = ResultFormat.BINARY;

      const msg = this._build(MsgKind.QUERY, payload);
      this.socket.write(msg);

      const header = await this._readHeader();
      if (header.kind === MsgKind.ERROR) throw await this._readError(header.length);
      if (header.kind === MsgKind.DATA) return await this._readDataResponse(header.length);
      if (header.kind === MsgKind.COMPLETE) {
        const data = await this._recvExact(header.length);
        const result = new QueryResult();
        result.affectedRows = data.readUInt32BE(0);
        return result;
      }
      return new QueryResult();
    });
  }

  async queryParams(sql, params = []) {
    if (!this.connected) throw new Error('Not connected');
    return this._enqueue(async () => {
      const queryBuf = Buffer.from(sql, 'utf-8');
      const paramParts = [];
      for (const p of params) {
        paramParts.push(p.serialize());
      }
      const paramsBuf = Buffer.concat(paramParts);

      const payload = Buffer.alloc(4 + queryBuf.length + 1 + 4 + paramsBuf.length);
      let pos = 0;
      payload.writeUInt32BE(queryBuf.length, pos); pos += 4;
      queryBuf.copy(payload, pos); pos += queryBuf.length;
      payload[pos] = ResultFormat.BINARY; pos++;
      payload.writeUInt32BE(params.length, pos); pos += 4;
      paramsBuf.copy(payload, pos);

      const msg = this._build(MsgKind.QUERY_PARAMS, payload);
      this.socket.write(msg);

      const header = await this._readHeader();
      if (header.kind === MsgKind.ERROR) throw await this._readError(header.length);
      if (header.kind === MsgKind.DATA) return await this._readDataResponse(header.length);
      if (header.kind === MsgKind.COMPLETE) {
        const data = await this._recvExact(header.length);
        const result = new QueryResult();
        result.affectedRows = data.readUInt32BE(0);
        return result;
      }
      return new QueryResult();
    });
  }

  async execute(sql) {
    const result = await this.query(sql);
    return result.affectedRows;
  }

  _build(kind, payload) {
    const reqId = this._nextId();
    const header = Buffer.alloc(12);
    header.writeUInt32BE(kind, 0);
    header.writeUInt32BE(payload.length, 4);
    header.writeUInt32BE(reqId, 8);
    return Buffer.concat([header, payload]);
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

module.exports = { Client, QueryBuilder, QueryResult, WireValue, MsgKind, FieldKind, ResultFormat };
