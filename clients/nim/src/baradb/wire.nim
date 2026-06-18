## BaraDB binary wire protocol — shared between client and server.
import std/endians

const
  ProtocolMagic* = 0x42415241'u32

type
  FieldKind* = enum
    fkNull = 0x00
    fkBool = 0x01
    fkInt8 = 0x02
    fkInt16 = 0x03
    fkInt32 = 0x04
    fkInt64 = 0x05
    fkFloat32 = 0x06
    fkFloat64 = 0x07
    fkString = 0x08
    fkBytes = 0x09
    fkArray = 0x0A
    fkObject = 0x0B
    fkVector = 0x0C
    fkJson = 0x0D

  MsgKind* = enum
    mkClientHandshake = 0x01
    mkQuery = 0x02
    mkQueryParams = 0x03
    mkExecute = 0x04
    mkBatch = 0x05
    mkTransaction = 0x06
    mkClose = 0x07
    mkPing = 0x08
    mkAuth = 0x09
    mkServerHandshake = 0x80
    mkReady = 0x81
    mkData = 0x82
    mkComplete = 0x83
    mkError = 0x84
    mkAuthChallenge = 0x85
    mkAuthOk = 0x86
    mkSchemaChange = 0x87
    mkPong = 0x88
    mkTransactionState = 0x89

  ResultFormat* = enum
    rfBinary = 0x00
    rfJson = 0x01
    rfText = 0x02

  WireValue* = object
    case kind*: FieldKind
    of fkNull: discard
    of fkBool: boolVal*: bool
    of fkInt8: int8Val*: int8
    of fkInt16: int16Val*: int16
    of fkInt32: int32Val*: int32
    of fkInt64: int64Val*: int64
    of fkFloat32: float32Val*: float32
    of fkFloat64: float64Val*: float64
    of fkString: strVal*: string
    of fkBytes: bytesVal*: seq[byte]
    of fkArray: arrayVal*: seq[WireValue]
    of fkObject: objVal*: seq[(string, WireValue)]
    of fkVector: vecVal*: seq[float32]
    of fkJson: jsonVal*: string

proc writeUint32*(buf: var seq[byte], val: uint32) =
  var bytes: array[4, byte]
  bigEndian32(addr bytes, unsafeAddr val)
  buf.add(bytes)

proc writeUint64(buf: var seq[byte], val: uint64) =
  var bytes: array[8, byte]
  bigEndian64(addr bytes, unsafeAddr val)
  buf.add(bytes)

proc writeString*(buf: var seq[byte], s: string) =
  buf.writeUint32(uint32(s.len))
  for ch in s:
    buf.add(byte(ch))

proc readUint32*(buf: openArray[byte], pos: var int): uint32 =
  var bytes: array[4, byte]
  for i in 0..3: bytes[i] = buf[pos + i]
  bigEndian32(addr result, unsafeAddr bytes)
  pos += 4

proc readUint64*(buf: openArray[byte], pos: var int): uint64 =
  var bytes: array[8, byte]
  for i in 0..7: bytes[i] = buf[pos + i]
  bigEndian64(addr result, unsafeAddr bytes)
  pos += 8

proc readString*(buf: openArray[byte], pos: var int): string =
  let len = int(readUint32(buf, pos))
  result = newString(len)
  for i in 0..<len:
    result[i] = char(buf[pos + i])
  pos += len

proc toBytes*(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s:
    result[i] = byte(c)

proc toString*(s: seq[byte]): string =
  result = newString(s.len)
  for i, b in s:
    result[i] = char(b)

proc serializeValue*(buf: var seq[byte], val: WireValue) =
  buf.add(byte(val.kind))
  case val.kind
  of fkNull: discard
  of fkBool: buf.add(if val.boolVal: 1'u8 else: 0'u8)
  of fkInt8: buf.add(uint8(val.int8Val))
  of fkInt16:
    var bytes16: array[2, byte]
    bigEndian16(addr bytes16, unsafeAddr val.int16Val)
    buf.add(bytes16)
  of fkInt32: buf.writeUint32(uint32(val.int32Val))
  of fkInt64: buf.writeUint64(uint64(val.int64Val))
  of fkFloat32:
    var bytes32: array[4, byte]
    copyMem(addr bytes32, unsafeAddr val.float32Val, 4)
    buf.add(bytes32)
  of fkFloat64:
    var bytes: array[8, byte]
    copyMem(addr bytes, unsafeAddr val.float64Val, 8)
    buf.add(bytes)
  of fkString: buf.writeString(val.strVal)
  of fkBytes:
    buf.writeUint32(uint32(val.bytesVal.len))
    buf.add(val.bytesVal)
  of fkArray:
    buf.writeUint32(uint32(val.arrayVal.len))
    for item in val.arrayVal:
      buf.serializeValue(item)
  of fkObject:
    buf.writeUint32(uint32(val.objVal.len))
    for (name, item) in val.objVal:
      buf.writeString(name)
      buf.serializeValue(item)
  of fkVector:
    buf.writeUint32(uint32(val.vecVal.len))
    for f in val.vecVal:
      var fb: array[4, byte]
      copyMem(addr fb, unsafeAddr f, 4)
      buf.add(fb)
  of fkJson: buf.writeString(val.jsonVal)

proc deserializeValue*(buf: openArray[byte], pos: var int): WireValue =
  let kind = FieldKind(buf[pos])
  inc pos
  case kind
  of fkNull: result = WireValue(kind: fkNull)
  of fkBool:
    result = WireValue(kind: fkBool, boolVal: buf[pos] != 0)
    inc pos
  of fkInt8:
    result = WireValue(kind: fkInt8, int8Val: cast[int8](buf[pos]))
    inc pos
  of fkInt16:
    var bytes16: array[2, byte]
    for i in 0..1: bytes16[i] = buf[pos + i]
    var v16: int16
    bigEndian16(addr v16, unsafeAddr bytes16)
    result = WireValue(kind: fkInt16, int16Val: v16)
    pos += 2
  of fkInt32:
    result = WireValue(kind: fkInt32, int32Val: int32(readUint32(buf, pos)))
  of fkInt64:
    result = WireValue(kind: fkInt64, int64Val: int64(readUint64(buf, pos)))
  of fkFloat32:
    var v32: float32
    copyMem(addr v32, addr buf[pos], 4)
    result = WireValue(kind: fkFloat32, float32Val: v32)
    pos += 4
  of fkFloat64:
    var v: float64
    copyMem(addr v, addr buf[pos], 8)
    result = WireValue(kind: fkFloat64, float64Val: v)
    pos += 8
  of fkString:
    result = WireValue(kind: fkString, strVal: readString(buf, pos))
  of fkBytes:
    let blen = int(readUint32(buf, pos))
    var bval: seq[byte] = @[]
    for i in 0..<blen:
      bval.add(buf[pos + i])
    result = WireValue(kind: fkBytes, bytesVal: bval)
    pos += blen
  of fkArray:
    let count = int(readUint32(buf, pos))
    var arr: seq[WireValue] = @[]
    for i in 0..<count:
      arr.add(deserializeValue(buf, pos))
    result = WireValue(kind: fkArray, arrayVal: arr)
  of fkObject:
    let count = int(readUint32(buf, pos))
    var obj: seq[(string, WireValue)] = @[]
    for i in 0..<count:
      let name = readString(buf, pos)
      let val = deserializeValue(buf, pos)
      obj.add((name, val))
    result = WireValue(kind: fkObject, objVal: obj)
  of fkVector:
    let dim = int(readUint32(buf, pos))
    var vec: seq[float32] = @[]
    for i in 0..<dim:
      var fv: float32
      copyMem(addr fv, addr buf[pos], 4)
      vec.add(fv)
      pos += 4
    result = WireValue(kind: fkVector, vecVal: vec)
  of fkJson:
    result = WireValue(kind: fkJson, jsonVal: readString(buf, pos))

proc buildMessage*(kind: MsgKind, requestId: uint32, payload: seq[byte]): seq[byte] =
  result = @[]
  result.writeUint32(uint32(kind))
  result.writeUint32(uint32(payload.len))
  result.writeUint32(requestId)
  result.add(payload)

proc makeQueryMessage*(requestId: uint32, query: string): seq[byte] =
  var payload: seq[byte] = @[]
  payload.writeString(query)
  payload.add(byte(rfBinary))
  buildMessage(mkQuery, requestId, payload)

proc makeQueryParamsMessage*(requestId: uint32, query: string, params: seq[WireValue]): seq[byte] =
  var payload: seq[byte] = @[]
  payload.writeString(query)
  payload.add(byte(rfBinary))
  payload.writeUint32(uint32(params.len))
  for p in params:
    payload.serializeValue(p)
  buildMessage(mkQueryParams, requestId, payload)

proc makeAuthMessage*(requestId: uint32, token: string): seq[byte] =
  var payload: seq[byte] = @[]
  payload.writeString(token)
  buildMessage(mkAuth, requestId, payload)
