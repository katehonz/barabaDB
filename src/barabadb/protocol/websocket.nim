## WebSocket — streaming protocol support
import std/asyncdispatch
import std/asyncnet
import std/strutils
import std/base64
import std/sha1
import std/hashes

const
  WS_FIN* = 0x80'u8
  WS_TEXT* = 0x01'u8
  WS_BINARY* = 0x02'u8
  WS_CLOSE* = 0x08'u8
  WS_PING* = 0x09'u8
  WS_PONG* = 0x0A'u8
  WS_MAX_FRAME* = 65536

type
  WsFrame* = object
    fin*: bool
    opcode*: uint8
    payload*: seq[byte]
    masked*: bool

  WebSocket* = ref object
    socket: AsyncSocket
    connected*: bool
    onMessage*: proc(data: seq[byte]) {.gcsafe.}
    onClose*: proc() {.gcsafe.}
    onPing*: proc(data: seq[byte]) {.gcsafe.}
    onPong*: proc(data: seq[byte]) {.gcsafe.}

  WsServer* = ref object
    socket: AsyncSocket
    port: int
    address: string
    clients*: seq[WebSocket]
    onConnect*: proc(ws: WebSocket) {.gcsafe.}
    onDisconnect*: proc(ws: WebSocket) {.gcsafe.}
    onMessage*: proc(ws: WebSocket, data: seq[byte]) {.gcsafe.}

proc newWebSocket*(socket: AsyncSocket): WebSocket =
  WebSocket(
    socket: socket,
    connected: true,
    onMessage: nil,
    onClose: nil,
    onPing: nil,
    onPong: nil,
  )

proc newWsServer*(port: int = 8081, address: string = "0.0.0.0"): WsServer =
  WsServer(
    socket: newAsyncSocket(),
    port: port,
    address: address,
    clients: @[],
    onConnect: nil,
    onDisconnect: nil,
    onMessage: nil,
  )

proc wsHandshakeKey(clientKey: string): string =
  let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  let combined = clientKey & magic
  let hash = computeSHA1(combined)
  return encode(hash)

proc sendFrame*(ws: WebSocket, opcode: uint8, data: openArray[byte]) {.async.} =
  var frame: seq[byte] = @[]
  frame.add(opcode or WS_FIN)

  if data.len < 126:
    frame.add(byte(data.len))
  elif data.len < 65536:
    frame.add(126'u8)
    frame.add(byte((data.len shr 8) and 0xFF))
    frame.add(byte(data.len and 0xFF))
  else:
    frame.add(127'u8)
    for i in 0..7:
      frame.add(byte((data.len shr (56 - i * 8)) and 0xFF))

  for b in data:
    frame.add(b)

  await ws.socket.send(cast[string](frame))

proc sendText*(ws: WebSocket, text: string) {.async.} =
  await ws.sendFrame(WS_TEXT, cast[seq[byte]](text))

proc sendBinary*(ws: WebSocket, data: seq[byte]) {.async.} =
  await ws.sendFrame(WS_BINARY, data)

proc sendPing*(ws: WebSocket, data: seq[byte] = @[]) {.async.} =
  await ws.sendFrame(WS_PING, data)

proc sendPong*(ws: WebSocket, data: seq[byte] = @[]) {.async.} =
  await ws.sendFrame(WS_PONG, data)

proc close*(ws: WebSocket) {.async.} =
  if ws.connected:
    ws.connected = false
    await ws.sendFrame(WS_CLOSE, @[])
    ws.socket.close()
    if ws.onClose != nil:
      ws.onClose()

proc readFrame*(ws: WebSocket): Future[WsFrame] {.async.} =
  var header: array[2, byte]
  let read1 = await ws.socket.recv(2)
  if read1.len < 2:
    return WsFrame(fin: false, opcode: WS_CLOSE)

  header[0] = byte(read1[0])
  header[1] = byte(read1[1])

  result.fin = (header[0] and WS_FIN) != 0
  result.opcode = header[0] and 0x0F
  result.masked = (header[1] and 0x80) != 0
  var payloadLen = int(header[1] and 0x7F)

  if payloadLen == 126:
    let ext = await ws.socket.recv(2)
    if ext.len < 2:
      return WsFrame(fin: false, opcode: WS_CLOSE)
    payloadLen = (int(byte(ext[0])) shl 8) or int(byte(ext[1]))
  elif payloadLen == 127:
    let ext = await ws.socket.recv(8)
    if ext.len < 8:
      return WsFrame(fin: false, opcode: WS_CLOSE)
    payloadLen = 0
    for i in 0..7:
      payloadLen = (payloadLen shl 8) or int(byte(ext[i]))

  var maskKey: array[4, byte] = [0'u8, 0, 0, 0]
  if result.masked:
    let mk = await ws.socket.recv(4)
    if mk.len < 4:
      return WsFrame(fin: false, opcode: WS_CLOSE)
    for i in 0..3:
      maskKey[i] = byte(mk[i])

  let payloadData = await ws.socket.recv(payloadLen)
  if payloadData.len < payloadLen:
    return WsFrame(fin: false, opcode: WS_CLOSE)

  result.payload = newSeq[byte](payloadLen)
  for i in 0..<payloadLen:
    if result.masked:
      result.payload[i] = byte(payloadData[i]) xor maskKey[i mod 4]
    else:
      result.payload[i] = byte(payloadData[i])

proc handleUpgrade*(client: AsyncSocket, requestHeaders: Table[string, string]): Future[WebSocket] {.async.} =
  let wsKey = requestHeaders.getOrDefault("Sec-WebSocket-Key", "")
  if wsKey.len == 0:
    return nil

  let acceptKey = wsHandshakeKey(wsKey)
  let response = "HTTP/1.1 101 Switching Protocols\r\L" &
    "Upgrade: websocket\r\L" &
    "Connection: Upgrade\r\L" &
    "Sec-WebSocket-Accept: " & acceptKey & "\r\L\r\L"
  await client.send(response)
  return newWebSocket(client)

proc run*(server: WsServer) {.async.} =
  server.socket.setSockOpt(OptReuseAddr, true)
  server.socket.bindAddr(Port(server.port), server.address)
  server.socket.listen()

  while true:
    let client = await server.socket.accept()
    let ws = newWebSocket(client)
    server.clients.add(ws)

    if server.onConnect != nil:
      server.onConnect(ws)

    # Read loop
    try:
      while ws.connected:
        let frame = await ws.readFrame()
        case frame.opcode
        of WS_TEXT, WS_BINARY:
          if server.onMessage != nil:
            server.onMessage(ws, frame.payload)
        of WS_PING:
          await ws.sendPong(frame.payload)
        of WS_CLOSE:
          ws.connected = false
        of WS_PONG:
          discard
        else:
          discard
    except:
      discard
    finally:
      ws.connected = false
      server.clients = server.clients.filterIt(it != ws)
      if server.onDisconnect != nil:
        server.onDisconnect(ws)

proc broadcast*(server: WsServer, data: seq[byte]) {.async.} =
  for client in server.clients:
    if client.connected:
      await client.sendBinary(data)

proc broadcastText*(server: WsServer, text: string) {.async.} =
  for client in server.clients:
    if client.connected:
      await client.sendText(text)

proc clientCount*(server: WsServer): int = server.clients.len
