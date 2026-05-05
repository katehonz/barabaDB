## Columnar Engine — column-oriented storage for analytics
import std/tables

type
  ColumnType* = enum
    ctInt64 = "int64"
    ctFloat64 = "float64"
    ctString = "str"
    ctBool = "bool"

  Column*[T] = object
    name*: string
    data*: seq[T]
    nulls*: seq[bool]

  ColumnBatch* = ref object
    columns*: Table[string, ColumnPtr]
    rowCount: int

  ColumnPtr* = ref object
    typ*: ColumnType
    case kind: ColumnType
    of ctInt64: intData: seq[int64]
    of ctFloat64: floatData: seq[float64]
    of ctString: strData: seq[string]
    of ctBool: boolData: seq[bool]

  ChunkedColumn*[T] = ref object
    name: string
    chunks: seq[Column[T]]
    totalLen: int

proc newColumnBatch*(): ColumnBatch =
  ColumnBatch(columns: initTable[string, ColumnPtr](), rowCount: 0)

proc addInt64Col*(batch: var ColumnBatch, name: string): var ColumnPtr =
  var col = ColumnPtr(typ: ctInt64, kind: ctInt64, intData: @[])
  batch.columns[name] = col
  return batch.columns[name]

proc addFloat64Col*(batch: var ColumnBatch, name: string): var ColumnPtr =
  var col = ColumnPtr(typ: ctFloat64, kind: ctFloat64, floatData: @[])
  batch.columns[name] = col
  return batch.columns[name]

proc addStringCol*(batch: var ColumnBatch, name: string): var ColumnPtr =
  var col = ColumnPtr(typ: ctString, kind: ctString, strData: @[])
  batch.columns[name] = col
  return batch.columns[name]

proc addBoolCol*(batch: var ColumnBatch, name: string): var ColumnPtr =
  var col = ColumnPtr(typ: ctBool, kind: ctBool, boolData: @[])
  batch.columns[name] = col
  return batch.columns[name]

proc appendInt64*(col: var ColumnPtr, val: int64, isNull: bool = false) =
  col.intData.add(val)

proc appendFloat64*(col: var ColumnPtr, val: float64, isNull: bool = false) =
  col.floatData.add(val)

proc appendString*(col: var ColumnPtr, val: string, isNull: bool = false) =
  col.strData.add(val)

proc appendBool*(col: var ColumnPtr, val: bool, isNull: bool = false) =
  col.boolData.add(val)

proc rowCount*(batch: ColumnBatch): int =
  var maxRows = 0
  for name, col in batch.columns:
    let cnt = case col.typ
      of ctInt64: col.intData.len
      of ctFloat64: col.floatData.len
      of ctString: col.strData.len
      of ctBool: col.boolData.len
    if cnt > maxRows:
      maxRows = cnt
  return maxRows

proc getInt64*(col: ColumnPtr, row: int): int64 = col.intData[row]
proc getFloat64*(col: ColumnPtr, row: int): float64 = col.floatData[row]
proc getString*(col: ColumnPtr, row: int): string = col.strData[row]
proc getBool*(col: ColumnPtr, row: int): bool = col.boolData[row]

# Encoding techniques
type
  RunLengthEncoding* = ref object
    values: seq[int64]
    counts: seq[int]

  DictionaryEncoding* = ref object
    dict*: seq[string]
    indices*: seq[int32]

proc rleEncode*(data: seq[int64]): RunLengthEncoding =
  result = RunLengthEncoding(values: @[], counts: @[])
  if data.len == 0:
    return
  var current = data[0]
  var count = 1
  for i in 1..<data.len:
    if data[i] == current:
      inc count
    else:
      result.values.add(current)
      result.counts.add(count)
      current = data[i]
      count = 1
  result.values.add(current)
  result.counts.add(count)

proc rleDecode*(rle: RunLengthEncoding): seq[int64] =
  result = @[]
  for i in 0..<rle.values.len:
    for j in 0..<rle.counts[i]:
      result.add(rle.values[i])

proc dictEncode*(data: seq[string]): DictionaryEncoding =
  result = DictionaryEncoding(dict: @[], indices: @[])
  var lookup = initTable[string, int32]()
  for s in data:
    if s notin lookup:
      lookup[s] = int32(result.dict.len)
      result.dict.add(s)
    result.indices.add(lookup[s])

proc dictDecode*(de: DictionaryEncoding): seq[string] =
  result = @[]
  for idx in de.indices:
    result.add(de.dict[idx])

# Aggregation over columnar data
proc sumInt64*(col: ColumnPtr): int64 =
  for v in col.intData:
    result += v

proc sumFloat64*(col: ColumnPtr): float64 =
  for v in col.floatData:
    result += v

proc avgInt64*(col: ColumnPtr): float64 =
  if col.intData.len == 0:
    return 0.0
  return float64(col.sumInt64()) / float64(col.intData.len)

proc avgFloat64*(col: ColumnPtr): float64 =
  if col.floatData.len == 0:
    return 0.0
  return col.sumFloat64() / float64(col.floatData.len)

proc minInt64*(col: ColumnPtr): int64 =
  if col.intData.len == 0:
    return 0
  result = col.intData[0]
  for v in col.intData:
    if v < result:
      result = v

proc maxInt64*(col: ColumnPtr): int64 =
  if col.intData.len == 0:
    return 0
  result = col.intData[0]
  for v in col.intData:
    if v > result:
      result = v

proc minFloat64*(col: ColumnPtr): float64 =
  if col.floatData.len == 0:
    return 0.0
  result = col.floatData[0]
  for v in col.floatData:
    if v < result:
      result = v

proc maxFloat64*(col: ColumnPtr): float64 =
  if col.floatData.len == 0:
    return 0.0
  result = col.floatData[0]
  for v in col.floatData:
    if v > result:
      result = v

proc count*(col: ColumnPtr): int =
  case col.typ
  of ctInt64: col.intData.len
  of ctFloat64: col.floatData.len
  of ctString: col.strData.len
  of ctBool: col.boolData.len

# GroupBy aggregation
type
  GroupByKey* = object
    columns: seq[string]
    values: seq[int]

  GroupByResult* = ref object
    groups*: Table[string, ColumnBatch]

proc groupBy*(batch: ColumnBatch, keyCols: seq[string],
              aggCols: seq[string] = @[]): GroupByResult =
  result = GroupByResult(groups: initTable[string, ColumnBatch]())
  if keyCols.len == 0 or batch.columns.len == 0:
    return

  let rowCount = batch.rowCount()
  for row in 0..<rowCount:
    var key = ""
    for colName in keyCols:
      if colName in batch.columns:
        let col = batch.columns[colName]
        case col.typ
        of ctInt64: key &= col.intData[row].`$` & "/"
        of ctFloat64: key &= col.floatData[row].`$` & "/"
        of ctString: key &= col.strData[row] & "/"
        of ctBool: key &= col.boolData[row].`$` & "/"

    if key notin result.groups:
      result.groups[key] = newColumnBatch()
      for colName, col in batch.columns:
        case col.typ
        of ctInt64: discard result.groups[key].addInt64Col(colName)
        of ctFloat64: discard result.groups[key].addFloat64Col(colName)
        of ctString: discard result.groups[key].addStringCol(colName)
        of ctBool: discard result.groups[key].addBoolCol(colName)

    for colName, col in batch.columns:
      let groupCol = result.groups[key].columns[colName]
      case col.typ
      of ctInt64: groupCol.intData.add(col.intData[row])
      of ctFloat64: groupCol.floatData.add(col.floatData[row])
      of ctString: groupCol.strData.add(col.strData[row])
      of ctBool: groupCol.boolData.add(col.boolData[row])
