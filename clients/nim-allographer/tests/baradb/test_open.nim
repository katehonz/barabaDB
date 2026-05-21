discard """
  cmd: "nim c $file"
"""

import std/unittest
import ../../src/allographer/connection
import ../../src/allographer/query_builder


suite("Baradb connection"):
  test("connection"):
    let rdb = dbOpen(Baradb, "default", "admin", "", "127.0.0.1", 9472)
    check(rdb.isConnected())
