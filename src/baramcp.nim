## BaraDB MCP Server — Standalone Entry Point
##
## Starts BaraDB in MCP (Model Context Protocol) server mode over STDIO.
## The server accepts JSON-RPC requests from AI agents and provides
## tools for SQL query execution, vector search, and schema inspection.
##
## Usage:
##   baramcp --data-dir ./data
##
## Environment variables:
##   BARADB_DATA_DIR — Path to the data directory (default: ./data)

import barabadb/mcp/server

when isMainModule:
  let dataDir = server.parseDataDir()
  server.logToStderr("Starting BaraDB MCP Server with data dir: " & dataDir)
  try:
    discard server.init(dataDir)
    server.run()
  except CatchableError:
    server.logToStderr("Fatal error: " & getCurrentExceptionMsg())
  finally:
    server.close()
