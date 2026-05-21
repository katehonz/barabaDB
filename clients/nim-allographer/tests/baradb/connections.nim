import std/asyncdispatch
import std/json
import ../../src/allographer/connection
import ../../src/allographer/query_builder

let baradb* = dbOpen(Baradb, "default", "admin", "", "127.0.0.1", 9472, maxConnections = 2, timeout = 30)
