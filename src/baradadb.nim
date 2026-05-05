## BaraDB — Multimodal Database Engine
## Main entry point
import std/asyncdispatch
import barabadb/core/server
import barabadb/core/config

proc main() =
  let config = loadConfig()
  echo "BaraDB v0.1.0 — Multimodal Database Engine"
  echo "Listening on ", config.address, ":", config.port
  var server = newServer(config)
  waitFor server.run()

when isMainModule:
  main()
