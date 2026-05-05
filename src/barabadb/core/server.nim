## BaraDB Server — async TCP server
import std/asyncdispatch
import std/asyncnet
import std/strutils
import config

type
  Server* = ref object
    config: BaraConfig
    running: bool

  ClientConnection = ref object
    socket: AsyncSocket
    id: int

proc newServer*(config: BaraConfig): Server =
  Server(config: config, running: false)

proc handleClient(server: Server, client: AsyncSocket, clientId: int) {.async.} =
  echo "Client ", clientId, " connected"
  try:
    while true:
      let line = await client.recvLine()
      if line.len == 0:
        break
      echo "[", clientId, "] ", line
      await client.send("OK\n")
  except:
    discard
  finally:
    echo "Client ", clientId, " disconnected"
    client.close()

proc run*(server: Server) {.async.} =
  server.running = true
  var clientId = 0
  let sock = newAsyncSocket()
  sock.setSockOpt(OptReuseAddr, true)
  sock.bindAddr(Port(server.config.port), server.config.address)
  sock.listen()
  echo "BaraDB listening on ", server.config.address, ":", server.config.port
  while server.running:
    let client = await sock.accept()
    inc clientId
    asyncCheck server.handleClient(client, clientId)

proc stop*(server: Server) =
  server.running = false
