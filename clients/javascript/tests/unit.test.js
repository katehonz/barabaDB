/**
 * BaraDB JavaScript Client — Unit Tests
 * No running server required.
 */

const { describe, it } = require('node:test');
const assert = require('node:assert');
const { WireValue, FieldKind, MsgKind, ResultFormat, Client, QueryBuilder } = require('../baradb');

describe('WireValue serialization', () => {
  it('serializes null', () => {
    const wv = WireValue.null();
    const buf = wv.serialize();
    assert.strictEqual(buf.length, 1);
    assert.strictEqual(buf[0], FieldKind.NULL);
  });

  it('serializes bool true', () => {
    const wv = WireValue.bool(true);
    const buf = wv.serialize();
    assert.strictEqual(buf[0], FieldKind.BOOL);
    assert.strictEqual(buf[1], 1);
  });

  it('serializes bool false', () => {
    const wv = WireValue.bool(false);
    const buf = wv.serialize();
    assert.strictEqual(buf[0], FieldKind.BOOL);
    assert.strictEqual(buf[1], 0);
  });

  it('serializes int8', () => {
    const wv = WireValue.int8(-42);
    const buf = wv.serialize();
    assert.strictEqual(buf[0], FieldKind.INT8);
    assert.strictEqual(buf.readInt8(1), -42);
  });

  it('serializes int16', () => {
    const wv = WireValue.int16(-1000);
    const buf = wv.serialize();
    assert.strictEqual(buf[0], FieldKind.INT16);
    assert.strictEqual(buf.readInt16BE(1), -1000);
  });

  it('serializes int32', () => {
    const wv = WireValue.int32(123456);
    const buf = wv.serialize();
    assert.strictEqual(buf[0], FieldKind.INT32);
    assert.strictEqual(buf.readInt32BE(1), 123456);
  });

  it('serializes int64', () => {
    const wv = WireValue.int64(9999999999n);
    const buf = wv.serialize();
    assert.strictEqual(buf[0], FieldKind.INT64);
    assert.strictEqual(buf.readBigInt64BE(1), 9999999999n);
  });

  it('serializes float32', () => {
    const wv = WireValue.float32(3.14);
    const buf = wv.serialize();
    assert.strictEqual(buf[0], FieldKind.FLOAT32);
    assert.ok(Math.abs(buf.readFloatBE(1) - 3.14) < 0.01);
  });

  it('serializes float64', () => {
    const wv = WireValue.float64(2.718281828);
    const buf = wv.serialize();
    assert.strictEqual(buf[0], FieldKind.FLOAT64);
    assert.ok(Math.abs(buf.readDoubleBE(1) - 2.718281828) < 1e-9);
  });

  it('serializes string', () => {
    const wv = WireValue.string('hello');
    const buf = wv.serialize();
    assert.strictEqual(buf[0], FieldKind.STRING);
    assert.strictEqual(buf.readUInt32BE(1), 5);
    assert.strictEqual(buf.subarray(5).toString('utf-8'), 'hello');
  });

  it('serializes bytes', () => {
    const wv = WireValue.bytes(Buffer.from([0xde, 0xad, 0xbe, 0xef]));
    const buf = wv.serialize();
    assert.strictEqual(buf[0], FieldKind.BYTES);
    assert.strictEqual(buf.readUInt32BE(1), 4);
    assert.deepStrictEqual(buf.subarray(5), Buffer.from([0xde, 0xad, 0xbe, 0xef]));
  });

  it('serializes vector', () => {
    const wv = WireValue.vector([1.0, 2.0, 3.0]);
    const buf = wv.serialize();
    assert.strictEqual(buf[0], FieldKind.VECTOR);
    assert.strictEqual(buf.readUInt32BE(1), 3);
    const floats = [buf.readFloatBE(5), buf.readFloatBE(9), buf.readFloatBE(13)];
    assert.deepStrictEqual(floats, [1.0, 2.0, 3.0]);
  });

  it('serializes json', () => {
    const wv = WireValue.json('{"key":"value"}');
    const buf = wv.serialize();
    assert.strictEqual(buf[0], FieldKind.JSON);
    assert.strictEqual(buf.readUInt32BE(1), 15);
  });

  it('serializes array', () => {
    const wv = WireValue.array([WireValue.string('a'), WireValue.string('b')]);
    const buf = wv.serialize();
    assert.strictEqual(buf[0], FieldKind.ARRAY);
    assert.strictEqual(buf.readUInt32BE(1), 2);
  });

  it('serializes object', () => {
    const wv = WireValue.object({ name: WireValue.string('Bara'), age: WireValue.int32(42) });
    const buf = wv.serialize();
    assert.strictEqual(buf[0], FieldKind.OBJECT);
    assert.strictEqual(buf.readUInt32BE(1), 2);
  });
});

describe('Protocol constants', () => {
  it('has correct client message kinds', () => {
    assert.strictEqual(MsgKind.CLIENT_HANDSHAKE, 0x01);
    assert.strictEqual(MsgKind.QUERY, 0x02);
    assert.strictEqual(MsgKind.QUERY_PARAMS, 0x03);
    assert.strictEqual(MsgKind.EXECUTE, 0x04);
    assert.strictEqual(MsgKind.BATCH, 0x05);
    assert.strictEqual(MsgKind.TRANSACTION, 0x06);
    assert.strictEqual(MsgKind.CLOSE, 0x07);
    assert.strictEqual(MsgKind.PING, 0x08);
    assert.strictEqual(MsgKind.AUTH, 0x09);
  });

  it('has correct server message kinds', () => {
    assert.strictEqual(MsgKind.SERVER_HANDSHAKE, 0x80);
    assert.strictEqual(MsgKind.READY, 0x81);
    assert.strictEqual(MsgKind.DATA, 0x82);
    assert.strictEqual(MsgKind.COMPLETE, 0x83);
    assert.strictEqual(MsgKind.ERROR, 0x84);
    assert.strictEqual(MsgKind.AUTH_CHALLENGE, 0x85);
    assert.strictEqual(MsgKind.AUTH_OK, 0x86);
    assert.strictEqual(MsgKind.SCHEMA_CHANGE, 0x87);
    assert.strictEqual(MsgKind.PONG, 0x88);
    assert.strictEqual(MsgKind.TRANSACTION_STATE, 0x89);
  });

  it('has correct result formats', () => {
    assert.strictEqual(ResultFormat.BINARY, 0x00);
    assert.strictEqual(ResultFormat.JSON, 0x01);
    assert.strictEqual(ResultFormat.TEXT, 0x02);
  });
});

describe('QueryBuilder', () => {
  it('builds simple SELECT', () => {
    const client = new Client();
    const qb = new QueryBuilder(client);
    const sql = qb.select('name', 'age').from('users').build();
    assert.strictEqual(sql, 'SELECT name, age FROM users');
  });

  it('builds SELECT * when empty', () => {
    const client = new Client();
    const qb = new QueryBuilder(client);
    const sql = qb.from('users').build();
    assert.strictEqual(sql, 'SELECT * FROM users');
  });

  it('builds WHERE with single clause', () => {
    const client = new Client();
    const qb = new QueryBuilder(client);
    const sql = qb.select('name').from('users').where('age > 18').build();
    assert.strictEqual(sql, 'SELECT name FROM users WHERE age > 18');
  });

  it('builds WHERE with multiple clauses', () => {
    const client = new Client();
    const qb = new QueryBuilder(client);
    const sql = qb.select('name').from('users').where('age > 18').where('active = true').build();
    assert.strictEqual(sql, 'SELECT name FROM users WHERE age > 18 AND active = true');
  });

  it('builds JOIN', () => {
    const client = new Client();
    const qb = new QueryBuilder(client);
    const sql = qb.select('u.name', 'o.total').from('users u').join('orders o', 'u.id = o.user_id').build();
    assert.ok(sql.includes('JOIN orders o ON u.id = o.user_id'));
  });

  it('builds LEFT JOIN', () => {
    const client = new Client();
    const qb = new QueryBuilder(client);
    const sql = qb.select('u.name', 'o.total').from('users u').leftJoin('orders o', 'u.id = o.user_id').build();
    assert.ok(sql.includes('LEFT JOIN orders o ON u.id = o.user_id'));
  });

  it('builds GROUP BY and HAVING', () => {
    const client = new Client();
    const qb = new QueryBuilder(client);
    const sql = qb.select('dept', 'count(*)').from('employees').groupBy('dept').having('count(*) > 5').build();
    assert.ok(sql.includes('GROUP BY dept'));
    assert.ok(sql.includes('HAVING count(*) > 5'));
  });

  it('builds ORDER BY', () => {
    const client = new Client();
    const qb = new QueryBuilder(client);
    const sql = qb.select('name').from('users').orderBy('name', 'DESC').build();
    assert.ok(sql.includes('ORDER BY name DESC'));
  });

  it('builds LIMIT and OFFSET', () => {
    const client = new Client();
    const qb = new QueryBuilder(client);
    const sql = qb.select('name').from('users').limit(10).offset(5).build();
    assert.ok(sql.includes('LIMIT 10'));
    assert.ok(sql.includes('OFFSET 5'));
  });

  it('builds full complex query', () => {
    const client = new Client();
    const qb = new QueryBuilder(client);
    const sql = qb.select('u.name', 'count(*) as cnt')
      .from('users u')
      .leftJoin('orders o', 'u.id = o.user_id')
      .where('u.age > 18')
      .groupBy('u.name')
      .having('cnt > 3')
      .orderBy('cnt', 'DESC')
      .limit(50)
      .build();
    assert.ok(sql.startsWith('SELECT'));
    assert.ok(sql.includes('LEFT JOIN'));
    assert.ok(sql.includes('WHERE'));
    assert.ok(sql.includes('GROUP BY'));
    assert.ok(sql.includes('HAVING'));
    assert.ok(sql.includes('ORDER BY'));
    assert.ok(sql.includes('LIMIT 50'));
  });
});
