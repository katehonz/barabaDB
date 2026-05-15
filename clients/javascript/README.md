# BaraDB JavaScript / Node.js Client

Official JavaScript client for **BaraDB** — a multimodal database engine written in Nim.

## Features

- **Binary wire protocol** — fast TCP communication
- **Promise-based API** — modern async/await
- **Query builder** — fluent SQL construction
- **Parameterized queries** — safe from SQL injection
- **Vector & JSON support** — first-class multimodal types
- **TypeScript definitions** — included out of the box

## Installation

```bash
npm install baradb
```

Or from source:

```bash
git clone https://codeberg.org/baraba/baradb
cd clients/javascript
npm link
```

## Quick Start

```javascript
const { Client } = require('baradb');

async function main() {
  const client = new Client('localhost', 9472);
  await client.connect();

  const result = await client.query("SELECT name, age FROM users WHERE age > 18");
  for (const row of result) {
    console.log(row.name, row.age);
  }

  await client.close();
}

main().catch(console.error);
```

### Parameterized Queries

```javascript
const { Client, WireValue } = require('baradb');

async function main() {
  const client = new Client('localhost', 9472);
  await client.connect();

  const result = await client.queryParams(
    'SELECT * FROM users WHERE age > $1 AND country = $2',
    [WireValue.int64(18), WireValue.string('BG')]
  );

  for (const row of result) {
    console.log(row);
  }

  await client.close();
}
```

### Query Builder

```javascript
const { Client, QueryBuilder } = require('baradb');

async function main() {
  const client = new Client('localhost', 9472);
  await client.connect();

  const result = await new QueryBuilder(client)
    .select('name', 'email')
    .from('users')
    .where('active = true')
    .orderBy('name')
    .limit(10)
    .exec();

  for (const row of result) {
    console.log(row);
  }

  await client.close();
}
```

### Vector Search

```javascript
const { Client, WireValue } = require('baradb');

async function main() {
  const client = new Client('localhost', 9472);
  await client.connect();

  const result = await client.queryParams(
    'SELECT id, name FROM products ORDER BY embedding <-> $1 LIMIT 5',
    [WireValue.vector([0.1, 0.2, 0.3])]
  );

  await client.close();
}
```

## Running Tests

Unit tests (no server):

```bash
npm run test:unit
```

Integration tests (requires server on `localhost:9472`):

```bash
# Start server
docker run -d -p 9472:9472 baradb:latest

# Run integration tests
npm run test:integration

# Run all tests
npm test
```

## API Reference

### `new Client(host, port, options)`

| Option       | Default     | Description                |
|--------------|-------------|----------------------------|
| `host`       | `localhost` | Server hostname            |
| `port`       | `9472`      | TCP wire protocol port     |
| `database`   | `default`   | Default database           |
| `username`   | `admin`     | Username                   |
| `password`   | `""`        | Password                   |
| `timeout`    | `30000`     | Socket timeout in ms       |

### Methods

- `connect()` — open TCP connection
- `close()` — close connection
- `query(sql)` — execute SELECT-like query
- `queryParams(sql, params)` — parameterized query
- `execute(sql)` — execute DDL/DML, returns affected rows
- `auth(token)` — JWT authentication
- `ping()` — health check

## License

Apache-2.0
