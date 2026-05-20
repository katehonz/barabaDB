import std/times
import std/oids
import std/monotimes
import std/strutils

type
  ValueKind* = enum
    vkNull
    vkBool
    vkInt8
    vkInt16
    vkInt32
    vkInt64
    vkFloat32
    vkFloat64
    vkString
    vkBytes
    vkUuid
    vkDateTime
    vkJson
    vkArray
    vkObject
    vkVector

  Value* = object
    case kind*: ValueKind
    of vkNull: discard
    of vkBool: boolVal*: bool
    of vkInt8: int8Val*: int8
    of vkInt16: int16Val*: int16
    of vkInt32: int32Val*: int32
    of vkInt64: int64Val*: int64
    of vkFloat32: float32Val*: float32
    of vkFloat64: float64Val*: float64
    of vkString: strVal*: string
    of vkBytes: bytesVal*: seq[byte]
    of vkUuid: uuidVal*: Oid
    of vkDateTime: dtVal*: DateTime
    of vkJson: jsonVal*: string
    of vkArray: arrayVal*: seq[Value]
    of vkObject: objVal*: seq[(string, Value)]
    of vkVector: vecVal*: seq[float32]

  RecordId* = distinct uint64

  Record* = object
    id*: RecordId
    data*: seq[(string, Value)]

  SchemaKind* = enum
    skScalar
    skObject
    skLink
    skCollection

  ScalarType* = enum
    stBool = "bool"
    stInt8 = "int8"
    stInt16 = "int16"
    stInt32 = "int32"
    stInt64 = "int64"
    stFloat32 = "float32"
    stFloat64 = "float64"
    stString = "str"
    stBytes = "bytes"
    stUuid = "uuid"
    stDateTime = "datetime"
    stJson = "json"
    stVector = "vector"

  Cardinality* = enum
    One
    Many

  PropertyDef* = object
    name*: string
    typ*: ScalarType
    required*: bool
    default*: Value
    computed*: bool
    expr*: string

  LinkDef* = object
    name*: string
    target*: string
    cardinality*: Cardinality
    required*: bool
    properties*: seq[PropertyDef]
    onDelete*: DeleteAction

  DeleteAction* = enum
    daRestrict
    daDeleteSource
    daAllow
    daDeferredRestrict

  ObjectTypeDef* = object
    name*: string
    bases*: seq[string]
    properties*: seq[PropertyDef]
    links*: seq[LinkDef]
    indexes*: seq[IndexDef]
    constraints*: seq[ConstraintDef]

  IndexDef* = object
    name*: string
    expr*: string
    kind*: IndexKind

  IndexKind* = enum
    ikBTree
    ikHash
    ikGiST
    ikGIN
    ikHNSW
    ikIVFPQ
    ikFullText

  ConstraintDef* = object
    name*: string
    expr*: string

proc newRecordId*(): RecordId =
  RecordId(uint64(getMonoTime().ticks()))

proc `==`*(a, b: RecordId): bool {.borrow.}
proc `$`*(r: RecordId): string = $uint64(r)

proc `==`*(a, b: Value): bool {.noSideEffect.} =
  if a.kind != b.kind: return false
  case a.kind
  of vkNull: return true
  of vkBool: return a.boolVal == b.boolVal
  of vkInt8: return a.int8Val == b.int8Val
  of vkInt16: return a.int16Val == b.int16Val
  of vkInt32: return a.int32Val == b.int32Val
  of vkInt64: return a.int64Val == b.int64Val
  of vkFloat32: return a.float32Val == b.float32Val
  of vkFloat64: return a.float64Val == b.float64Val
  of vkString: return a.strVal == b.strVal
  of vkBytes: return a.bytesVal == b.bytesVal
  of vkUuid: return a.uuidVal == b.uuidVal
  of vkDateTime: return false  # DateTime comparison not supported without side effects
  of vkJson: return a.jsonVal == b.jsonVal
  of vkArray: return false  # Recursive comparison not supported
  of vkObject: return false  # Recursive comparison not supported
  of vkVector: return a.vecVal == b.vecVal

proc `!=`*(a, b: Value): bool {.noSideEffect.} =
  return not (a == b)

proc `$`*(v: Value): string =
  case v.kind
  of vkNull: return "\\N"
  of vkBool: return $v.boolVal
  of vkInt8: return $v.int8Val
  of vkInt16: return $v.int16Val
  of vkInt32: return $v.int32Val
  of vkInt64: return $v.int64Val
  of vkFloat32: return $v.float32Val
  of vkFloat64: return $v.float64Val
  of vkString: return v.strVal
  of vkBytes: return "<bytes>"
  of vkUuid: return $v.uuidVal
  of vkDateTime: return $v.dtVal
  of vkJson: return v.jsonVal
  of vkArray: return $v.arrayVal
  of vkObject: return $v.objVal
  of vkVector: return $v.vecVal

proc `==`*(a: Value, b: string): bool =
  if a.kind == vkString: return a.strVal == b
  if a.kind == vkNull: return b == "\\N"
  return $a == b

proc `==`*(a: string, b: Value): bool =
  return b == a

proc `in`*(v: Value, s: seq[string]): bool =
  return $v in s

proc `in`*(s: string, v: Value): bool =
  if v.kind == vkString: return v.strVal.contains(s)
  return ($v).contains(s)
