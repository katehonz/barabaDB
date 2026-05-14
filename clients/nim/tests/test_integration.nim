## BaraDB Nim Client — Integration Tests
## Requires a running BaraDB server.
## Set BARADB_HOST / BARADB_PORT env vars to override defaults.

import std/unittest
import std/asyncdispatch
import std/asyncnet
import std/strutils
import std/os
import baradb/client

const
  TestHost = getEnv("BARADB_HOST", "127.0.0.1")
  TestPort = parseInt(getEnv("BARADB_PORT", "9472"))

proc serverAvailable(): bool =
  try:
    var socket = newAsyncSocket()
    waitFor socket.connect(TestHost, Port(TestPort))
    socket.close()
    return true
  except:
    return false

let hasServer = serverAvailable()

suite "Integration: Connection":
  test "Connect and close":
    if not hasServer:
      skip()
    var client = newClient(ClientConfig(host: TestHost, port: TestPort))
    check not client.isConnected
    waitFor client.connect()
    check client.isConnected
    client.close()
    check not client.isConnected

  test "Ping":
    if not hasServer:
      skip()
    var client = newClient(ClientConfig(host: TestHost, port: TestPort))
    waitFor client.connect()
    check (waitFor client.ping()) == true
    client.close()

suite "Integration: Query":
  test "Simple SELECT":
    if not hasServer:
      skip()
    var client = newClient(ClientConfig(host: TestHost, port: TestPort))
    waitFor client.connect()
    let result = waitFor client.query("SELECT 1 as one")
    check result.rowCount >= 0
    client.close()

  test "Parameterized query":
    if not hasServer:
      skip()
    var client = newClient(ClientConfig(host: TestHost, port: TestPort))
    waitFor client.connect()
    let result = waitFor client.query(
      "SELECT $1 as num, $2 as txt",
      @[WireValue(kind: fkInt64, int64Val: 42), WireValue(kind: fkString, strVal: "hello")]
    )
    check result.rowCount >= 0
    client.close()

suite "Integration: DDL & DML":
  test "Create table, insert, select, drop":
    if not hasServer:
      skip()
    var client = newClient(ClientConfig(host: TestHost, port: TestPort))
    waitFor client.connect()

    try:
      discard waitFor client.exec("DROP TABLE IF EXISTS nim_test_users")
    except:
      discard

    discard waitFor client.exec("CREATE TABLE nim_test_users (id INT PRIMARY KEY, name STRING, age INT)")
    let affected = waitFor client.exec("INSERT INTO nim_test_users (id, name, age) VALUES (1, 'Alice', 30)")
    check affected >= 0

    let result = waitFor client.query("SELECT name, age FROM nim_test_users WHERE id = 1")
    check result.rowCount == 1
    client.close()

suite "Integration: QueryBuilder":
  test "Builder exec":
    if not hasServer:
      skip()
    var client = newClient(ClientConfig(host: TestHost, port: TestPort))
    waitFor client.connect()

    try:
      discard waitFor client.exec("DROP TABLE IF EXISTS nim_test_products")
    except:
      discard

    discard waitFor client.exec("CREATE TABLE nim_test_products (id INT PRIMARY KEY, name STRING, price FLOAT)")
    discard waitFor client.exec("INSERT INTO nim_test_products (id, name, price) VALUES (1, 'Widget', 9.99)")

    let result = waitFor newQueryBuilder(client)
      .select("name", "price")
      .from("nim_test_products")
      .where("id = 1")
      .exec()
    check result.rowCount == 1

    discard waitFor client.exec("DROP TABLE nim_test_products")
    client.close()

suite "Integration: SyncClient":
  test "Sync query":
    if not hasServer:
      skip()
    var client = newSyncClient(ClientConfig(host: TestHost, port: TestPort))
    client.connect()
    let result = client.query("SELECT 1 as one")
    check result.rowCount >= 0
    client.close()
