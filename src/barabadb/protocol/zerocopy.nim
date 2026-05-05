## Zero-Copy Serialization — direct memory access without copies
import std/endians
import std/tables
import std/strutils

type
  ZeroBuf* = object
    data*: ptr UncheckedArray[byte]
    pos*: int
    capacity*: int
    owned*: bool

  ZcTypeKind* = enum
    ztBool
    ztInt8
    ztInt16
    ztInt32
    ztInt64
    ztFloat32
    ztFloat64
    ztString
    ztBytes
    ztUuid
    ztArray
    ztObject
    ztVector

  ZcField* = object
    name*: string
    offset*: int  # byte offset within the record
    typeKind*: ZcTypeKind
    size*: int
    isNullable*: bool

  ZcSchema* = ref object
    fields*: seq[ZcField]
    totalSize*: int
    name*: string

proc newZcSchema*(name: string): ZcSchema =
  ZcSchema(name: name, fields: @[], totalSize: 0)

proc addField*(schema: ZcSchema, name: string, kind: ZcTypeKind,
               isNullable: bool = false) =
  let fieldSize = case kind
    of ztBool, ztInt8: 1
    of ztInt16: 2
    of ztInt32, ztFloat32: 4
    of ztInt64, ztFloat64: 8
    of ztString, ztBytes, ztArray, ztObject, ztVector: 16  # pointer + length
    of ztUuid: 16

  schema.fields.add(ZcField(
    name: name, offset: schema.totalSize, typeKind: kind,
    size: fieldSize, isNullable: isNullable,
  ))
  schema.totalSize += fieldSize + (if isNullable: 1 else: 0)

proc getField*(schema: ZcSchema, name: string): ZcField =
  for f in schema.fields:
    if f.name == name:
      return f
  return ZcField()

proc newZeroBuf*(capacity: int): ZeroBuf =
  let p = cast[ptr UncheckedArray[byte]](alloc0(capacity))
  ZeroBuf(data: p, pos: 0, capacity: capacity, owned: true)

proc newZeroBufFrom*(raw: ptr UncheckedArray[byte], len: int): ZeroBuf =
  ZeroBuf(data: raw, pos: 0, capacity: len, owned: false)

proc free*(buf: var ZeroBuf) =
  if buf.owned and buf.data != nil:
    dealloc(buf.data)
    buf.data = nil

proc remaining*(buf: ZeroBuf): int = buf.capacity - buf.pos

proc writeBool*(buf: var ZeroBuf, val: bool) =
  if buf.remaining() >= 1:
    buf.data[buf.pos] = byte(val)
    inc buf.pos

proc readBool*(buf: ZeroBuf, offset: int): bool =
  if offset + 1 <= buf.capacity:
    return buf.data[offset] != 0
  return false

proc writeInt32*(buf: var ZeroBuf, val: int32) =
  if buf.remaining() >= 4:
    bigEndian32(addr buf.data[buf.pos], unsafeAddr val)
    buf.pos += 4

proc readInt32*(buf: ZeroBuf, offset: int): int32 =
  var val: int32
  if offset + 4 <= buf.capacity:
    bigEndian32(addr val, addr buf.data[offset])
  return val

proc writeInt64*(buf: var ZeroBuf, val: int64) =
  if buf.remaining() >= 8:
    bigEndian64(addr buf.data[buf.pos], unsafeAddr val)
    buf.pos += 8

proc readInt64*(buf: ZeroBuf, offset: int): int64 =
  var val: int64
  if offset + 8 <= buf.capacity:
    bigEndian64(addr val, addr buf.data[offset])
  return val

proc writeFloat32*(buf: var ZeroBuf, val: float32) =
  if buf.remaining() >= 4:
    copyMem(addr buf.data[buf.pos], unsafeAddr val, 4)
    buf.pos += 4

proc readFloat32*(buf: ZeroBuf, offset: int): float32 =
  var val: float32
  if offset + 4 <= buf.capacity:
    copyMem(addr val, addr buf.data[offset], 4)
  return val

proc writeFloat64*(buf: var ZeroBuf, val: float64) =
  if buf.remaining() >= 8:
    copyMem(addr buf.data[buf.pos], unsafeAddr val, 8)
    buf.pos += 8

proc readFloat64*(buf: ZeroBuf, offset: int): float64 =
  var val: float64
  if offset + 8 <= buf.capacity:
    copyMem(addr val, addr buf.data[offset], 8)
  return val

proc writeString*(buf: var ZeroBuf, val: string) =
  let headerSize = 8  # len + data ptr (conceptual)
  if buf.remaining() >= headerSize + val.len:
    buf.writeInt64(int64(val.len))
    copyMem(addr buf.data[buf.pos], unsafeAddr val[0], val.len)
    buf.pos += val.len

proc readString*(buf: ZeroBuf, offset: var int): string =
  let len = int(buf.readInt64(offset))
  offset += 8
  if len > 0:
    result = newString(len)
    copyMem(addr result[0], addr buf.data[offset], len)
    offset += len

proc readString*(buf: ZeroBuf, offset: int): (string, int) =
  var pos = offset
  let s = readString(buf, pos)
  return (s, pos - offset)

# Record encoding with schema
proc encodeRecord*(buf: var ZeroBuf, schema: ZcSchema,
                    values: Table[string, string]) =
  # Write fields at their schema offsets
  for field in schema.fields:
    let value = values.getOrDefault(field.name, "")
    let savedPos = buf.pos
    buf.pos = field.offset  # Seek to field offset
    case field.typeKind
    of ztBool:
      buf.data[field.offset] = byte(value == "true" or value == "1")
    of ztInt32:
      try:
        var v = int32(parseInt(value))
        bigEndian32(addr buf.data[field.offset], unsafeAddr v)
      except:
        var v: int32 = 0
        bigEndian32(addr buf.data[field.offset], unsafeAddr v)
    of ztInt64:
      try:
        var v = int64(parseInt(value))
        bigEndian64(addr buf.data[field.offset], unsafeAddr v)
      except:
        var v: int64 = 0
        bigEndian64(addr buf.data[field.offset], unsafeAddr v)
    of ztString:
      buf.data[field.offset] = byte(value.len)
      if value.len > 0:
        copyMem(addr buf.data[field.offset + 4], unsafeAddr value[0], value.len)
    else:
      discard
    buf.pos = savedPos  # Reset pos

proc decodeRecord*(buf: ZeroBuf, schema: ZcSchema): Table[string, string] =
  result = initTable[string, string]()
  for field in schema.fields:
    case field.typeKind
    of ztBool:
      result[field.name] = $readBool(buf, field.offset)
    of ztInt32:
      result[field.name] = $readInt32(buf, field.offset)
    of ztInt64:
      result[field.name] = $readInt64(buf, field.offset)
    of ztFloat32:
      result[field.name] = $readFloat32(buf, field.offset)
    of ztFloat64:
      result[field.name] = $readFloat64(buf, field.offset)
    of ztString:
      var pos = field.offset
      result[field.name] = readString(buf, pos)
    else:
      result[field.name] = ""

# Batch record operations
type
  ZcTable* = ref object
    schema*: ZcSchema
    records*: seq[ZeroBuf]
    totalRows*: int

proc newZcTable*(schema: ZcSchema): ZcTable =
  ZcTable(schema: schema, records: @[], totalRows: 0)

proc addRecord*(table: ZcTable, values: Table[string, string]) =
  var buf = newZeroBuf(table.schema.totalSize)
  buf.encodeRecord(table.schema, values)
  table.records.add(buf)
  inc table.totalRows

proc getRecord*(table: ZcTable, index: int): Table[string, string] =
  if index < table.records.len:
    return table.records[index].decodeRecord(table.schema)
  return initTable[string, string]()

proc clear*(table: ZcTable) =
  for i in 0..<table.records.len:
    table.records[i].free()
  table.records.setLen(0)
  table.totalRows = 0

proc rowCount*(table: ZcTable): int = table.totalRows

# Fast memory copying
proc fastCopy*(src: var ZeroBuf, dst: var ZeroBuf, size: int) =
  let copySize = min(min(src.remaining(), dst.remaining()), size)
  copyMem(addr dst.data[dst.pos], addr src.data[src.pos], copySize)
  src.pos += copySize
  dst.pos += copySize

proc fastCopyFrom*(dst: var ZeroBuf, src: pointer, size: int) =
  if dst.remaining() >= size:
    copyMem(addr dst.data[dst.pos], src, size)
    dst.pos += size

proc slice*(buf: ZeroBuf, offset, size: int): ZeroBuf =
  if offset + size <= buf.capacity:
    return ZeroBuf(data: cast[ptr UncheckedArray[byte]](addr buf.data[offset]),
                   pos: 0, capacity: size, owned: false)
  return ZeroBuf(data: nil, pos: 0, capacity: 0, owned: false)
