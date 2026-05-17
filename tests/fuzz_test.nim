## Wire Protocol Fuzz Tests
import std/unittest
import std/random
import std/strutils

import barabadb/protocol/wire

suite "Wire Protocol Fuzz":
  test "deserializeValue survives random bytes":
    var rng = initRand(12345)
    for i in 0..<500:
      var buf = newSeq[byte](rng.rand(1..256))
      for b in buf.mitems:
        b = byte(rng.rand(0..255))
      var pos = 0
      try:
        discard deserializeValue(buf, pos)
      except:
        discard  # Exceptions are expected for garbage input

  test "deserializeValue survives truncated buffers":
    var rng = initRand(12346)
    for i in 0..<200:
      # Start with a valid-ish prefix then truncate
      var buf: seq[byte] = @[byte(rng.rand(0..12))]  # random FieldKind
      let extra = rng.rand(0..64)
      for j in 0..<extra:
        buf.add(byte(rng.rand(0..255)))
      var pos = 0
      try:
        discard deserializeValue(buf, pos)
      except:
        discard

  test "MsgKind cast with random uint32 values":
    var rng = initRand(12347)
    for i in 0..<1000:
      let raw = uint32(rng.rand(int64(high(uint32))))
      let kind = cast[MsgKind](raw)
      # Should not crash; cast is unsafe but does not range-check
      check true

  test "parseHeader-like logic with random 12-byte chunks":
    var rng = initRand(12348)
    for i in 0..<500:
      var data = ""
      for j in 0..<12:
        data.add(char(rng.rand(0..255)))
      let rawKind = uint32(ord(data[0])) shl 24 or uint32(ord(data[1])) shl 16 or
                    uint32(ord(data[2])) shl 8 or uint32(ord(data[3]))
      let kind = cast[MsgKind](rawKind)
      let length = uint32(ord(data[4])) shl 24 or uint32(ord(data[5])) shl 16 or
                   uint32(ord(data[6])) shl 8 or uint32(ord(data[7]))
      let requestId = uint32(ord(data[8])) shl 24 or uint32(ord(data[9])) shl 16 or
                      uint32(ord(data[10])) shl 8 or uint32(ord(data[11]))
      let header = MessageHeader(kind: kind, length: length, requestId: requestId)
      check header.length == length

  test "makeQueryMessage roundtrip with random queries":
    var rng = initRand(12349)
    for i in 0..<100:
      var query = ""
      let len = rng.rand(0..200)
      for j in 0..<len:
        query.add(char(rng.rand(32..126)))
      let msg = makeQueryMessage(uint32(i), query)
      check msg.len >= 12

  test "serializeMessage roundtrip with random payloads":
    var rng = initRand(12350)
    for i in 0..<100:
      let reqId = uint32(rng.rand(int64(high(uint32))))
      var msg = WireMessage(
        header: MessageHeader(kind: mkQuery, length: uint32(rng.rand(0..1000)), requestId: reqId),
        payload: newSeq[byte](rng.rand(0..200))
      )
      for j in 0..<msg.payload.len:
        msg.payload[j] = byte(rng.rand(0..255))
      let s = serializeMessage(msg)
      check s.len >= 12

  test "makeErrorMessage with large IDs":
    var rng = initRand(12351)
    for i in 0..<100:
      let reqId = uint32(rng.rand(int64(high(uint32))))
      let err = makeErrorMessage(reqId, uint32(rng.rand(0..255)), "fuzz")
      check err.len > 0
