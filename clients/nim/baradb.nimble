# Package

version       = "0.1.0"
author        = "BaraDB Team"
description   = "BaraDB client library for Nim — async binary protocol client"
license       = "Apache-2.0"
srcDir        = "src"

# Dependencies — only Nim stdlib, no server code
requires "nim >= 2.2.0"

# Export the client module
bin           = @[]

task test, "Run client tests":
  exec "nim c -r tests/test_client.nim"
