discard """
  cmd: "nim c -r $file"
"""

import std/unittest
import std/asyncdispatch
import std/json
import std/options
import std/strformat
import ../../src/allographer/query_builder
import ./connections


let rdb = baradb

suite("Baradb query"):
  test("create table raw"):
    let sql = """
      CREATE TABLE IF NOT EXISTS "users" (
        "id" SERIAL PRIMARY KEY,
        "name" VARCHAR(255),
        "email" VARCHAR(255),
        "age" INTEGER
      )
    """
    waitFor rdb.raw(sql).exec()
    check true

  test("insert"):
    waitFor rdb.table("users").insert(%*{ "name": "Alice", "email": "alice@example.com", "age": 30 })
    waitFor rdb.table("users").insert(%*{ "name": "Bob", "email": "bob@example.com", "age": 25 })
    check true

  test("get"):
    let users = waitFor rdb.select("id", "name", "email", "age").table("users").orderBy("id", Asc).get()
    check users.len >= 2
    check users[0]["name"].getStr == "Alice"
    check users[0]["email"].getStr == "alice@example.com"
    check users[0]["age"].getInt == 30

  test("first"):
    let user = waitFor rdb.table("users").where("name", "=", "Alice").first()
    check user.isSome
    check user.get["name"].getStr == "Alice"

  test("find"):
    let user = waitFor rdb.table("users").find(1)
    check user.isSome
    check user.get["id"].getInt == 1

  test("update"):
    waitFor rdb.table("users").where("name", "=", "Alice").update(%*{ "age": 31 })
    let user = waitFor rdb.table("users").where("name", "=", "Alice").first()
    check user.isSome
    check user.get["age"].getInt == 31

  test("delete"):
    waitFor rdb.table("users").where("name", "=", "Bob").delete()
    let user = waitFor rdb.table("users").where("name", "=", "Bob").first()
    check user.isNone

  test("count"):
    let cnt = waitFor rdb.table("users").count()
    check cnt >= 1

  test("transaction rollback"):
    waitFor rdb.begin()
    waitFor rdb.table("users").insert(%*{ "name": "Charlie", "email": "charlie@example.com", "age": 40 })
    waitFor rdb.rollback()
    let user = waitFor rdb.table("users").where("name", "=", "Charlie").first()
    check user.isNone

  test("transaction commit"):
    waitFor rdb.begin()
    waitFor rdb.table("users").insert(%*{ "name": "Dave", "email": "dave@example.com", "age": 50 })
    waitFor rdb.commit()
    let user = waitFor rdb.table("users").where("name", "=", "Dave").first()
    check user.isSome

  test("raw select"):
    let users = waitFor rdb.raw("SELECT * FROM \"users\" WHERE \"age\" > 20").get()
    check users.len >= 1
