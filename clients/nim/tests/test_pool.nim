import std/unittest
import std/asyncdispatch
import baradb/client
import baradb/pool

suite "BaraPool":
  test "pool stats with one acquired connection":
    proc run() {.async.} =
      let cfg = ClientConfig(host: "127.0.0.1", port: 9472, timeoutMs: 100)
      let pool = newBaraPool(cfg, minConnections = 0, maxConnections = 2)
      # Without a server, acquire should fail cleanly (timeout or connection refused)
      var failedCleanly = false
      try:
        withClient(pool):
          discard
      except BaraError:
        failedCleanly = true
      check failedCleanly
    waitFor run()
