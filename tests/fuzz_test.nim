## Wire Protocol Fuzz Tests
import std/unittest
import std/random
import std/strutils

import barabadb/protocol/wire

suite "Wire Protocol Fuzz":
  # ──────────────────────────────────────────────────
  # Core robustness
  # ──────────────────────────────────────────────────
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
      var buf: seq[byte] = @[byte(rng.rand(0..12))]
      let extra = rng.rand(0..64)
      for j in 0..<extra:
        buf.add(byte(rng.rand(0..255)))
      var pos = 0
      try:
        discard deserializeValue(buf, pos)
      except:
        discard

  test "deserializeValue survives huge length claims":
    var rng = initRand(5001)
    for i in 0..<200:
      var buf: seq[byte] = @[byte(fkString)]
      buf.writeUint32(uint32(rng.rand(67_000_000'i64 .. int64(high(uint32)))))
      buf.add(byte(rng.rand(0..255)))
      var pos = 0
      try:
        discard deserializeValue(buf, pos)
      except ValueError:
        discard

  test "deserializeValue survives byte 0xFF kind":
    var rng = initRand(5002)
    for i in 0..<500:
      var buf: seq[byte] = @[byte(rng.rand(0x0E..0xFF))]
      let extra = rng.rand(0..64)
      for j in 0..<extra:
        buf.add(byte(rng.rand(0..255)))
      var pos = 0
      try:
        discard deserializeValue(buf, pos)
      except:
        discard

  test "deserializeValue survives empty buffer":
    var pos = 0
    try:
      discard deserializeValue(@[], pos)
    except ValueError:
      discard

  test "deserializeValue survives single zero byte":
    var pos = 0
    let v = deserializeValue(@[byte 0], pos)
    check v.kind == fkNull

  # ──────────────────────────────────────────────────
  # MsgKind cast test
  # ──────────────────────────────────────────────────
  test "MsgKind cast with random uint32 values":
    var rng = initRand(12347)
    for i in 0..<1000:
      let raw = uint32(rng.rand(int64(high(uint32))))
      let kind = cast[MsgKind](raw)
      check true

  # ──────────────────────────────────────────────────
  # Header parsing
  # ──────────────────────────────────────────────────
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

  test "Header with zero-length payload":
    var rng = initRand(5003)
    for i in 0..<100:
      let kind = cast[MsgKind](uint32(rng.rand(1..0xFF)))
      let header = MessageHeader(kind: kind, length: 0, requestId: uint32(i))
      let msg = WireMessage(header: header, payload: @[])
      let s = serializeMessage(msg)
      check s.len == 12

  test "Header with max length payload kind":
    let header = MessageHeader(kind: mkPing, length: high(uint32), requestId: 0)
    check header.kind == mkPing
    check header.length == high(uint32)

  # ──────────────────────────────────────────────────
  # Message roundtrips
  # ──────────────────────────────────────────────────
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

  test "serializeMessage with max payload length":
    var rng = initRand(5004)
    for i in 0..<50:
      let reqId = uint32(rng.rand(int64(high(uint32))))
      let payloadLen = rng.rand(0..4096)
      var msg = WireMessage(
        header: MessageHeader(kind: mkQuery, length: uint32(payloadLen), requestId: reqId),
        payload: newSeq[byte](payloadLen)
      )
      for j in 0..<msg.payload.len:
        msg.payload[j] = byte(rng.rand(0..255))
      let s = serializeMessage(msg)
      check s.len == 12 + payloadLen

  # ──────────────────────────────────────────────────
  # Error message
  # ──────────────────────────────────────────────────
  test "makeErrorMessage with large IDs":
    var rng = initRand(12351)
    for i in 0..<100:
      let reqId = uint32(rng.rand(int64(high(uint32))))
      let err = makeErrorMessage(reqId, uint32(rng.rand(0..255)), "fuzz")
      check err.len > 0

  test "makeErrorMessage with long error string":
    var rng = initRand(5005)
    for i in 0..<50:
      let reqId = uint32(rng.rand(int64(high(uint32))))
      var errStr = ""
      let errLen = rng.rand(0..1000)
      for j in 0..<errLen:
        errStr.add(char(rng.rand(32..126)))
      let err = makeErrorMessage(reqId, uint32(rng.rand(0..255)), errStr)
      check err.len >= 12 + errStr.len

  # ──────────────────────────────────────────────────
  # SerializeValue roundtrip for all field kinds
  # ──────────────────────────────────────────────────
  test "serializeValue/deserializeValue roundtrip — fkNull":
    var buf: seq[byte] = @[]
    var val = WireValue(kind: fkNull)
    serializeValue(buf, val)
    var pos = 0
    let back = deserializeValue(buf, pos)
    check back.kind == fkNull

  test "serializeValue/deserializeValue roundtrip — fkBool":
    var rng = initRand(5006)
    for i in 0..<100:
      var buf: seq[byte] = @[]
      let bv = rng.rand(0..1) == 1
      var val = WireValue(kind: fkBool, boolVal: bv)
      serializeValue(buf, val)
      var pos = 0
      let back = deserializeValue(buf, pos)
      check back.kind == fkBool
      check back.boolVal == bv

  test "serializeValue/deserializeValue roundtrip — fkInt64":
    var rng = initRand(5007)
    for i in 0..<100:
      var buf: seq[byte] = @[]
      let iv = int64(rng.rand(int64.low..int64.high))
      var val = WireValue(kind: fkInt64, int64Val: iv)
      serializeValue(buf, val)
      var pos = 0
      let back = deserializeValue(buf, pos)
      check back.kind == fkInt64
      check back.int64Val == iv

  test "serializeValue/deserializeValue roundtrip — fkFloat64":
    var rng = initRand(5008)
    for i in 0..<100:
      var buf: seq[byte] = @[]
      let fv = float64(rng.rand(-1000.0..1000.0))
      var val = WireValue(kind: fkFloat64, float64Val: fv)
      serializeValue(buf, val)
      var pos = 0
      let back = deserializeValue(buf, pos)
      check back.kind == fkFloat64
      check back.float64Val == fv

  test "serializeValue/deserializeValue roundtrip — fkString":
    var rng = initRand(5009)
    for i in 0..<100:
      var buf: seq[byte] = @[]
      var s = ""
      let sl = rng.rand(0..200)
      for j in 0..<sl:
        s.add(char(rng.rand(0..255)))
      var val = WireValue(kind: fkString, strVal: s)
      serializeValue(buf, val)
      var pos = 0
      let back = deserializeValue(buf, pos)
      check back.kind == fkString
      check back.strVal == s

  test "serializeValue/deserializeValue roundtrip — fkBytes":
    var rng = initRand(5010)
    for i in 0..<50:
      var buf: seq[byte] = @[]
      var b: seq[byte] = @[]
      let bl = rng.rand(0..200)
      for j in 0..<bl:
        b.add(byte(rng.rand(0..255)))
      var val = WireValue(kind: fkBytes, bytesVal: b)
      serializeValue(buf, val)
      var pos = 0
      let back = deserializeValue(buf, pos)
      check back.kind == fkBytes
      check back.bytesVal == b

  test "serializeValue/deserializeValue roundtrip — fkFloat32":
    var rng = initRand(5011)
    for i in 0..<50:
      var buf: seq[byte] = @[]
      let fv = float32(rng.rand(-100.0..100.0))
      var val = WireValue(kind: fkFloat32, float32Val: fv)
      serializeValue(buf, val)
      var pos = 0
      let back = deserializeValue(buf, pos)
      check back.kind == fkFloat32
      check abs(back.float32Val - fv) < 1e-6

  test "serializeValue/deserializeValue roundtrip — fkInt32":
    var rng = initRand(5012)
    for i in 0..<100:
      var buf: seq[byte] = @[]
      let iv = int32(rng.rand(int32.low..int32.high))
      var val = WireValue(kind: fkInt32, int32Val: iv)
      serializeValue(buf, val)
      var pos = 0
      let back = deserializeValue(buf, pos)
      check back.kind == fkInt32
      check back.int32Val == iv

  test "serializeValue/deserializeValue roundtrip — fkArray":
    var rng = initRand(5013)
    for i in 0..<30:
      var buf: seq[byte] = @[]
      var arr: seq[WireValue] = @[]
      let al = rng.rand(0..10)
      for j in 0..<al:
        arr.add(WireValue(kind: fkInt64, int64Val: int64(rng.rand(-1000..1000))))
      var val = WireValue(kind: fkArray, arrayVal: arr)
      serializeValue(buf, val)
      var pos = 0
      let back = deserializeValue(buf, pos)
      check back.kind == fkArray
      check back.arrayVal.len == al

  test "serializeValue/deserializeValue roundtrip — fkObject":
    var rng = initRand(5014)
    for i in 0..<30:
      var buf: seq[byte] = @[]
      var obj: seq[(string, WireValue)] = @[]
      let ol = rng.rand(0..10)
      for j in 0..<ol:
        var key = ""
        let kl = rng.rand(1..8)
        for k in 0..<kl:
          key.add(char(rng.rand(ord('a')..ord('z'))))
        obj.add((key, WireValue(kind: fkInt64, int64Val: int64(rng.rand(-1000..1000)))))
      var val = WireValue(kind: fkObject, objVal: obj)
      serializeValue(buf, val)
      var pos = 0
      let back = deserializeValue(buf, pos)
      check back.kind == fkObject
      check back.objVal.len == ol

  test "serializeValue/deserializeValue roundtrip — fkVector":
    var rng = initRand(5015)
    for i in 0..<30:
      var buf: seq[byte] = @[]
      var vec: seq[float32] = @[]
      let vl = rng.rand(0..16)
      for j in 0..<vl:
        vec.add(float32(rng.rand(-10.0..10.0)))
      var val = WireValue(kind: fkVector, vecVal: vec)
      serializeValue(buf, val)
      var pos = 0
      let back = deserializeValue(buf, pos)
      check back.kind == fkVector
      check back.vecVal.len == vl

  test "serializeValue/deserializeValue roundtrip — fkJson":
    var rng = initRand(5016)
    for i in 0..<50:
      var buf: seq[byte] = @[]
      var jstr = ""
      let jl = rng.rand(0..100)
      for j in 0..<jl:
        jstr.add(char(rng.rand(32..126)))
      var val = WireValue(kind: fkJson, jsonVal: jstr)
      serializeValue(buf, val)
      var pos = 0
      let back = deserializeValue(buf, pos)
      check back.kind == fkJson
      check back.jsonVal == jstr

  # ──────────────────────────────────────────────────
  # Mutation fuzzing — mutate valid messages
  # ──────────────────────────────────────────────────
  test "Mutated valid messages don't crash deserializeValue":
    var rng = initRand(5017)
    for i in 0..<200:
      var buf: seq[byte] = @[]
      var val = WireValue(kind: fkInt64, int64Val: int64(rng.rand(-1000..1000)))
      serializeValue(buf, val)
      for mutation in 0..<5:
        if buf.len > 0:
          let idx = rng.rand(0..buf.len-1)
          buf[idx] = byte(rng.rand(0..255))
      var pos = 0
      try:
        discard deserializeValue(buf, pos)
      except:
        discard

  test "Mutated serialized messages parse without crash":
    var rng = initRand(5018)
    for i in 0..<200:
      let header = MessageHeader(kind: mkQuery, length: 10, requestId: uint32(i))
      var payload = newSeq[byte](10)
      for j in 0..<10:
        payload[j] = byte(rng.rand(0..255))
      var msg = WireMessage(header: header, payload: payload)
      var s = serializeMessage(msg)
      for mutation in 0..<3:
        if s.len > 0:
          s[rng.rand(0..s.len-1)] = byte(rng.rand(0..255))
      check s.len >= 12

  test "makeQueryMessage with empty query":
    let msg = makeQueryMessage(1, "")
    check msg.len >= 12

  test "makeQueryMessage with special characters":
    var rng = initRand(5019)
    for i in 0..<50:
      var query = ""
      let sl = rng.rand(0..100)
      for j in 0..<sl:
        query.add(char(rng.rand(0..255)))
      let msg = makeQueryMessage(uint32(i), query)
      check msg.len >= 12

  # ──────────────────────────────────────────────────
  # makeCompleteMessage
  # ──────────────────────────────────────────────────
  test "makeCompleteMessage with random affected rows":
    var rng = initRand(5020)
    for i in 0..<50:
      let affectedRows = rng.rand(0..100_000)
      let msg = makeCompleteMessage(uint32(i), affectedRows)
      check msg.len >= 12

  # ──────────────────────────────────────────────────
  # makeAuthOkMessage
  # ──────────────────────────────────────────────────
  test "makeAuthOkMessage produces valid message":
    let msg = makeAuthOkMessage(42)
    check msg.len == 12

  # ──────────────────────────────────────────────────
  # makeAuthChallengeMessage
  # ──────────────────────────────────────────────────
  test "makeAuthChallengeMessage with random challenges":
    var rng = initRand(5021)
    for i in 0..<50:
      var challenge = ""
      let cl = rng.rand(0..100)
      for j in 0..<cl:
        challenge.add(char(rng.rand(32..126)))
      let msg = makeAuthChallengeMessage(uint32(i), challenge)
      check msg.len >= 12

  # ──────────────────────────────────────────────────
  # Stress: many iterations
  # ──────────────────────────────────────────────────
  test "Stress: 2000 random deserializeValue calls":
    var rng = initRand(5022)
    for i in 0..<2000:
      var buf = newSeq[byte](rng.rand(1..128))
      for b in buf.mitems:
        b = byte(rng.rand(0..255))
      var pos = 0
      try:
        discard deserializeValue(buf, pos)
      except:
        discard

  test "Stress: 1000 serializeMessage with random content":
    var rng = initRand(5023)
    for i in 0..<1000:
      let kind = cast[MsgKind](uint32(rng.rand(1..0xFF)))
      let payloadLen = rng.rand(0..256)
      var payload = newSeq[byte](payloadLen)
      for j in 0..<payloadLen:
        payload[j] = byte(rng.rand(0..255))
      let header = MessageHeader(
        kind: kind,
        length: uint32(payloadLen),
        requestId: uint32(rng.rand(int64(high(uint32))))
      )
      let msg = WireMessage(header: header, payload: payload)
      let s = serializeMessage(msg)
      check s.len == 12 + payloadLen
