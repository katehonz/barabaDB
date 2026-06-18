import std/unittest
import std/asyncdispatch
import std/asyncnet
import std/json
import baradb/wire
import baradb/client

proc buildDataResponse(cols: seq[string], rows: seq[seq[WireValue]], affected: int): seq[byte] =
  var payload: seq[byte] = @[]
  payload.writeUint32(uint32(cols.len))
  for c in cols:
    payload.writeString(c)
  for c in cols:
    payload.add(byte(fkString))
  payload.writeUint32(uint32(rows.len))
  for row in rows:
    for wv in row:
      payload.serializeValue(wv)
  result = buildMessage(mkData, 1'u32, payload)
  var completePayload: seq[byte] = @[]
  completePayload.writeUint32(uint32(affected))
  result.add(buildMessage(mkComplete, 1'u32, completePayload))

suite "Wire protocol":
  test "buildMessage header is 12 bytes + payload":
    let msg = buildMessage(mkQuery, 7'u32, toBytes("SELECT 1"))
    check msg.len == 12 + 8

  test "serialize/deserialize round-trip for WireValue":
    let original = WireValue(kind: fkInt64, int64Val: 42)
    var buf: seq[byte] = @[]
    buf.serializeValue(original)
    var pos = 0
    let decoded = deserializeValue(buf, pos)
    check decoded.kind == fkInt64
    check decoded.int64Val == 42

  test "client query against mock server returns typedRows and rows":
    proc run() {.async.} =
      var server = newAsyncSocket()
      server.setSockOpt(OptReuseAddr, true)
      server.bindAddr(Port(0), "127.0.0.1")
      let port = server.getLocalAddr()[1]
      server.listen()

      proc serve() {.async.} =
        let s = await server.accept()
        let data = buildDataResponse(
          @["name", "age"],
          @[
            @[WireValue(kind: fkString, strVal: "Alice"), WireValue(kind: fkInt32, int32Val: 30)],
          ],
          0,
        )
        await s.send(toString(data))
        s.close()

      asyncCheck serve()

      let client = newClient(ClientConfig(host: "127.0.0.1", port: int(port), timeoutMs: 5000))
      await client.connect()
      let qr = await client.query("SELECT name, age FROM users")
      check qr.rowCount == 1
      check qr.typedRows[0][1].int32Val == 30
      check qr.rows[0][1] == "30"
      client.close()
      server.close()
    waitFor run()
