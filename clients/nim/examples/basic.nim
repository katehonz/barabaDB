## BaraDB Nim Client — Basic Examples
## Make sure BaraDB is running on localhost:9472

import std/asyncdispatch
import std/strutils
import baradb/client

proc exampleConnection() {.async.} =
  echo "=== Connection ==="
  let client = newClient()
  await client.connect()
  echo "Connected: ", client.isConnected
  echo "Ping: ", await client.ping()
  client.close()
  echo "Connected after close: ", client.isConnected
  echo ""

proc exampleSimpleQuery() {.async.} =
  echo "=== Simple Query ==="
  let client = newClient()
  await client.connect()
  let result = await client.query("SELECT 42 as answer, 'BaraDB' as db")
  echo "Columns: ", result.columns
  echo "Row count: ", result.rowCount
  for row in result.rows:
    echo "  ", row.join(", ")
  client.close()
  echo ""

proc exampleParameterizedQuery() {.async.} =
  echo "=== Parameterized Query ==="
  let client = newClient()
  await client.connect()
  let result = await client.query(
    "SELECT $1 as num, $2 as txt",
    @[
      WireValue(kind: fkInt64, int64Val: 123),
      WireValue(kind: fkString, strVal: "hello world"),
    ]
  )
  for row in result.rows:
    echo "  ", row.join(", ")
  client.close()
  echo ""

proc exampleQueryBuilder() {.async.} =
  echo "=== Query Builder ==="
  let client = newClient()
  await client.connect()
  let sql = newQueryBuilder(client)
    .select("id", "name")
    .from("users")
    .where("active = true")
    .orderBy("name", "ASC")
    .limit(5)
    .build()
  echo "Generated SQL: ", sql
  client.close()
  echo ""

proc exampleDdlDml() {.async.} =
  echo "=== DDL & DML ==="
  let client = newClient()
  await client.connect()

  try:
    discard await client.exec("DROP TABLE IF EXISTS demo_products")
  except:
    discard

  discard await client.exec("CREATE TABLE demo_products (id INT PRIMARY KEY, name STRING, price FLOAT)")
  let affected = await client.exec("INSERT INTO demo_products (id, name, price) VALUES (1, 'Widget', 9.99)")
  echo "Insert affected rows: ", affected

  let result = await client.query("SELECT * FROM demo_products")
  echo "Select returned ", result.rowCount, " row(s)"
  for row in result.rows:
    echo "  ", row.join(", ")

  discard await client.exec("DROP TABLE demo_products")
  echo "Table dropped"
  client.close()
  echo ""

proc main() {.async.} =
  echo "BaraDB Nim Client Examples"
  echo "Make sure BaraDB is running on localhost:9472"
  echo ""

  await exampleConnection()
  await exampleSimpleQuery()
  await exampleParameterizedQuery()
  await exampleQueryBuilder()
  await exampleDdlDml()

waitFor main()
