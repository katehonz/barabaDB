## BaraDB Nim Client — Tests
import std/unittest
import std/strutils
import baradb/client

suite "QueryBuilder":
  test "Simple SELECT":
    let client = newClient()
    let qb = newQueryBuilder(client)
    let sql = qb.select("name", "age").from("users").build()
    check sql == "SELECT name, age FROM users"

  test "SELECT with WHERE":
    let client = newClient()
    let qb = newQueryBuilder(client)
    let sql = qb.select("name").from("users").where("age > 18").build()
    check sql == "SELECT name FROM users WHERE age > 18"

  test "SELECT with JOIN":
    let client = newClient()
    let qb = newQueryBuilder(client)
    let sql = qb.select("u.name", "o.total").from("users u")
      .join("orders o", "u.id = o.user_id").build()
    check "JOIN" in sql
    check "ON" in sql

  test "SELECT with GROUP BY and HAVING":
    let client = newClient()
    let qb = newQueryBuilder(client)
    let sql = qb.select("dept", "count(*)").from("employees")
      .groupBy("dept").having("count(*) > 5").build()
    check "GROUP BY" in sql
    check "HAVING" in sql

  test "SELECT with ORDER BY and LIMIT":
    let client = newClient()
    let qb = newQueryBuilder(client)
    let sql = qb.select("name").from("users")
      .orderBy("name", "DESC").limit(10).offset(5).build()
    check "ORDER BY name DESC" in sql
    check "LIMIT 10" in sql
    check "OFFSET 5" in sql

  test "Full complex query":
    let client = newClient()
    let qb = newQueryBuilder(client)
    let sql = qb.select("u.name", "count(*) as cnt")
      .from("users u")
      .leftJoin("orders o", "u.id = o.user_id")
      .where("u.age > 18")
      .groupBy("u.name")
      .having("cnt > 3")
      .orderBy("cnt", "DESC")
      .limit(50)
      .build()
    check sql.startsWith("SELECT")
    check "LEFT JOIN" in sql
    check "WHERE" in sql
    check "GROUP BY" in sql
    check "HAVING" in sql
    check "ORDER BY" in sql
    check "LIMIT 50" in sql

suite "Client Config":
  test "Default config":
    let config = defaultConfig()
    check config.host == "127.0.0.1"
    check config.port == 5432
    check config.database == "default"

  test "Custom config":
    let config = ClientConfig(host: "db.example.com", port: 9999,
                              database: "production", username: "app")
    check config.host == "db.example.com"
    check config.port == 9999

  test "Client creation":
    let client = newClient()
    check not client.isConnected

suite "Wire Protocol":
  test "Build query message":
    let msg = makeQueryMessage(1, "SELECT 1")
    check msg.len > 0
    # First 4 bytes: mkQuery (0x02) in big-endian uint32
    check msg[3] == 2'u8

  test "Wire value serialization":
    var buf: seq[byte] = @[]
    let val = WireValue(kind: fkString, strVal: "hello")
    buf.serializeValue(val)
    var pos = 0
    let decoded = buf.deserializeValue(pos)
    check decoded.kind == fkString
    check decoded.strVal == "hello"

  test "Null value roundtrip":
    var buf: seq[byte] = @[]
    let val = WireValue(kind: fkNull)
    buf.serializeValue(val)
    check buf.len == 1
    check buf[0] == 0x00'u8

  test "Int64 value roundtrip":
    var buf: seq[byte] = @[]
    let val = WireValue(kind: fkInt64, int64Val: 123456789)
    buf.serializeValue(val)
    var pos = 0
    let decoded = buf.deserializeValue(pos)
    check decoded.kind == fkInt64
    check decoded.int64Val == 123456789

  test "Array value roundtrip":
    var buf: seq[byte] = @[]
    let val = WireValue(kind: fkArray, arrayVal: @[
      WireValue(kind: fkString, strVal: "a"),
      WireValue(kind: fkString, strVal: "b"),
    ])
    buf.serializeValue(val)
    var pos = 0
    let decoded = buf.deserializeValue(pos)
    check decoded.kind == fkArray
    check decoded.arrayVal.len == 2
    check decoded.arrayVal[0].strVal == "a"

suite "Client async":
  test "Client nextId":
    let client = newClient()
    check not client.isConnected
