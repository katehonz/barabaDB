## BaraDB WebSocket Server — real-time subscriptions
import std/asyncdispatch
import std/asyncnet
import std/strutils
import std/tables
import std/base64
import std/sets
import config
import jwt as jwtlib

type
  WsFrame = object
    fin: bool
    opcode: uint8
    masked: bool
    payloadLen: uint64
    maskKey: array[4, byte]
    payload: string

  WsClient* = ref object
    socket: AsyncSocket
    id: int
    subscriptions: HashSet[string]

  WsServer* = ref object
    clients*: Table[int, WsClient]
    nextId: int
    running: bool
    config*: BaraConfig
    secretKey*: string
    onInsert*: proc (table, key, value: string) {.closure.}
    onDelete*: proc (table, key: string) {.closure.}

proc newWsServer*(cfg: BaraConfig = defaultConfig(), secret: string = ""): WsServer =
  WsServer(clients: initTable[int, WsClient](), nextId: 1, running: false,
           config: cfg, secretKey: secret)

# ----------------------------------------------------------------------
# WebSocket frame encoding/decoding (RFC 6455)
# ----------------------------------------------------------------------

proc encodeFrame(opcode: uint8, payload: string): string =
  result = ""
  let isMasked = false
  var b0 = 0x80'u8 or opcode
  result.add(char(b0))

  var b1 = 0'u8
  if not isMasked:
    if payload.len < 126:
      b1 = uint8(payload.len)
    elif payload.len <= 65535:
      b1 = 126
    else:
      b1 = 127
  result.add(char(b1))

  if payload.len >= 126 and payload.len <= 65535:
    var len16 = uint16(payload.len)
    result.add(char((len16 shr 8) and 0xFF))
    result.add(char(len16 and 0xFF))
  elif payload.len > 65535:
    var len64 = uint64(payload.len)
    for i in countdown(7, 0):
      result.add(char((len64 shr (i * 8)) and 0xFF))

  result.add(payload)

proc decodeFrame(data: string): (WsFrame, int) =
  if data.len < 2:
    return (WsFrame(), 0)

  var frame = WsFrame()
  let b0 = uint8(data[0])
  let b1 = uint8(data[1])
  frame.fin = (b0 and 0x80) != 0
  frame.opcode = b0 and 0x0F
  frame.masked = (b1 and 0x80) != 0

  var len = uint64(b1 and 0x7F)
  var offset = 2

  if len == 126:
    if data.len < 4: return (WsFrame(), 0)
    len = (uint64(uint8(data[2])) shl 8) or uint64(uint8(data[3]))
    offset = 4
  elif len == 127:
    if data.len < 10: return (WsFrame(), 0)
    len = 0
    for i in 0..7:
      len = (len shl 8) or uint64(uint8(data[2 + i]))
    offset = 10

  if frame.masked:
    if data.len < offset + 4: return (WsFrame(), 0)
    for i in 0..3:
      frame.maskKey[i] = byte(data[offset + i])
    offset += 4

  if uint64(data.len) < uint64(offset) + len:
    return (Wsframe(), 0)

  let plen = int(len)
  if frame.masked:
    for i in 0..<plen:
      frame.payload.add(char(byte(data[offset + i]) xor frame.maskKey[i mod 4]))
  else:
    frame.payload = data[offset..offset + plen - 1]

  return (frame, offset + plen)

# ----------------------------------------------------------------------
# HTTP upgrade handshake
# ----------------------------------------------------------------------

proc computeAcceptKey(key: string): string =
  let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  # Minimal SHA1 implementation for WebSocket handshake
  proc rotateLeft(x: uint32, n: int): uint32 {.inline.} =
    (x shl uint32(n)) or (x shr uint32(32 - n))

  var h: array[5, uint32] = [0x67452301'u32, 0xEFCDAB89'u32, 0x98BADCFE'u32, 0x10325476'u32, 0xC3D2E1F0'u32]
  let input = key & magic
  var msg = newSeq[byte](input.len)
  for i, c in input:
    msg[i] = byte(c)

  let origLen = msg.len
  msg.add(0x80'u8)
  while (msg.len + 8) mod 64 != 0:
    msg.add(0'u8)
  let bitLen = uint64(origLen) * 8
  for i in countdown(7, 0):
    msg.add(byte((bitLen shr (i * 8)) and 0xFF))

  var w: array[80, uint32]
  for chunkStart in countup(0, msg.len - 64, 64):
    for i in 0..15:
      w[i] = (uint32(msg[chunkStart + i*4]) shl 24) or
             (uint32(msg[chunkStart + i*4 + 1]) shl 16) or
             (uint32(msg[chunkStart + i*4 + 2]) shl 8) or
             uint32(msg[chunkStart + i*4 + 3])
    for i in 16..79:
      w[i] = rotateLeft(w[i-3] xor w[i-8] xor w[i-14] xor w[i-16], 1)

    var a = h[0]; var b = h[1]; var c = h[2]; var d = h[3]; var e = h[4]
    for i in 0..79:
      var f, k: uint32
      if i < 20:
        f = (b and c) or ((not b) and d); k = 0x5A827999'u32
      elif i < 40:
        f = b xor c xor d; k = 0x6ED9EBA1'u32
      elif i < 60:
        f = (b and c) or (b and d) or (c and d); k = 0x8F1BBCDC'u32
      else:
        f = b xor c xor d; k = 0xCA62C1D6'u32
      let temp = rotateLeft(a, 5) + f + e + k + w[i]
      e = d; d = c; c = rotateLeft(b, 30); b = a; a = temp
    h[0] = h[0] + a; h[1] = h[1] + b; h[2] = h[2] + c; h[3] = h[3] + d; h[4] = h[4] + e

  var digest = newString(20)
  for i in 0..4:
    digest[i*4] = char((h[i] shr 24) and 0xFF)
    digest[i*4 + 1] = char((h[i] shr 16) and 0xFF)
    digest[i*4 + 2] = char((h[i] shr 8) and 0xFF)
    digest[i*4 + 3] = char(h[i] and 0xFF)
  return encode(digest)

# ----------------------------------------------------------------------
# Subscription management
# ----------------------------------------------------------------------

proc subscribe*(client: WsClient, table: string) =
  client.subscriptions.incl(table)

proc unsubscribe*(client: WsClient, table: string) =
  client.subscriptions.excl(table)

proc notifyClient(client: WsClient, msg: string) {.async.} =
  try:
    let frame = encodeFrame(0x1, msg)
    await client.socket.send(frame)
  except:
    discard

proc broadcastToTable*(server: WsServer, table: string, msg: string) {.async.} =
  for id, client in server.clients:
    if table in client.subscriptions:
      asyncCheck client.notifyClient(msg)

# ----------------------------------------------------------------------
# WebSocket client handler
# ----------------------------------------------------------------------

proc handleWsClient(server: WsServer, client: AsyncSocket, id: int) {.async.} =
  echo "WebSocket client ", id, " connected"
  var wsClient = WsClient(socket: client, id: id, subscriptions: initHashSet[string]())
  server.clients[id] = wsClient

  var buf = ""
  try:
    while true:
      let chunk = await client.recv(4096)
      if chunk.len == 0:
        break
      buf.add(chunk)

      while buf.len >= 2:
        let (frame, consumed) = decodeFrame(buf)
        if consumed == 0:
          break

        case frame.opcode
        of 0x8:  # close
          client.close()
          server.clients.del(id)
          return
        of 0x9:  # ping
          let pong = encodeFrame(0xA, frame.payload)
          await client.send(pong)
        of 0x1:  # text
          let msg = frame.payload
          if msg.startsWith("SUBSCRIBE "):
            let table = msg[10..^1].strip()
            wsClient.subscribe(table)
            let ack = encodeFrame(0x1, "OK subscribed to " & table)
            await client.send(ack)
          elif msg.startsWith("UNSUBSCRIBE "):
            let table = msg[12..^1].strip()
            wsClient.unsubscribe(table)
            let ack = encodeFrame(0x1, "OK unsubscribed from " & table)
            await client.send(ack)
          else:
            let echo = encodeFrame(0x1, "ECHO: " & msg)
            await client.send(echo)
        else:
          discard

        buf = buf[consumed..^1]

  except:
    discard
  finally:
    echo "WebSocket client ", id, " disconnected"
    server.clients.del(id)
    client.close()

# ----------------------------------------------------------------------
# HTTP upgrade + WebSocket handoff
# ----------------------------------------------------------------------

proc handleConnection(server: WsServer, client: AsyncSocket) {.async.} =
  let firstLine = await client.recvLine()
  if firstLine.len == 0:
    client.close()
    return

  var headers = initTable[string, string]()
  var wsKey = ""

  while true:
    let line = await client.recvLine()
    if line == "\r" or line == "":
      break
    let parts = line.split(":", maxSplit = 1)
    if parts.len >= 2:
      let key = parts[0].strip().toLower()
      let val = parts[1].strip()
      headers[key] = val
      if key == "sec-websocket-key":
        wsKey = val

  if wsKey.len == 0:
    await client.send("HTTP/1.1 400 Bad Request\r\n\r\n")
    client.close()
    return

  # Auth check
  if server.config.authEnabled:
    let authHeader = headers.getOrDefault("authorization", "")
    if authHeader.len == 0 or not authHeader.startsWith("Bearer "):
      await client.send("HTTP/1.1 401 Unauthorized\r\n\r\n")
      client.close()
      return
    let tokenStr = authHeader[7..^1]
    try:
      let token = tokenStr.toJWT()
      if not token.verify(server.secretKey, HS256):
        await client.send("HTTP/1.1 401 Unauthorized\r\n\r\n")
        client.close()
        return
    except:
      await client.send("HTTP/1.1 401 Unauthorized\r\n\r\n")
      client.close()
      return

  let acceptKey = computeAcceptKey(wsKey)

  var response = "HTTP/1.1 101 Switching Protocols\r\n"
  response &= "Upgrade: websocket\r\n"
  response &= "Connection: Upgrade\r\n"
  response &= "Sec-WebSocket-Accept: " & acceptKey & "\r\n"
  response &= "Access-Control-Allow-Origin: *\r\n"
  response &= "\r\n"
  await client.send(response)

  inc server.nextId
  asyncCheck server.handleWsClient(client, server.nextId)

proc run*(server: WsServer, port: int = 9471) {.async.} =
  server.running = true
  let sock = newAsyncSocket()
  sock.setSockOpt(OptReuseAddr, true)
  sock.bindAddr(Port(port))
  sock.listen()
  echo "BaraDB WebSocket listening on port ", port

  while server.running:
    let client = await sock.accept()
    asyncCheck server.handleConnection(client)

proc stop*(server: WsServer) =
  server.running = false
