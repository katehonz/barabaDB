import std/[strutils, json, times, parseutils]
import db_connector/db_common
import query_hooks
export db_common

import baradb/client
export client.WireValue, client.FieldKind

type
  DbConn* = SyncClient
  PStmt = object
    sql: string

  varcharType* = string
  intType* = int
  floatType* = float
  boolType* = bool
  timestampType* = DateTime
  serialType* = int
  jsonType* = JsonNode

var jsonTimeFormat* = "yyyy-MM-dd HH:mm:ss"

proc dbError*(db: DbConn) {.noreturn.} =
  var e: ref DbError
  new(e)
  e.msg = "BaraDB query failed"
  raise e

proc prepareStmt*(db: DbConn; q: string): PStmt =
  when defined(debugOrminTrace):
    echo "[[Ormin Executing]]: ", q
  result.sql = q

template startBindings*(s: PStmt; n: int) {.dirty.} =
  var pparams: seq[WireValue] = newSeq[WireValue](n)

template bindParam*(db: DbConn; s: PStmt; idx: int; x: untyped; t: untyped) =
  when t is DateTime:
    let xx = x.format("yyyy-MM-dd HH:mm:ss")
    pparams[idx-1] = WireValue(kind: fkString, strVal: $xx)
  elif t is int or t is int64:
    pparams[idx-1] = WireValue(kind: fkInt64, int64Val: int64(x))
  elif t is float or t is float64:
    pparams[idx-1] = WireValue(kind: fkFloat64, float64Val: float64(x))
  elif t is bool:
    pparams[idx-1] = WireValue(kind: fkBool, boolVal: bool(x))
  elif t is string:
    pparams[idx-1] = WireValue(kind: fkString, strVal: string(x))
  elif t is JsonNode:
    pparams[idx-1] = WireValue(kind: fkJson, jsonVal: $x)
  else:
    pparams[idx-1] = WireValue(kind: fkString, strVal: $x)

template bindNullParam*(db: DbConn; s: PStmt; idx: int) =
  pparams[idx-1] = WireValue(kind: fkNull)

template bindParamJson*(db: DbConn; s: PStmt; idx: int; xx: JsonNode;
                        t: typedesc) =
  let x = xx
  if x.kind == JNull:
    pparams[idx-1] = WireValue(kind: fkNull)
  else:
    bindFromJson(db, s, idx, x, t)

template bindFromJson*(db: DbConn; s: PStmt; idx: int; x: JsonNode;
                       t: typedesc) =
  {.error: "invalid type for JSON object".}

template bindFromJson*(db: DbConn; s: PStmt; idx: int; x: JsonNode;
                       t: typedesc[string]) =
  doAssert x.kind == JString
  pparams[idx-1] = WireValue(kind: fkString, strVal: x.str)

template bindFromJson*(db: DbConn; s: PStmt; idx: int; x: JsonNode;
                       t: typedesc[int|int64]) =
  doAssert x.kind == JInt
  pparams[idx-1] = WireValue(kind: fkInt64, int64Val: x.num)

template bindFromJson*(db: DbConn; s: PStmt; idx: int; x: JsonNode;
                       t: typedesc[float64]) =
  doAssert x.kind == JFloat
  pparams[idx-1] = WireValue(kind: fkFloat64, float64Val: x.fnum)

template bindFromJson*(db: DbConn; s: PStmt; idx: int; x: JsonNode;
                       t: typedesc[bool]) =
  doAssert x.kind == JBool
  pparams[idx-1] = WireValue(kind: fkBool, boolVal: x.bval)

template bindFromJson*(db: DbConn; s: PStmt; idx: int; x: JsonNode;
                       t: typedesc[DateTime]) =
  doAssert x.kind == JString
  pparams[idx-1] = WireValue(kind: fkString, strVal: x.str)

template startQuery*(db: DbConn; s: PStmt) =
  when declared(pparams):
    var queryResult {.inject.} = db.query(s.sql, pparams)
  else:
    var queryResult {.inject.} = db.query(s.sql)
  var queryI {.inject.} = -1
  var queryLen {.inject.} = queryResult.rowCount

template stopQuery*(db: DbConn; s: PStmt) =
  discard

template stepQuery*(db: DbConn; s: PStmt; returnsData: bool): bool =
  inc queryI
  queryI < queryLen

template getLastId*(db: DbConn; s: PStmt): int =
  0

template getAffectedRows*(db: DbConn; s: PStmt): int =
  queryResult.affectedRows

proc close*(db: DbConn) =
  client.close(db)

proc open*(connection, user, password, database: string): DbConn =
  let colonPos = connection.find(':')
  let host = if colonPos < 0: connection else: connection[0..<colonPos]
  let portStr = if colonPos < 0: "9472" else: connection[colonPos+1..^1]
  let port = parseInt(portStr)
  let cfg = ClientConfig(
    host: host,
    port: port,
    database: database,
    username: user,
    password: password
  )
  result = newSyncClient(cfg)
  result.connect()

# --- Result binding helpers ---

template currentValue(s: PStmt; idx: int): string =
  queryResult.rows[queryI][idx-1]

template columnIsNull*(db: DbConn; s: PStmt; idx: int): bool =
  currentValue(s, idx).len == 0

template bindResult*(db: DbConn; s: PStmt; idx: int; dest: int;
                     t: typedesc; name: string) =
  dest = int(parseBiggestInt(currentValue(s, idx)))

template bindResult*(db: DbConn; s: PStmt; idx: int; dest: int64;
                     t: typedesc; name: string) =
  dest = parseBiggestInt(currentValue(s, idx))

template bindResult*(db: DbConn; s: PStmt; idx: int; dest: bool;
                     t: typedesc; name: string) =
  let v = currentValue(s, idx)
  dest = v == "true" or v == "1" or v == "t"

template bindResult*(db: DbConn; s: PStmt; idx: int; dest: var string;
                     t: typedesc; name: string) =
  dest = currentValue(s, idx)

template bindResult*(db: DbConn; s: PStmt; idx: int; dest: float64;
                     t: typedesc; name: string) =
  dest = parseFloat(currentValue(s, idx))

template bindResult*(db: DbConn; s: PStmt; idx: int; dest: var DateTime;
                     t: typedesc; name: string) =
  let src = currentValue(s, idx)
  if src.len > 0:
    dest = parse(src, "yyyy-MM-dd HH:mm:ss")
  else:
    dest = initDateTime(1, 1, 1, 0, 0, 0, utc())

template bindResult*(db: DbConn; s: PStmt; idx: int; dest: JsonNode;
                     t: typedesc; name: string) =
  dest = parseJson(currentValue(s, idx))

template bindResult*[T](db: DbConn; s: PStmt; idx: int; dest: var DbValue[T];
                        t: typedesc; name: string) =
  let v = currentValue(s, idx)
  if v.len == 0:
    dest.isNull = true
  else:
    dest.isNull = false
    when T is string:
      dest.value = v
    else:
      bindResult(db, s, idx, dest.value, t, name)

template createJObject*(): untyped = newJObject()
template createJArray*(): untyped = newJArray()

template bindResultJson*(db: DbConn; s: PStmt; idx: int; obj: JsonNode;
                         t: typedesc; name: string) =
  let x = obj
  doAssert x.kind == JObject
  let v = currentValue(s, idx)
  if v.len == 0:
    x[name] = newJNull()
  else:
    bindToJson(db, s, idx, x, t, name)

template bindToJson*(db: DbConn; s: PStmt; idx: int; obj: JsonNode;
                     t: typedesc; name: string) =
  {.error: "invalid type for JSON object".}

template bindToJson*(db: DbConn; s: PStmt; idx: int; obj: JsonNode;
                     t: typedesc[string]; name: string) =
  obj[name] = newJString(currentValue(s, idx))

template bindToJson*(db: DbConn; s: PStmt; idx: int; obj: JsonNode;
                     t: typedesc[int|int64]; name: string) =
  var v: int64
  discard parseBiggestInt(currentValue(s, idx), v)
  obj[name] = newJInt(v)

template bindToJson*(db: DbConn; s: PStmt; idx: int; obj: JsonNode;
                     t: typedesc[float64]; name: string) =
  obj[name] = newJFloat(parseFloat(currentValue(s, idx)))

template bindToJson*(db: DbConn; s: PStmt; idx: int; obj: JsonNode;
                     t: typedesc[bool]; name: string) =
  let v = currentValue(s, idx)
  obj[name] = newJBool(v == "true" or v == "1" or v == "t")

template bindToJson*(db: DbConn; s: PStmt; idx: int; obj: JsonNode;
                     t: typedesc[DateTime]; name: string) =
  var dt: DateTime
  bindResult(db, s, idx, dt, t, name)
  obj[name] = newJString(format(dt, jsonTimeFormat))

template bindToJson*(db: DbConn; s: PStmt; idx: int; obj: JsonNode;
                     t: typedesc[JsonNode]; name: string) =
  obj[name] = parseJson(currentValue(s, idx))
