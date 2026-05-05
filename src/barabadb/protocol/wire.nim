## BaraDB Wire Protocol — binary message format
import std/endians

const
  ProtocolVersion* = 1'u32
  Magic* = 0x42415241'u32  # "BARA"

type
  MsgKind* = enum
    # Client messages
    mkClientHandshake = 0x01
    mkQuery = 0x02
    mkQueryParams = 0x03
    mkExecute = 0x04
    mkBatch = 0x05
    mkTransaction = 0x06
    mkClose = 0x07
    mkPing = 0x08
    mkAuth = 0x09

    # Server messages
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

  MessageHeader* = object
    kind*: MsgKind
    length*: uint32
    requestId*: uint32

  WireMessage* = object
    header*: MessageHeader
    payload*: seq[byte]

  QueryMessage* = object
    query*: string
    format*: ResultFormat
    params*: seq[WireValue]

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

  QueryResult* = object
    columns*: seq[string]
    columnTypes*: seq[FieldKind]
    rows*: seq[seq[WireValue]]
    rowCount*: int
    affectedRows*: int

proc writeUint32(buf: var seq[byte], val: uint32) =
  var bytes: array[4, byte]
  bigEndian32(addr bytes, unsafeAddr val)
  buf.add(bytes)

proc writeUint64(buf: var seq[byte], val: uint64) =
  var bytes: array[8, byte]
  bigEndian64(addr bytes, unsafeAddr val)
  buf.add(bytes)

proc writeString(buf: var seq[byte], s: string) =
  buf.writeUint32(uint32(s.len))
  for ch in s:
    buf.add(byte(ch))

proc writeBytes(buf: var seq[byte], data: openArray[byte]) =
  buf.writeUint32(uint32(data.len))
  for b in data:
    buf.add(b)

proc readUint32(buf: openArray[byte], pos: var int): uint32 =
  var bytes: array[4, byte]
  for i in 0..3:
    bytes[i] = buf[pos + i]
  bigEndian32(addr result, unsafeAddr bytes)
  pos += 4

proc readUint64(buf: openArray[byte], pos: var int): uint64 =
  var bytes: array[8, byte]
  for i in 0..7:
    bytes[i] = buf[pos + i]
  bigEndian64(addr result, unsafeAddr bytes)
  pos += 8

proc readString(buf: openArray[byte], pos: var int): string =
  let len = int(readUint32(buf, pos))
  result = newString(len)
  for i in 0..<len:
    result[i] = char(buf[pos + i])
  pos += len

proc readBytes(buf: openArray[byte], pos: var int): seq[byte] =
  let len = int(readUint32(buf, pos))
  result = newSeq[byte](len)
  for i in 0..<len:
    result[i] = buf[pos + i]
  pos += len

proc serializeValue*(buf: var seq[byte], val: WireValue) =
  buf.add(byte(val.kind))
  case val.kind
  of fkNull: discard
  of fkBool: buf.add(if val.boolVal: 1'u8 else: 0'u8)
  of fkInt8: buf.add(byte(val.int8Val))
  of fkInt16:
    var bytes: array[2, byte]
    bigEndian16(addr bytes, unsafeAddr val.int16Val)
    buf.add(bytes)
  of fkInt32: buf.writeUint32(uint32(val.int32Val))
  of fkInt64: buf.writeUint64(uint64(val.int64Val))
  of fkFloat32:
    var fl = val.float32Val
    var bytes: array[4, byte]
    copyMem(addr bytes, unsafeAddr fl, 4)
    buf.add(bytes)
  of fkFloat64:
    var fl = val.float64Val
    var bytes: array[8, byte]
    copyMem(addr bytes, unsafeAddr fl, 8)
    buf.add(bytes)
  of fkString: buf.writeString(val.strVal)
  of fkBytes: buf.writeBytes(val.bytesVal)
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
      var fl = f
      var bytes: array[4, byte]
      copyMem(addr bytes, unsafeAddr fl, 4)
      buf.add(bytes)

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
    var val: int16
    var bytes: array[2, byte]
    for i in 0..1: bytes[i] = buf[pos + i]
    bigEndian16(addr val, unsafeAddr bytes)
    pos += 2
    result = WireValue(kind: fkInt16, int16Val: val)
  of fkInt32:
    result = WireValue(kind: fkInt32, int32Val: int32(readUint32(buf, pos)))
  of fkInt64:
    result = WireValue(kind: fkInt64, int64Val: int64(readUint64(buf, pos)))
  of fkFloat32:
    var fl: float32
    var bytes: array[4, byte]
    for i in 0..3: bytes[i] = buf[pos + i]
    copyMem(addr fl, unsafeAddr bytes, 4)
    pos += 4
    result = WireValue(kind: fkFloat32, float32Val: fl)
  of fkFloat64:
    var fl: float64
    var bytes: array[8, byte]
    for i in 0..7: bytes[i] = buf[pos + i]
    copyMem(addr fl, unsafeAddr bytes, 8)
    pos += 8
    result = WireValue(kind: fkFloat64, float64Val: fl)
  of fkString:
    result = WireValue(kind: fkString, strVal: readString(buf, pos))
  of fkBytes:
    result = WireValue(kind: fkBytes, bytesVal: readBytes(buf, pos))
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
    let count = int(readUint32(buf, pos))
    var vec: seq[float32] = @[]
    for i in 0..<count:
      var fl: float32
      var bytes: array[4, byte]
      for j in 0..3: bytes[j] = buf[pos + j]
      copyMem(addr fl, unsafeAddr bytes, 4)
      pos += 4
      vec.add(fl)
    result = WireValue(kind: fkVector, vecVal: vec)

proc serializeMessage*(msg: WireMessage): seq[byte] =
  result = @[]
  result.writeUint32(uint32(msg.header.kind))
  result.writeUint32(msg.header.length)
  result.writeUint32(msg.header.requestId)
  result.add(msg.payload)

proc makeQueryMessage*(requestId: uint32, query: string): seq[byte] =
  var payload: seq[byte] = @[]
  payload.writeString(query)
  payload.add(byte(rfBinary))

  var msg = WireMessage(
    header: MessageHeader(kind: mkQuery, length: uint32(payload.len), requestId: requestId),
    payload: payload,
  )
  return serializeMessage(msg)

proc makeReadyMessage*(requestId: uint32): seq[byte] =
  var payload: seq[byte] = @[]
  payload.add(0'u8)  # idle state
  var msg = WireMessage(
    header: MessageHeader(kind: mkReady, length: uint32(payload.len), requestId: requestId),
    payload: payload,
  )
  return serializeMessage(msg)

proc makeErrorMessage*(requestId: uint32, code: uint32, message: string): seq[byte] =
  var payload: seq[byte] = @[]
  payload.writeUint32(code)
  payload.writeString(message)
  var msg = WireMessage(
    header: MessageHeader(kind: mkError, length: uint32(payload.len), requestId: requestId),
    payload: payload,
  )
  return serializeMessage(msg)

proc makeCompleteMessage*(requestId: uint32, affectedRows: int): seq[byte] =
  var payload: seq[byte] = @[]
  payload.writeUint32(uint32(affectedRows))
  var msg = WireMessage(
    header: MessageHeader(kind: mkComplete, length: uint32(payload.len), requestId: requestId),
    payload: payload,
  )
  return serializeMessage(msg)
