/**
 * BaraDB JavaScript Client — Basic Examples
 *
 * Run: node examples/basic.js
 * Requires BaraDB server on localhost:9472.
 */

const { Client, WireValue, QueryBuilder } = require('../baradb');

const HOST = 'localhost';
const PORT = 9472;

async function exampleConnection() {
  console.log('=== Connection ===');
  const client = new Client(HOST, PORT);
  await client.connect();
  console.log(`Connected: ${client.isConnected()}`);
  console.log(`Ping: ${await client.ping()}`);
  await client.close();
  console.log(`Connected after close: ${client.isConnected()}`);
  console.log();
}

async function exampleSimpleQuery() {
  console.log('=== Simple Query ===');
  const client = new Client(HOST, PORT);
  await client.connect();
  const result = await client.query("SELECT 42 as answer, 'BaraDB' as db");
  console.log(`Columns: ${result.columns.join(', ')}`);
  console.log(`Row count: ${result.rowCount}`);
  for (const row of result) {
    console.log(`  answer=${row.answer}, db=${row.db}`);
  }
  await client.close();
  console.log();
}

async function exampleParameterizedQuery() {
  console.log('=== Parameterized Query ===');
  const client = new Client(HOST, PORT);
  await client.connect();
  const result = await client.queryParams(
    'SELECT $1 as num, $2 as txt, $3 as flag',
    [
      WireValue.int64(123),
      WireValue.string('hello world'),
      WireValue.bool(true),
    ]
  );
  for (const row of result) {
    console.log(`  num=${row.num}, txt=${row.txt}, flag=${row.flag}`);
  }
  await client.close();
  console.log();
}

async function exampleQueryBuilder() {
  console.log('=== Query Builder ===');
  const client = new Client(HOST, PORT);
  await client.connect();
  const sql = await new QueryBuilder(client)
    .select('id', 'name')
    .from('users')
    .where('active = true')
    .orderBy('name', 'ASC')
    .limit(5)
    .build();
  console.log(`Generated SQL: ${sql}`);
  await client.close();
  console.log();
}

async function exampleVector() {
  console.log('=== Vector Value ===');
  const client = new Client(HOST, PORT);
  await client.connect();
  const result = await client.queryParams(
    'SELECT $1 as embedding',
    [WireValue.vector([0.1, 0.2, 0.3, 0.4])]
  );
  for (const row of result) {
    console.log(`  embedding type: ${typeof row.embedding}`);
  }
  await client.close();
  console.log();
}

async function exampleDdlDml() {
  console.log('=== DDL & DML ===');
  const client = new Client(HOST, PORT);
  await client.connect();

  try {
    await client.execute('DROP TABLE IF EXISTS demo_products');
  } catch (err) {
    console.log(`Cleanup warning: ${err.message}`);
  }

  await client.execute('CREATE TABLE demo_products (id INT PRIMARY KEY, name STRING, price FLOAT)');
  const affected = await client.execute("INSERT INTO demo_products (id, name, price) VALUES (1, 'Widget', 9.99)");
  console.log(`Insert affected rows: ${affected}`);

  const result = await client.query('SELECT * FROM demo_products');
  console.log(`Select returned ${result.rowCount} row(s)`);
  for (const row of result) {
    console.log(`  ${JSON.stringify(row)}`);
  }

  await client.execute('DROP TABLE demo_products');
  console.log('Table dropped');
  await client.close();
  console.log();
}

async function main() {
  console.log('BaraDB JavaScript Client Examples');
  console.log('Make sure BaraDB is running on localhost:9472');
  console.log();

  const examples = [
    exampleConnection,
    exampleSimpleQuery,
    exampleParameterizedQuery,
    exampleQueryBuilder,
    exampleVector,
    exampleDdlDml,
  ];

  for (const fn of examples) {
    try {
      await fn();
    } catch (err) {
      console.error(`ERROR in ${fn.name}: ${err.message}`);
    }
  }
}

main().catch(console.error);
