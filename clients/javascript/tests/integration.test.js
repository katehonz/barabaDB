/**
 * BaraDB JavaScript Client — Integration Tests
 * Requires a running BaraDB server on localhost:9472.
 */

const { describe, it } = require('node:test');
const assert = require('node:assert');
const net = require('net');
const { Client, WireValue, QueryBuilder } = require('../baradb');

const HOST = 'localhost';
const PORT = 9472;

function serverAvailable() {
  return new Promise((resolve) => {
    const socket = new net.Socket();
    socket.setTimeout(2000);
    socket.once('connect', () => {
      socket.destroy();
      resolve(true);
    });
    socket.once('error', () => resolve(false));
    socket.once('timeout', () => resolve(false));
    socket.connect(PORT, HOST);
  });
}

let available = false;

(async () => {
  available = await serverAvailable();
})();

// Use conditional describe via top-level if to avoid describe skip issues
if (true) {
  describe('Integration', () => {
    it('connects and closes', async () => {
      if (!available) return; // skip inline
      const client = new Client(HOST, PORT);
      assert.strictEqual(client.isConnected(), false);
      await client.connect();
      assert.strictEqual(client.isConnected(), true);
      await client.close();
      assert.strictEqual(client.isConnected(), false);
    });

    it('pongs', async () => {
      if (!available) return;
      const client = new Client(HOST, PORT);
      await client.connect();
      const ok = await client.ping();
      assert.strictEqual(ok, true);
      await client.close();
    });

    it('executes simple SELECT', async () => {
      if (!available) return;
      const client = new Client(HOST, PORT);
      await client.connect();
      const result = await client.query('SELECT 1 as one');
      assert.ok(result instanceof Object);
      assert.ok(typeof result.rowCount === 'number');
      await client.close();
    });

    it('executes parameterized query', async () => {
      if (!available) return;
      const client = new Client(HOST, PORT);
      await client.connect();
      const result = await client.queryParams(
        'SELECT $1 as num, $2 as txt',
        [WireValue.int64(42), WireValue.string('hello')]
      );
      assert.ok(result instanceof Object);
      await client.close();
    });

    it('creates table, inserts, selects, drops', async () => {
      if (!available) return;
      const client = new Client(HOST, PORT);
      await client.connect();

      try {
        await client.execute('DROP TABLE IF EXISTS js_test_users');
      } catch (_) { /* ignore */ }

      await client.execute('CREATE TABLE js_test_users (id INT PRIMARY KEY, name STRING, age INT)');
      const affected = await client.execute("INSERT INTO js_test_users (id, name, age) VALUES (1, 'Alice', 30)");
      assert.ok(affected >= 0);

      const result = await client.query('SELECT name, age FROM js_test_users WHERE id = 1');
      assert.strictEqual(result.rowCount, 1);
      const row = {};
      for (let i = 0; i < result.columns.length; i++) {
        row[result.columns[i]] = result.rows[0][i];
      }
      assert.strictEqual(row.name, 'Alice');
      assert.strictEqual(row.age, 30);

      await client.execute('DROP TABLE js_test_users');
      await client.close();
    });

    it('executes built query', async () => {
      if (!available) return;
      const client = new Client(HOST, PORT);
      await client.connect();

      try {
        await client.execute('DROP TABLE IF EXISTS js_test_products');
      } catch (_) { /* ignore */ }

      await client.execute('CREATE TABLE js_test_products (id INT PRIMARY KEY, name STRING, price FLOAT)');
      await client.execute("INSERT INTO js_test_products (id, name, price) VALUES (1, 'Widget', 9.99)");

      const result = await new QueryBuilder(client)
        .select('name', 'price')
        .from('js_test_products')
        .where('id = 1')
        .exec();

      assert.strictEqual(result.rowCount, 1);
      await client.execute('DROP TABLE js_test_products');
      await client.close();
    });

    it('accepts or rejects dummy token', async () => {
      if (!available) return;
      const client = new Client(HOST, PORT);
      await client.connect();
      try {
        await client.auth('dummy-token-for-testing');
      } catch (err) {
        assert.ok(err.message.includes('Auth') || err.message.toLowerCase().includes('error'));
      }
      await client.close();
    });
  });
}
