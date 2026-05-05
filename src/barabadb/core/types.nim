import std/times
import std/oids
import std/monotimes

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
