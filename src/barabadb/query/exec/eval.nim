## Expression evaluation (evalExpr/evalExprOld/evalExprLegacy) and hybrid
## search — extracted from executor.nim (Task 5 of the executor split).
##
## This code calls back into plan execution (subqueries) and table scans.
## Those procs live in executor.nim, which imports this module, so the
## back-edges go through the proc-var hooks below (Nim forbids circular
## imports). executor.nim wires them at module scope.
import std/strutils
import std/tables
import std/sequtils
import std/algorithm
import std/math
import std/json
import std/times
import std/random
import std/locks
import std/re
import std/monotimes
import ../lexer as qlex
import ../parser as qpar
import ../ast
import ../ir
import ../../core/types
import ../../protocol/wire
import ../../fts/engine as fts
import ../../vector/engine as vengine
import ../../graph/engine as gengine
import ../../graph/cypher as cyphermod
import ../../ai/chunk as chunkmod
import ../../ai/embed as embedmod
import ../../ai/llm as llmmod

import types
import values
import helpers

## Wired by executor.nim at module load. Breaks the eval <-> executePlan /
## execScan module cycle (subqueries, hybrid search).
var executePlanHook*: proc(ctx: ExecutionContext, plan: IRPlan): seq[Row]
var execScanHook*: proc(ctx: ExecutionContext, table: string): seq[Row]
var executeQueryHook*: proc(ctx: ExecutionContext, astNode: Node, params: seq[WireValue]): ExecResult

proc requireExecutePlanHook(): proc(ctx: ExecutionContext, plan: IRPlan): seq[Row] =
  if executePlanHook == nil:
    raise newException(ValueError, "executePlanHook not wired (import barabadb/query/executor)")
  executePlanHook

proc requireExecScanHook(): proc(ctx: ExecutionContext, table: string): seq[Row] =
  if execScanHook == nil:
    raise newException(ValueError, "execScanHook not wired (import barabadb/query/executor)")
  execScanHook

proc requireExecuteQueryHook(): proc(ctx: ExecutionContext, astNode: Node, params: seq[WireValue]): ExecResult =
  if executeQueryHook == nil:
    raise newException(ValueError, "executeQueryHook not wired (import barabadb/query/executor)")
  executeQueryHook

# ----------------------------------------------------------------------
# Hybrid Search Helpers
# ----------------------------------------------------------------------

proc reciprocalRankFusion(vecResults: seq[(uint64, float64)], ftsResults: seq[fts.SearchResult], k: float64 = 60.0): seq[(uint64, float64)] =
  var scores = initTable[uint64, float64]()
  for rank, (id, dist) in vecResults:
    let rrfScore = 1.0 / (k + float64(rank + 1))
    scores[id] = scores.getOrDefault(id, 0.0) + rrfScore
  for rank, res in ftsResults:
    let rrfScore = 1.0 / (k + float64(rank + 1))
    scores[res.docId] = scores.getOrDefault(res.docId, 0.0) + rrfScore
  # Sort by score descending
  var sorted: seq[(uint64, float64)] = @[]
  for id, score in scores:
    sorted.add((id, score))
  sorted.sort(proc(a, b: (uint64, float64)): int =
    if a[1] > b[1]: return -1
    elif a[1] < b[1]: return 1
    else: return 0)
  return sorted

proc realIdFromKey(key: string): string =
  let eqPos = key.find('=')
  if eqPos >= 0:
    return key[eqPos+1..^1]
  return key

proc findRealIdByDocId(ctx: ExecutionContext, table: string, docId: uint64): string =
  for row in requireExecScanHook()(ctx, table):
    if "$key" in row:
      let docKey = table & "." & valueToString(row["$key"])
      var hash: uint64 = 0
      for ch in docKey:
        hash = hash * 31 + uint64(ord(ch))
      if hash == docId:
        return realIdFromKey(valueToString(row["$key"]))
  return ""

proc doHybridSearch(ctx: ExecutionContext, table: string, vecCol: string, textCol: string,
                    queryText: string, queryVectorStr: string, k: int): seq[(string, float64)] =
  result = @[]
  if ctx == nil: return
  let vecKey = table & "." & vecCol
  let textKey = table & "." & textCol
  if vecKey notin ctx.vectorIndexes or textKey notin ctx.ftsIndexes:
    return
  let vecIdx = ctx.vectorIndexes[vecKey]
  let ftsIdx = ctx.ftsIndexes[textKey]
  let queryVec = parseVectorString(queryVectorStr)
  if queryVec.len == 0: return

  # Vector search with metadata
  var vecIdScores = initTable[string, float64]()
  let vecExResults = vengine.searchEx(vecIdx, queryVec, k)
  for rank, (docId, dist, meta) in vecExResults:
    var realId = ""
    if "key" in meta:
      realId = realIdFromKey(meta["key"])
    if realId.len == 0:
      realId = findRealIdByDocId(ctx, table, docId)
    if realId.len > 0:
      let rrfScore = 1.0 / (60.0 + float64(rank + 1))
      vecIdScores[realId] = vecIdScores.getOrDefault(realId, 0.0) + rrfScore

  # FTS search
  let ftsResults = fts.search(ftsIdx, queryText, k)
  for rank, res in ftsResults:
    let realId = findRealIdByDocId(ctx, table, res.docId)
    if realId.len > 0:
      let rrfScore = 1.0 / (60.0 + float64(rank + 1))
      vecIdScores[realId] = vecIdScores.getOrDefault(realId, 0.0) + rrfScore

  # Sort by score descending
  var sorted: seq[(string, float64)] = @[]
  for id, score in vecIdScores:
    sorted.add((id, score))
  sorted.sort(proc(a, b: (string, float64)): int =
    if a[1] > b[1]: return -1
    elif a[1] < b[1]: return 1
    else: return 0)
  if sorted.len > k:
    sorted = sorted[0..<k]
  return sorted

proc doHybridSearchFiltered(ctx: ExecutionContext, table: string, vecCol: string, textCol: string,
                            queryText: string, queryVectorStr: string, k: int,
                            filterCol: string, filterVal: string): seq[(string, float64)] =
  result = @[]
  if ctx == nil: return
  let vecKey = table & "." & vecCol
  let textKey = table & "." & textCol
  if vecKey notin ctx.vectorIndexes or textKey notin ctx.ftsIndexes:
    return
  let vecIdx = ctx.vectorIndexes[vecKey]
  let ftsIdx = ctx.ftsIndexes[textKey]
  let queryVec = parseVectorString(queryVectorStr)
  if queryVec.len == 0: return

  var vecIdScores = initTable[string, float64]()

  # Vector search with metadata filter (pre-filtering)
  let vecFilteredResults = vengine.searchWithFilter(vecIdx, queryVec, k,
    proc(meta: Table[string, string]): bool {.gcsafe.} =
      if filterCol.len == 0: return true
      if filterCol in meta: return meta[filterCol] == filterVal
      return false
  )
  for rank, (docId, dist) in vecFilteredResults:
    let realId = findRealIdByDocId(ctx, table, docId)
    if realId.len > 0:
      let rrfScore = 1.0 / (60.0 + float64(rank + 1))
      vecIdScores[realId] = vecIdScores.getOrDefault(realId, 0.0) + rrfScore

  # FTS search (post-filtering by docId lookup)
  let ftsResults = fts.search(ftsIdx, queryText, k * 3)
  for rank, res in ftsResults:
    let realId = findRealIdByDocId(ctx, table, res.docId)
    if realId.len > 0:
      # Verify filter on actual row data
      var passesFilter = true
      if filterCol.len > 0:
        passesFilter = false
        for row in requireExecScanHook()(ctx, table):
          if realIdFromKey(valueToString(row.getOrDefault("$key", Value(kind: vkNull)))) == realId:
            if filterCol in row and valueToString(row[filterCol]) == filterVal:
              passesFilter = true
            break
      if passesFilter:
        let rrfScore = 1.0 / (60.0 + float64(rank + 1))
        vecIdScores[realId] = vecIdScores.getOrDefault(realId, 0.0) + rrfScore

  # Sort by score descending
  var sorted: seq[(string, float64)] = @[]
  for id, score in vecIdScores:
    sorted.add((id, score))
  sorted.sort(proc(a, b: (string, float64)): int =
    if a[1] > b[1]: return -1
    elif a[1] < b[1]: return 1
    else: return 0)
  if sorted.len > k:
    sorted = sorted[0..<k]
  return sorted

proc stringTableToValueRow(row: Table[string, string]): Row
proc evalExprOld*(expr: IRExpr, row: Table[string, string], ctx: ExecutionContext = nil): string
proc evalExprLegacy*(expr: IRExpr, row: Row, ctx: ExecutionContext = nil): string

proc evalExpr*(expr: IRExpr, row: Row, ctx: ExecutionContext = nil): Value =
  if expr == nil: return Value(kind: vkNull)
  case expr.kind
  of irekLiteral:
    case expr.literal.kind
    of vkString: return Value(kind: vkString, strVal: expr.literal.strVal)
    of vkInt64: return Value(kind: vkInt64, int64Val: expr.literal.int64Val)
    of vkFloat64: return Value(kind: vkFloat64, float64Val: expr.literal.float64Val)
    of vkBool: return Value(kind: vkBool, boolVal: expr.literal.boolVal)
    of vkNull: return Value(kind: vkNull)
    else: return Value(kind: vkNull)
  of irekField:
    if expr.fieldPath.len > 0:
      let fullPath = expr.fieldPath.join(".")
      var s = ""
      var found = false
      if fullPath in row:
        s = valueToString(row[fullPath])
        found = true
      else:
        let colName = expr.fieldPath[^1]
        if colName in row:
          s = valueToString(row[colName])
          found = true
        elif "$key" in row and valueToString(row["$key"]).startsWith(colName & "="):
          s = valueToString(row["$key"])[colName.len+1..^1]
          found = true
        elif "$value" in row:
          let parsed = parseRowData(valueToString(row["$value"]))
          if colName in parsed:
            s = parsed[colName]
            found = true
      if s == "\\N": return Value(kind: vkNull)
      if not found: return Value(kind: vkNull)
      case expr.valueKind
      of vkInt64:
        try: return Value(kind: vkInt64, int64Val: parseInt(s))
        except CatchableError: return Value(kind: vkNull)
      of vkFloat64:
        try: return Value(kind: vkFloat64, float64Val: parseFloat(s))
        except CatchableError: return Value(kind: vkNull)
      of vkBool:
        return Value(kind: vkBool, boolVal: s == "true")
      of vkNull:
        return Value(kind: vkNull)
      else:
        # Heuristic type coercion for arithmetic on string-stored fields
        if s.len == 0: return Value(kind: vkString, strVal: s)
        try:
          return Value(kind: vkInt64, int64Val: parseInt(s))
        except CatchableError:
          try:
            return Value(kind: vkFloat64, float64Val: parseFloat(s))
          except CatchableError:
            return Value(kind: vkString, strVal: s)
    return Value(kind: vkNull)
  of irekBinary:
    case expr.binOp
    of irAdd:
      let lv = evalExpr(expr.binLeft, row, ctx)
      let rv = evalExpr(expr.binRight, row, ctx)
      if lv.kind == vkInt64 and rv.kind == vkInt64:
        return Value(kind: vkInt64, int64Val: lv.int64Val + rv.int64Val)
      elif lv.kind == vkFloat64 and rv.kind == vkFloat64:
        return Value(kind: vkFloat64, float64Val: lv.float64Val + rv.float64Val)
      elif lv.kind == vkInt64 and rv.kind == vkFloat64:
        return Value(kind: vkFloat64, float64Val: float(lv.int64Val) + rv.float64Val)
      elif lv.kind == vkFloat64 and rv.kind == vkInt64:
        return Value(kind: vkFloat64, float64Val: lv.float64Val + float(rv.int64Val))
      elif lv.kind == vkString and rv.kind == vkString:
        return Value(kind: vkString, strVal: lv.strVal & rv.strVal)
      else:
        return Value(kind: vkNull)
    of irSub:
      let lv = evalExpr(expr.binLeft, row, ctx)
      let rv = evalExpr(expr.binRight, row, ctx)
      if lv.kind == vkInt64 and rv.kind == vkInt64:
        return Value(kind: vkInt64, int64Val: lv.int64Val - rv.int64Val)
      elif lv.kind == vkFloat64 and rv.kind == vkFloat64:
        return Value(kind: vkFloat64, float64Val: lv.float64Val - rv.float64Val)
      elif lv.kind == vkInt64 and rv.kind == vkFloat64:
        return Value(kind: vkFloat64, float64Val: float(lv.int64Val) - rv.float64Val)
      elif lv.kind == vkFloat64 and rv.kind == vkInt64:
        return Value(kind: vkFloat64, float64Val: lv.float64Val - float(rv.int64Val))
      else:
        return Value(kind: vkNull)
    of irMul:
      let lv = evalExpr(expr.binLeft, row, ctx)
      let rv = evalExpr(expr.binRight, row, ctx)
      if lv.kind == vkInt64 and rv.kind == vkInt64:
        return Value(kind: vkInt64, int64Val: lv.int64Val * rv.int64Val)
      elif lv.kind == vkFloat64 and rv.kind == vkFloat64:
        return Value(kind: vkFloat64, float64Val: lv.float64Val * rv.float64Val)
      elif lv.kind == vkInt64 and rv.kind == vkFloat64:
        return Value(kind: vkFloat64, float64Val: float(lv.int64Val) * rv.float64Val)
      elif lv.kind == vkFloat64 and rv.kind == vkInt64:
        return Value(kind: vkFloat64, float64Val: lv.float64Val * float(rv.int64Val))
      else:
        return Value(kind: vkNull)
    of irDiv:
      let lv = evalExpr(expr.binLeft, row, ctx)
      let rv = evalExpr(expr.binRight, row, ctx)
      var rvf = 0.0
      if rv.kind == vkFloat64: rvf = rv.float64Val
      elif rv.kind == vkInt64: rvf = float(rv.int64Val)
      else: return Value(kind: vkNull)
      if rvf == 0.0: return Value(kind: vkNull)
      var lvf = 0.0
      if lv.kind == vkFloat64: lvf = lv.float64Val
      elif lv.kind == vkInt64: lvf = float(lv.int64Val)
      else: return Value(kind: vkNull)
      return Value(kind: vkFloat64, float64Val: lvf / rvf)
    of irMod:
      let lv = evalExpr(expr.binLeft, row, ctx)
      let rv = evalExpr(expr.binRight, row, ctx)
      if lv.kind == vkInt64 and rv.kind == vkInt64:
        if rv.int64Val == 0: return Value(kind: vkNull)
        return Value(kind: vkInt64, int64Val: lv.int64Val mod rv.int64Val)
      else:
        return Value(kind: vkNull)
    of irPow:
      let lv = evalExpr(expr.binLeft, row, ctx)
      let rv = evalExpr(expr.binRight, row, ctx)
      var lvf = 0.0
      if lv.kind == vkFloat64: lvf = lv.float64Val
      elif lv.kind == vkInt64: lvf = float(lv.int64Val)
      else: return Value(kind: vkNull)
      var rvf = 0.0
      if rv.kind == vkFloat64: rvf = rv.float64Val
      elif rv.kind == vkInt64: rvf = float(rv.int64Val)
      else: return Value(kind: vkNull)
      return Value(kind: vkFloat64, float64Val: pow(lvf, rvf))
    else:
      let s = evalExprLegacy(expr, row, ctx)
      return Value(kind: vkString, strVal: s)
  of irekUnary:
    case expr.unOp
    of irNeg:
      let v = evalExpr(expr.unExpr, row, ctx)
      case v.kind
      of vkInt64: return Value(kind: vkInt64, int64Val: -v.int64Val)
      of vkFloat64: return Value(kind: vkFloat64, float64Val: -v.float64Val)
      else: return Value(kind: vkNull)
    else:
      let s = evalExprLegacy(expr, row, ctx)
      return Value(kind: vkString, strVal: s)
  else:
    let s = evalExprLegacy(expr, row, ctx)
    return Value(kind: vkString, strVal: s)

proc rowToStringTable(row: Row): Table[string, string] =
  result = initTable[string, string]()
  for k, v in row:
    if v.kind == vkNull:
      result[k] = "\\N"
    else:
      result[k] = valueToString(v)

proc stringTableToValueRow(row: Table[string, string]): Row =
  result = initTable[string, Value]()
  for k, v in row:
    result[k] = Value(kind: vkString, strVal: v)

proc evalExprLegacy*(expr: IRExpr, row: Row, ctx: ExecutionContext = nil): string =
  return evalExprOld(expr, rowToStringTable(row), ctx)

proc evalExprLegacy*(expr: IRExpr, row: Table[string, string], ctx: ExecutionContext = nil): string =
  return evalExprOld(expr, row)

proc evalExprOld*(expr: IRExpr, row: Table[string, string], ctx: ExecutionContext = nil): string =
  if expr == nil: return ""
  case expr.kind
  of irekLiteral:
    case expr.literal.kind
    of vkString: return expr.literal.strVal
    of vkInt64: return $expr.literal.int64Val
    of vkFloat64: return $expr.literal.float64Val
    of vkBool: return $expr.literal.boolVal
    of vkNull: return "\\N"
    else: return "\\N"
  of irekField:
    if expr.fieldPath.len > 0:
      # Check full path first for joined columns (e.g. "u.name")
      let fullPath = expr.fieldPath.join(".")
      if fullPath in row: return row[fullPath]
      let colName = expr.fieldPath[^1]
      if colName in row: return row[colName]
      if "$key" in row and row["$key"].startsWith(colName & "="):
        return row["$key"][colName.len+1..^1]
      if "$value" in row:
        let parsed = parseRowData(row["$value"])
        if colName in parsed: return parsed[colName]
      # Fallback to outer row for correlated subquery references
      if ctx != nil and ctx.outerRow.len > 0:
        if fullPath in ctx.outerRow: return ctx.outerRow[fullPath]
    return "\\N"
  of irekStar:
    return "*"
  of irekJsonPath:
    let srcVal = evalExprOld(expr.jpExpr, row, ctx)
    if srcVal.len == 0 or isNull(srcVal): return "\\N"
    try:
      let node = parseJson(srcVal)
      if node.hasKey(expr.jpKey):
        let val = node[expr.jpKey]
        if expr.jpAsText:
          case val.kind
          of JString: return val.getStr()
          of JInt: return $val.getInt()
          of JFloat: return $val.getFloat()
          of JBool: return $val.getBool()
          of JNull: return "null"
          else: return $val
        else:
          case val.kind
          of JString: return "\"" & val.getStr() & "\""
          of JNull: return "null"
          else: return $val
      return ""
    except CatchableError:
      return ""
  of irekBinary:
    let left = evalExprOld(expr.binLeft, row, ctx)
    let right = evalExprOld(expr.binRight, row, ctx)
    case expr.binOp
    of irEq:
      if left == right: return "true"
      # Try numeric comparison
      try:
        if parseFloat(left) == parseFloat(right): return "true"
      except CatchableError: discard
      return "false"
    of irNeq:
      if left != right: return "true"
      # Try numeric comparison
      try:
        return if parseFloat(left) != parseFloat(right): "true" else: "false"
      except CatchableError: return "false"
    of irLt:
      try:
        return if parseFloat(left) < parseFloat(right): "true" else: "false"
      except CatchableError: return if left < right: "true" else: "false"
    of irLte:
      try:
        return if parseFloat(left) <= parseFloat(right): "true" else: "false"
      except CatchableError: return if left <= right: "true" else: "false"
    of irGt:
      try:
        return if parseFloat(left) > parseFloat(right): "true" else: "false"
      except CatchableError: return if left > right: "true" else: "false"
    of irGte:
      try:
        return if parseFloat(left) >= parseFloat(right): "true" else: "false"
      except CatchableError: return if left >= right: "true" else: "false"
    of irAnd:
      if left == "true" and right == "true": return "true"
      return "false"
    of irOr:
      if left == "true" or right == "true": return "true"
      return "false"
    of irAdd, irSub, irMul, irDiv, irMod, irPow:
      let v = evalExpr(expr, stringTableToValueRow(row), ctx)
      case v.kind
      of vkInt64: return $v.int64Val
      of vkFloat64:
        let s = $v.float64Val
        if s.endsWith(".0"): return s[0..^3]
        return s
      of vkString: return v.strVal
      else: return "\\N"
    of irLike:
      proc escapeRe(s: string): string =
        result = ""
        for ch in s:
          case ch
          of '\\', '.', '*', '+', '?', '|', '^', '$', '(', ')', '[', ']', '{', '}':
            result &= "\\" & ch
          else:
            result &= ch
      let pattern = "^" & escapeRe(right).replace("%", ".*").replace("_", ".") & "$"
      try:
        let rePattern = re(pattern)
        if left.match(rePattern): return "true"
      except CatchableError: discard
      return "false"
    of irILike:
      proc escapeRe(s: string): string =
        result = ""
        for ch in s:
          case ch
          of '\\', '.', '*', '+', '?', '|', '^', '$', '(', ')', '[', ']', '{', '}':
            result &= "\\" & ch
          else:
            result &= ch
      let pattern = "^" & escapeRe(right.toLower()).replace("%", ".*").replace("_", ".") & "$"
      try:
        let rePattern = re(pattern)
        if left.toLower().match(rePattern): return "true"
      except CatchableError: discard
      return "false"
    of irIn:
      if expr.binRight.kind == irekSubquery:
        let subRows = requireExecutePlanHook()(ctx, expr.binRight.subqueryPlan)
        for row in subRows:
          # Compare against the first non-internal column only (SQL semantics)
          var firstVal = ""
          var found = false
          for k, v in row:
            if k.startsWith("$"): continue
            firstVal = valueToString(v)
            found = true
            break
          if found and firstVal == left: return "true"
        return "false"
      try:
        let lv = parseFloat(left)
        let rv = parseFloat(right)
        return if lv == rv: "true" else: "false"
      except CatchableError: discard
      return if left == right: "true" else: "false"
    of irNotIn:
      if expr.binRight.kind == irekSubquery:
        let subRows = requireExecutePlanHook()(ctx, expr.binRight.subqueryPlan)
        for row in subRows:
          # Compare against the first non-internal column only (SQL semantics)
          var firstVal = ""
          var found = false
          for k, v in row:
            if k.startsWith("$"): continue
            firstVal = valueToString(v)
            found = true
            break
          if found and firstVal == left: return "false"
        return "true"
      try:
        let lv = parseFloat(left)
        let rv = parseFloat(right)
        return if lv != rv: "true" else: "false"
      except CatchableError: discard
      return if left != right: "true" else: "false"
    of irFtsMatch:
      # Check for FTS index via ctx
      if ctx != nil and expr.binLeft.kind == irekField and expr.binLeft.fieldPath.len > 0:
        let colName = expr.binLeft.fieldPath[^1]
        # Find FTS index for this column (search by column name suffix)
        var ftsIdx: fts.InvertedIndex = nil
        var ftsKey = ""
        for key, idx in ctx.ftsIndexes:
          if key.endsWith("." & colName):
            ftsIdx = idx
            ftsKey = key
            break
        if ftsIdx != nil:
          let results = ftsIdx.search(right, limit = 10000)
          # Get the row's document key to check if it's in results
          let rowKey = if "$key" in row: row["$key"] else: ""
          let tableName = ftsKey[0..<ftsKey.rfind('.')]
          let docKey = tableName & "." & rowKey
          # Assign docId from key hash
          var docId: uint64 = 0
          for ch in docKey:
            docId = docId * 31 + uint64(ord(ch))
          for r in results:
            if r.docId == docId:
              return "true"
          return "false"
      # Fallback: case-insensitive phrase containment
      let colVal = left.toLower()
      let query = right.toLower()
      let terms = query.split()
      for term in terms:
        if term.len > 0 and term notin colVal:
          return "false"
      return "true"
    of irDistance:
      let vecA = parseVectorString(left)
      let vecB = parseVectorString(right)
      if vecA.len == 0 or vecB.len == 0:
        return "0"
      return $vengine.euclideanDistance(vecA, vecB)
    of irJsonContains:
      # Check if left JSON contains right JSON
      try:
        let leftNode = parseJson(left)
        let rightNode = parseJson(right)
        if leftNode.kind == JObject and rightNode.kind == JObject:
          for key, val in rightNode:
            if not leftNode.hasKey(key) or $(leftNode[key]) != $val:
              return "false"
          return "true"
        elif leftNode.kind == JArray and rightNode.kind == JArray:
          for ritem in rightNode:
            var found = false
            for litem in leftNode:
              if $(litem) == $(ritem):
                found = true
                break
            if not found:
              return "false"
          return "true"
        else:
          return if $(leftNode) == $(rightNode): "true" else: "false"
      except CatchableError:
        return "false"
    of irJsonContainedBy:
      # Check if left JSON is contained by right JSON (reverse of contains)
      try:
        let leftNode = parseJson(left)
        let rightNode = parseJson(right)
        if leftNode.kind == JObject and rightNode.kind == JObject:
          for key, val in leftNode:
            if not rightNode.hasKey(key) or $(rightNode[key]) != $val:
              return "false"
          return "true"
        elif leftNode.kind == JArray and rightNode.kind == JArray:
          for litem in leftNode:
            var found = false
            for ritem in rightNode:
              if $(ritem) == $(litem):
                found = true
                break
            if not found:
              return "false"
          return "true"
        else:
          return if $(leftNode) == $(rightNode): "true" else: "false"
      except CatchableError:
        return "false"
    of irJsonHasAny:
      # Check if JSON object has any of the keys in right array
      try:
        let leftNode = parseJson(left)
        let rightNode = parseJson(right)
        if leftNode.kind == JObject and rightNode.kind == JArray:
          for key in rightNode:
            if key.kind == JString and leftNode.hasKey(key.getStr()):
              return "true"
        return "false"
      except CatchableError:
        return "false"
    of irJsonHasAll:
      # Check if JSON object has all of the keys in right array
      try:
        let leftNode = parseJson(left)
        let rightNode = parseJson(right)
        if leftNode.kind == JObject and rightNode.kind == JArray:
          for key in rightNode:
            if key.kind == JString and not leftNode.hasKey(key.getStr()):
              return "false"
          return "true"
        return "false"
      except CatchableError:
        return "false"
    else: return "false"
  of irekUnary:
    case expr.unOp
    of irNot:
      let v = evalExprOld(expr.unExpr, row, ctx)
      return if v == "true": "false" else: "true"
    of irIsNull:
      let v = evalExprOld(expr.unExpr, row, ctx)
      return if isNull(v): "true" else: "false"
    of irIsNotNull:
      let v = evalExprOld(expr.unExpr, row, ctx)
      return if not isNull(v): "true" else: "false"
    of irNeg:
      let v = evalExpr(expr.unExpr, stringTableToValueRow(row), ctx)
      case v.kind
      of vkInt64: return $(-v.int64Val)
      of vkFloat64:
        let s = $(-v.float64Val)
        if s.endsWith(".0"): return s[0..^3]
        return s
      else: return "0"
    else: return "false"
  of irekFuncCall:
    let fn = expr.irFunc.toLower()
    case fn
    of "cosine_distance", "euclidean_distance", "inner_product", "l2_distance", "l1_distance":
      if expr.irFuncArgs.len < 2:
        return "0"
      let left = evalExprOld(expr.irFuncArgs[0], row, ctx)
      let right = evalExprOld(expr.irFuncArgs[1], row, ctx)
      let vecA = parseVectorString(left)
      let vecB = parseVectorString(right)
      if vecA.len == 0 or vecB.len == 0:
        return "0"
      var dist: float64 = 0.0
      case fn
      of "cosine_distance": dist = vengine.cosineDistance(vecA, vecB)
      of "euclidean_distance", "l2_distance": dist = vengine.euclideanDistance(vecA, vecB)
      of "inner_product": dist = -vengine.dotProduct(vecA, vecB)
      of "l1_distance": dist = vengine.manhattanDistance(vecA, vecB)
      else: dist = 0.0
      return $dist
    of "vector_dims", "vector_dimension":
      if expr.irFuncArgs.len < 1:
        return "0"
      let arg = evalExprOld(expr.irFuncArgs[0], row, ctx)
      return $parseVectorString(arg).len
    of "json_has_key":
      if expr.irFuncArgs.len < 2:
        return "false"
      let jsonStr = evalExprOld(expr.irFuncArgs[0], row, ctx)
      let key = evalExprOld(expr.irFuncArgs[1], row, ctx)
      try:
        let node = parseJson(jsonStr)
        if node.kind == JObject:
          return if node.hasKey(key): "true" else: "false"
        elif node.kind == JArray:
          try:
            let idx = parseInt(key)
            return if idx >= 0 and idx < node.len: "true" else: "false"
          except CatchableError:
            return "false"
        return "false"
      except CatchableError:
        return "false"
    of "current_setting":
      if expr.irFuncArgs.len < 1:
        return ""
      let key = evalExprOld(expr.irFuncArgs[0], row, ctx)
      if ctx != nil and key in ctx.sessionVars:
        return ctx.sessionVars[key]
      return ""
    of "current_user":
      if ctx != nil: return ctx.currentUser
      return ""
    of "current_role":
      if ctx != nil: return ctx.currentRole
      return ""
    of "hybrid_search":
      if expr.irFuncArgs.len < 6: return "[]"
      let table = evalExprOld(expr.irFuncArgs[0], row, ctx)
      let vecCol = evalExprOld(expr.irFuncArgs[1], row, ctx)
      let textCol = evalExprOld(expr.irFuncArgs[2], row, ctx)
      let queryText = evalExprOld(expr.irFuncArgs[3], row, ctx)
      let queryVec = evalExprOld(expr.irFuncArgs[4], row, ctx)
      let k = try: parseInt(evalExprOld(expr.irFuncArgs[5], row, ctx)) except ValueError: 10
      let results = doHybridSearch(ctx, table, vecCol, textCol, queryText, queryVec, k)
      var jsonArr = newJArray()
      for (id, score) in results:
        var obj = newJObject()
        obj["id"] = %id
        obj["score"] = %score
        jsonArr.add(obj)
      return $jsonArr
    of "hybrid_search_ids":
      if expr.irFuncArgs.len < 6: return ""
      let table = evalExprOld(expr.irFuncArgs[0], row, ctx)
      let vecCol = evalExprOld(expr.irFuncArgs[1], row, ctx)
      let textCol = evalExprOld(expr.irFuncArgs[2], row, ctx)
      let queryText = evalExprOld(expr.irFuncArgs[3], row, ctx)
      let queryVec = evalExprOld(expr.irFuncArgs[4], row, ctx)
      let k = try: parseInt(evalExprOld(expr.irFuncArgs[5], row, ctx)) except ValueError: 10
      let results = doHybridSearch(ctx, table, vecCol, textCol, queryText, queryVec, k)
      var ids: seq[string] = @[]
      for (id, score) in results:
        ids.add($id)
      return ids.join(",")
    of "hybrid_search_filtered":
      if expr.irFuncArgs.len < 8: return "[]"
      let table = evalExprOld(expr.irFuncArgs[0], row, ctx)
      let vecCol = evalExprOld(expr.irFuncArgs[1], row, ctx)
      let textCol = evalExprOld(expr.irFuncArgs[2], row, ctx)
      let queryText = evalExprOld(expr.irFuncArgs[3], row, ctx)
      let queryVec = evalExprOld(expr.irFuncArgs[4], row, ctx)
      let k = try: parseInt(evalExprOld(expr.irFuncArgs[5], row, ctx)) except ValueError: 10
      let filterCol = evalExprOld(expr.irFuncArgs[6], row, ctx)
      let filterVal = evalExprOld(expr.irFuncArgs[7], row, ctx)
      let results = doHybridSearchFiltered(ctx, table, vecCol, textCol, queryText, queryVec, k, filterCol, filterVal)
      var parts: seq[string] = @[]
      for (id, score) in results:
        let safeId = id.replace("\\", "\\\\").replace("\"", "\\\"")
        parts.add("{\"id\":\"" & safeId & "\",\"score\":\"" & $score & "\"}")
      return "[" & parts.join(",") & "]"
    of "rerank":
      if expr.irFuncArgs.len < 2: return "[]"
      let queryText = evalExprOld(expr.irFuncArgs[0], row, ctx)
      let resultsJson = evalExprOld(expr.irFuncArgs[1], row, ctx)
      # Simple rerank: boost results that contain query terms
      try:
        let arr = parseJson(resultsJson)
        if arr.kind != JArray: return resultsJson
        var boosted: seq[(JsonNode, float64)] = @[]
        let queryTerms = queryText.toLower().splitWhitespace()
        for elem in arr:
          var score = 0.0
          try: score = parseFloat(elem["score"].getStr()) except ValueError: discard
          # Simple term overlap boost
          for term in queryTerms:
            if term.len > 2:
              score += 0.01
          boosted.add((elem, score))
        boosted.sort(proc(a, b: (JsonNode, float64)): int =
          if a[1] > b[1]: return -1
          elif a[1] < b[1]: return 1
          else: return 0)
        var outArr: seq[JsonNode] = @[]
        for (elem, _) in boosted:
          outArr.add(elem)
        return $(%* outArr)
      except CatchableError:
        return resultsJson
    of "chunk":
      if expr.irFuncArgs.len < 1: return "[]"
      let text = evalExprOld(expr.irFuncArgs[0], row, ctx)
      let maxSize = if expr.irFuncArgs.len >= 2:
        try: parseInt(evalExprOld(expr.irFuncArgs[1], row, ctx)) except ValueError: 1024
      else: 1024
      let overlap = if expr.irFuncArgs.len >= 3:
        try: parseInt(evalExprOld(expr.irFuncArgs[2], row, ctx)) except ValueError: 128
      else: 128
      let cfg = chunkmod.ChunkConfig(maxChunkSize: maxSize, chunkOverlap: overlap,
                                     strategy: chunkmod.csRecursive, minChunkSize: 64)
      let chunks = chunkmod.chunk(text, cfg)
      var jsonChunks = newJArray()
      for i, c in chunks:
        jsonChunks.add(%*{"index": i, "text": c, "size": c.len})
      return $(jsonChunks)
    of "embed_text":
      if expr.irFuncArgs.len < 1: return "[]"
      let text = evalExprOld(expr.irFuncArgs[0], row, ctx)
      if ctx.embedder == nil or not ctx.embedder.config.enabled:
        return "[]"
      let vec = embedmod.embed(ctx.embedder, text)
      if vec.len == 0: return "[]"
      return embedmod.vectorToJson(vec)
    of "nl_to_sql":
      if expr.irFuncArgs.len < 1: return ""
      let question = evalExprOld(expr.irFuncArgs[0], row, ctx)
      let table = if expr.irFuncArgs.len >= 2: evalExprOld(expr.irFuncArgs[1], row, ctx) else: ""
      if ctx.llmClient == nil or not ctx.llmClient.config.enabled:
        return ""

      var schemaInfo = ""
      if table.len > 0 and table in ctx.tables:
        let tbl = ctx.tables[table]
        schemaInfo = "Table: " & table & "\nColumns:\n"
        for col in tbl.columns:
          var colInfo = "  - " & col.name & " " & col.colType
          if col.isPk: colInfo.add(" PRIMARY KEY")
          if col.isNotNull: colInfo.add(" NOT NULL")
          if col.fkTable.len > 0:
            colInfo.add(" REFERENCES " & col.fkTable & "(" & col.fkColumn & ")")
          schemaInfo.add(colInfo & "\n")
      elif table.len > 0:
        return "Table '" & table & "' not found"
      else:
        schemaInfo = "Available tables:\n"
        for tblName in ctx.tables.keys:
          schemaInfo.add("  - " & tblName & "\n")

      let systemPrompt = "You are a SQL expert. Given a schema and a natural language question, generate ONLY a valid SQL query for BaraDB. Return ONLY the SQL, no explanations. Use BaraQL syntax."
      let prompt = "Schema:\n" & schemaInfo & "\nQuestion: " & question & "\n\nSQL:"

      var llmResponse = llmmod.generate(ctx.llmClient, prompt, systemPrompt)
      var sql = llmmod.extractSQL(llmResponse)

      if sql.len == 0:
        return ""

      # Validate by parsing only (never execute LLM-generated SQL directly)
      let sqlLower = sql.toLower().strip()
      let isSafeQuery = sqlLower.startsWith("select") or sqlLower.startsWith("explain") or
                        sqlLower.startsWith("with")
      let allowDml = ctx.sessionVars.getOrDefault("nl_to_sql.allow_dml", "false") == "true"
      let isSuperuser = ctx.sessionVars.getOrDefault("is_superuser", "false") == "true"
      if not isSafeQuery and (not allowDml or not isSuperuser):
        # For non-SELECT: only do syntax validation via tokenize+parse, no execution
        let tokens = qlex.tokenize(sql)
        let astNode = qpar.parse(tokens)
        if astNode.stmts.len > 0:
          return sql
        else:
          let correctionPrompt = "Schema:\n" & schemaInfo & "\nQuestion: " & question & "\n\nPrevious SQL: " & sql & "\n\nError: Syntax error. Generate corrected SQL:"
          var correctedResponse = llmmod.generate(ctx.llmClient, correctionPrompt, systemPrompt)
          var correctedSql = llmmod.extractSQL(correctedResponse)
          if correctedSql.len > 0:
            return correctedSql
          return ""
      else:
        # For SELECT/EXPLAIN or when ALLOW_DML is set: validate with LIMIT 0 or EXPLAIN
        var validateSql = sql
        if sqlLower.startsWith("select"):
          validateSql = "SELECT * FROM (" & sql & ") LIMIT 0"
        elif sqlLower.startsWith("with"):
          validateSql = "WITH _cte_ AS (" & sql & ") SELECT 1 LIMIT 0"
        let tokens = qlex.tokenize(validateSql)
        let astNode = qpar.parse(tokens)
        if astNode.stmts.len > 0:
          let validateRes = requireExecuteQueryHook()(ctx, astNode, @[])
          if not validateRes.success:
            # Self-correction: send error back to LLM
            let correctionPrompt = "Schema:\n" & schemaInfo & "\nQuestion: " & question & "\n\nPrevious SQL: " & sql & "\n\nError: " & validateRes.message & "\n\nGenerate corrected SQL:"
            var correctedResponse = llmmod.generate(ctx.llmClient, correctionPrompt, systemPrompt)
            var correctedSql = llmmod.extractSQL(correctedResponse)
            if correctedSql.len > 0:
              return correctedSql
        return sql
    of "schema_prompt":
      if expr.irFuncArgs.len < 1: return ""
      let table = evalExprOld(expr.irFuncArgs[0], row, ctx)
      if table notin ctx.tables:
        return "Table '" & table & "' not found"

      let tbl = ctx.tables[table]
      var ddl = ""
      ddl.add("CREATE TABLE " & table & " (\n")
      for i, col in tbl.columns:
        ddl.add("  " & col.name & " " & col.colType)
        if col.isPk: ddl.add(" PRIMARY KEY")
        if col.isNotNull: ddl.add(" NOT NULL")
        if col.autoIncrement: ddl.add(" AUTO_INCREMENT")
        if col.fkTable.len > 0:
          ddl.add(" REFERENCES " & col.fkTable & "(" & col.fkColumn & ")")
        if i < tbl.columns.len - 1: ddl.add(",")
        ddl.add("\n")

      # Sample data
      let rows = requireExecScanHook()(ctx, table)
      let sampleLimit = min(5, rows.len)
      if sampleLimit > 0:
        ddl.add(");\n\n-- Sample data:\n")
        for i in 0..<sampleLimit:
          ddl.add("-- ")
          var parts: seq[string] = @[]
          for col in tbl.columns:
            parts.add(col.name & "=" & valueToString(rows[i].getOrDefault(col.name, Value(kind: vkNull))))
          ddl.add(parts.join(", "))
          ddl.add("\n")
      else:
        ddl.add(");")

      # Indexes
      var idxList: seq[string] = @[]
      for idxKey in ctx.btrees.keys:
        if idxKey.startsWith(table & "."):
          idxList.add(idxKey)
      for idxKey in ctx.vectorIndexes.keys:
        if idxKey.startsWith(table & "."):
          idxList.add("HNSW: " & idxKey)
      if idxList.len > 0:
        ddl.add("\n-- Indexes: " & idxList.join(", "))

      # RLS policies
      if table in ctx.policies and ctx.policies[table].len > 0:
        ddl.add("\n-- RLS Policies:\n")
        for pol in ctx.policies[table]:
          ddl.add("-- CREATE POLICY " & pol.name & " FOR " & pol.command & "\n")

      if tbl.foreignKeys.len > 0:
        ddl.add("\n-- Foreign Keys:\n")
        for fk in tbl.foreignKeys:
          ddl.add("-- " & fk.refTable & "(" & fk.refColumn & ") ON DELETE " & fk.onDelete & "\n")

      return ddl
    of "similarity_nodes":
      if expr.irFuncArgs.len < 1: return "[]"
      let graphName = evalExprOld(expr.irFuncArgs[0], row, ctx)
      let metric = if expr.irFuncArgs.len >= 2: evalExprOld(expr.irFuncArgs[1], row, ctx).toLower() else: "jaccard"
      if graphName notin ctx.graphs:
        return "[]"
      let g = ctx.graphs[graphName]
      let simMetric = if metric == "adamic_adar" or metric == "adamic-adar": gengine.smAdamicAdar else: gengine.smJaccard
      let pairs = gengine.similarityNodes(g, simMetric)
      var arr = newJArray()
      for (a, b, sim) in pairs:
        arr.add(%*{"node_a": uint64(a), "node_b": uint64(b), "similarity": sim})
      return $(arr)
    of "node2vec_embed":
      if expr.irFuncArgs.len < 1: return "[]"
      let graphName = evalExprOld(expr.irFuncArgs[0], row, ctx)
      let dims = if expr.irFuncArgs.len >= 2:
        try: parseInt(evalExprOld(expr.irFuncArgs[1], row, ctx)) except ValueError: 64
      else: 64
      if graphName notin ctx.graphs:
        return "[]"
      let g = ctx.graphs[graphName]
      let embeddings = gengine.node2vec(g, dims, 10, 5)
      var obj = newJObject()
      for nid, emb in embeddings:
        var vecStr = "["
        for i, v in emb:
          if i > 0: vecStr.add(",")
          vecStr.add($v)
        vecStr.add("]")
        obj[$(uint64(nid))] = %vecStr
      return $(obj)
    of "cypher":
      if expr.irFuncArgs.len < 1: return "[]"
      let cypherQuery = evalExprOld(expr.irFuncArgs[0], row, ctx)
      let sql = cyphermod.cypherToSql(cypherQuery)
      if sql.len == 0: return "[]"
      let tokens = qlex.tokenize(sql)
      let astNode = qpar.parse(tokens)
      if astNode.stmts.len == 0: return "[]"
      let res = requireExecuteQueryHook()(ctx, astNode, @[])
      if not res.success:
        return "Error: " & res.message
      var jsonRows = newJArray()
      for r in res.rows:
        var jsonRow = newJObject()
        for col in res.columns:
          jsonRow[col] = if col in r: %r[col] else: newJNull()
        jsonRows.add(jsonRow)
      return $(jsonRows)
    of "datetime":
      if expr.irFuncArgs.len > 0:
        let arg = evalExprOld(expr.irFuncArgs[0], row, ctx).toLower()
        if arg == "now":
          return $now().format("yyyy-MM-dd HH:mm:ss")
        return arg
      return $now().format("yyyy-MM-dd HH:mm:ss")
    of "now":
      return $now().format("yyyy-MM-dd HH:mm:ss")
    of "gen_random_uuid", "uuid":
      # Generate UUID v4
      var uuidStr = ""
      for i in 0..<36:
        if i in @[8, 13, 18, 23]:
          uuidStr.add('-')
        elif i == 14:
          uuidStr.add('4')
        elif i == 19:
          uuidStr.add(['8', '9', 'a', 'b'][rand(3)])
        else:
          uuidStr.add("0123456789abcdef"[rand(15)])
      return uuidStr
    of "nextval":
      if expr.irFuncArgs.len < 1:
        return "0"
      if ctx == nil: return "0"
      let seqName = evalExprOld(expr.irFuncArgs[0], row, ctx)
      var val: int64 = 0
      acquire(ctx.sharedLock.lock)
      try:
        if seqName in ctx.sequences:
          val = ctx.sequences[seqName]
        val += 1
        ctx.sequences[seqName] = val
      finally:
        release(ctx.sharedLock.lock)
      return $val
    of "currval":
      if expr.irFuncArgs.len < 1:
        return "0"
      if ctx == nil: return "0"
      let seqName = evalExprOld(expr.irFuncArgs[0], row, ctx)
      acquire(ctx.sharedLock.lock)
      try:
        if seqName in ctx.sequences:
          return $ctx.sequences[seqName]
      finally:
        release(ctx.sharedLock.lock)
      return "0"
    of "snowflake_id":
      # Snowflake ID: timestamp_ms(41 bits) | node_id(10 bits) | sequence(12 bits)
      var nodeId: int64 = 0
      if expr.irFuncArgs.len > 0:
        try: nodeId = parseInt(evalExprOld(expr.irFuncArgs[0], row, ctx))
        except ValueError: nodeId = 0
      nodeId = nodeId and 0x3FF  # 10 bits
      let ts = int64(epochTime() * 1000) and 0x1FFFFFFFFFF  # 41 bits
      var snowSeq = int64(getMonoTime().ticks() and 0xFFF)  # 12 bits from monotonic
      let snowflakeId = (ts shl 22) or (nodeId shl 12) or snowSeq
      return $snowflakeId
    of "strftime":
      if expr.irFuncArgs.len >= 2:
        let fmt = evalExprOld(expr.irFuncArgs[0], row, ctx)
        let val = evalExprOld(expr.irFuncArgs[1], row, ctx)
        if fmt == "%s":
          try:
            let dt = parse(val, "yyyy-MM-dd HH:mm:ss")
            return $(dt.toTime().toUnix())
          except CatchableError:
            return "0"
        elif fmt == "%Y-%m-%dT%H:%M:%SZ":
          try:
            let dt = parse(val, "yyyy-MM-dd HH:mm:ss")
            return format(dt, "yyyy-MM-dd'T'HH:mm:ss'Z'")
          except CatchableError:
            return ""
      return ""
    else:
      # Unknown function: try to evaluate args and return first arg as fallback
      if expr.irFuncArgs.len > 0:
        return evalExprOld(expr.irFuncArgs[0], row, ctx)
      return ""
  of irekCast:
    let val = evalExprOld(expr.irCastExpr, row, ctx)
    let castType = expr.irCastType.name.toLower()
    if castType.startsWith("vector"):
      let vec = parseVectorString(val)
      return "[" & vec.mapIt($it).join(", ") & "]"
    return val
  of irekExists:
    if ctx != nil:
      let rows = requireExecutePlanHook()(ctx, expr.existsSubquery)
      return if rows.len > 0: "true" else: "false"
    return "false"
  of irekAggregate:
    # Look up pre-computed aggregate from group row
    let prefix = "$agg_" & $expr.aggOp & "_"
    for k, v in row:
      if k.startsWith(prefix):
        return v
    return ""
  of irekSubquery:
    # Execute subquery and return scalar value (first column of first row)
    if ctx != nil and expr.subqueryPlan != nil:
      let savedOuter = ctx.outerRow
      let savedPlan = ctx.subqueryPlan
      ctx.outerRow = row
      ctx.subqueryPlan = expr.subqueryPlan
      let subRows = requireExecutePlanHook()(ctx, expr.subqueryPlan)
      ctx.outerRow = savedOuter
      ctx.subqueryPlan = savedPlan
      if subRows.len > 0:
        for k, v in subRows[0]:
          if not k.startsWith("$"):
            return valueToString(v)
    return ""
  else: return ""
