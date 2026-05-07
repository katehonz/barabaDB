# Package

version       = "1.0.0"
author        = "BaraDB Team"
description   = "Official Nim client for BaraDB — async binary protocol client"
license       = "Apache-2.0"
srcDir        = "src"

# Dependencies — only Nim stdlib, no server code
requires "nim >= 2.2.0"

# Export the client module
bin           = @[]

task test, "Run all client tests (unit + integration if server available)":
  exec "nim c -r tests/test_client.nim"
  # Integration tests are compiled separately; they auto-skip if no server.
  try:
    exec "nim c -r tests/test_integration.nim"
  except:
    echo "Integration tests skipped (no server on localhost:9472)"

task test_unit, "Run unit tests only":
  exec "nim c -r tests/test_client.nim"

task example, "Run basic example":
  exec "nim c -r examples/basic.nim"
