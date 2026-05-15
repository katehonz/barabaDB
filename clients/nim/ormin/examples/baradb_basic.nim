## Basic Ormin + BaraDB example
##
## Run with:
##   nim c -r examples/baradb_basic.nim
##
## Requires a BaraDB server on localhost:9472.

import ormin

importModel(DbBackend.baradb, "baradb_model")

let db {.global.} = open("127.0.0.1:9472", "admin", "", "default")

proc listUsers() =
  let rows = query:
    select users(id, name, email)
    orderby id
  for r in rows:
    echo "User #", r.id, ": ", r.name, " <", r.email, ">"

proc findUserByName(name: string) =
  let row = query:
    select users(id, name, email)
    where name == ?name
    limit 1
  echo "Found: ", row

proc insertUser(name, email: string; age: int) =
  query:
    insert users(name = ?name, email = ?email, age = ?age)

when isMainModule:
  listUsers()
  findUserByName("alice")
  insertUser("bob", "bob@example.com", 30)
