## BaraQL Executor — AST lowering, IR compilation, and execution
##
## Shared types/helpers live under `exec/` (re-exported below for API stability).
## See `exec/README.md` for module map and further extraction plan.
import std/os
import std/strutils
import std/tables
import std/hashes
import std/sequtils
import std/algorithm
import std/re
import checksums/sha2
import std/math
import std/times
import std/json
import std/random
import std/monotimes
import std/locks
import lexer as qlex
import parser as qpar
import ast
import ir
import ../core/types
import ../protocol/wire
import ../storage/lsm
import ../storage/btree
import ../storage/wal
import ../core/mvcc
import ../core/tracing
import ../client/fileops
import ../fts/engine as fts
import ../core/registry

import ../vector/engine as vengine
import ../graph/engine as gengine
import ../graph/community as gcomm
import ../ai/chunk as chunkmod
import ../ai/llm as llmmod
import ../graph/cypher as cyphermod

import exec/types
import exec/values
import exec/schema
import exec/context
import exec/helpers
import exec/params
import exec/migrations  # internal — not re-exported
import exec/eval
import exec/lower
import exec/scan  # internal — not re-exported
import exec/dml
export types
export values
export schema
export context
export helpers
export params
export eval
export lower
export dml

proc executePlan*(ctx: ExecutionContext, plan: IRPlan): seq[Row]

# ----------------------------------------------------------------------
# Forward declarations
# ----------------------------------------------------------------------

proc executeQuery*(ctx: ExecutionContext, astNode: Node, params: seq[WireValue] = @[]): ExecResult


# ----------------------------------------------------------------------
# Foreign Key Enforcement
# ----------------------------------------------------------------------

proc findReferencingRows(ctx: ExecutionContext, childTable: string, fkCol: string, fkValue: string): seq[Row] =
  result = @[]
  for row in execScan(ctx, childTable):
    if fkCol in row and valueToString(row[fkCol]) == fkValue:
      result.add(row)

proc enforceFkOnDelete(ctx: ExecutionContext, parentTable: string, parentCol: string, parentVal: string): (bool, string) =
  for childTblName, childTbl in ctx.tables:
    for col in childTbl.columns:
      if col.fkTable == parentTable and col.fkColumn == parentCol:
        let action = if col.fkOnDelete.len > 0: col.fkOnDelete else: "RESTRICT"
        let refs = findReferencingRows(ctx, childTblName, col.name, parentVal)
        if refs.len > 0:
          case action
          of "CASCADE":
            for refRow in refs:
              if "$key" in refRow:
                var dummy: seq[(string, seq[byte])] = @[]
                discard execDelete(ctx, childTblName, valueToString(refRow["$key"]), dummy)
          of "SET NULL":
            for refRow in refs:
              if "$key" in refRow:
                var sets = initTable[string, string]()
                sets[col.name] = "\\N"
                var dummy: seq[(string, seq[byte])] = @[]
                discard execUpdateRow(ctx, childTblName, valueToString(refRow["$key"]), sets, dummy)
          of "RESTRICT", "NO ACTION":
            return (false, "FOREIGN KEY violation: row is referenced by " & childTblName & "." & col.name)
  return (true, "")

proc enforceFkOnUpdate(ctx: ExecutionContext, parentTable: string, parentCol: string, oldVal: string, newVal: string): (bool, string) =
  for childTblName, childTbl in ctx.tables:
    for col in childTbl.columns:
      if col.fkTable == parentTable and col.fkColumn == parentCol:
        let action = if col.fkOnUpdate.len > 0: col.fkOnUpdate else: "RESTRICT"
        let refs = findReferencingRows(ctx, childTblName, col.name, oldVal)
        if refs.len > 0:
          case action
          of "CASCADE":
            for refRow in refs:
              if "$key" in refRow:
                var sets = initTable[string, string]()
                sets[col.name] = newVal
                var dummy: seq[(string, seq[byte])] = @[]
                discard execUpdateRow(ctx, childTblName, valueToString(refRow["$key"]), sets, dummy)
          of "SET NULL":
            for refRow in refs:
              if "$key" in refRow:
                var sets = initTable[string, string]()
                sets[col.name] = "\\N"
                var dummy: seq[(string, seq[byte])] = @[]
                discard execUpdateRow(ctx, childTblName, valueToString(refRow["$key"]), sets, dummy)
          of "RESTRICT", "NO ACTION":
            return (false, "FOREIGN KEY violation: row is referenced by " & childTblName & "." & col.name)
  return (true, "")

proc enforceFkOnChildUpdate(ctx: ExecutionContext, childTable: string, fkCol: string, newVal: string): (bool, string) =
  let tbl = ctx.getTableDef(childTable)
  var parentTable = ""
  var parentCol = ""
  for col in tbl.columns:
    if col.name == fkCol:
      parentTable = col.fkTable
      parentCol = col.fkColumn
      break
  if parentTable.len == 0 or parentCol.len == 0:
    return (true, "")
  if isNull(newVal):
    return (true, "")
  let fkKey = parentTable & "." & parentCol & "=" & newVal
  let (fkExists, _) = ctx.db.get(fkKey)
  if fkExists:
    return (true, "")
  var found = false
  let prefix = parentTable & "."
  for entry in ctx.db.scanMemTable():
    if entry.deleted: continue
    if entry.key.startsWith(prefix):
      let rest = entry.key[prefix.len..^1]
      if rest.startsWith(parentCol & "=") and rest[parentCol.len+1..^1] == newVal:
        found = true
        break
  if not found:
    return (false, "FOREIGN KEY violation: '" & newVal & "' not found in " & parentTable & "." & parentCol)
  return (true, "")

# ----------------------------------------------------------------------
# Constraint Validation
# ----------------------------------------------------------------------

proc validateType*(colType: string, value: string): (bool, string) =
  if isNull(value): return (true, "")
  let t = colType.toUpper()
  if t == "INTEGER" or t == "INT" or t == "BIGINT" or t == "SMALLINT" or t == "SERIAL":
    try: discard parseInt(value)
    except CatchableError: return (false, "Type mismatch: expected " & t & " but got '" & value & "'")
  elif t == "FLOAT" or t == "REAL" or t == "DOUBLE" or t == "DOUBLE PRECISION" or t == "NUMERIC":
    try: discard parseFloat(value)
    except CatchableError: return (false, "Type mismatch: expected " & t & " but got '" & value & "'")
  elif t == "BOOLEAN" or t == "BOOL":
    let lv = value.toLower()
    if lv notin ["true", "false", "1", "0", "t", "f", "yes", "no"]:
      return (false, "Type mismatch: expected BOOLEAN but got '" & value & "'")
  elif t == "TIMESTAMP" or t == "DATE":
    if value.len < 8:  # minimal date check
      return (false, "Type mismatch: expected " & t & " but got '" & value & "'")
  elif t == "JSON" or t == "JSONB":
    try:
      discard parseJson(value)
    except CatchableError:
      return (false, "Type mismatch: expected JSON but got '" & value & "'")
  elif t.startsWith("VECTOR"):
    let vec = parseVectorString(value)
    if vec.len == 0 and value.strip().len > 0:
      return (false, "Type mismatch: expected VECTOR but got '" & value & "'")
    var expectedDim = 0
    let dimStart = t.find('(')
    let dimEnd = t.find(')')
    if dimStart >= 0 and dimEnd > dimStart:
      try:
        expectedDim = parseInt(t[dimStart+1..<dimEnd])
      except CatchableError:
        expectedDim = 0
    if expectedDim > 0 and vec.len != expectedDim:
      return (false, "Vector dimension mismatch: expected " & $expectedDim & " but got " & $vec.len)
  return (true, "")

proc executeQueryImpl(ctx: ExecutionContext, astNode: Node, params: seq[WireValue] = @[]): ExecResult
proc executeMigrationSql(ctx: ExecutionContext, sql: string): ExecResult

proc fireTriggers*(ctx: ExecutionContext, tableName: string, timing: string, event: string, row: Row) =
  let tbl = ctx.getTableDef(tableName)
  for trig in tbl.triggers:
    if trig.timing == timing and trig.event == event:
      if trig.action != nil:
        let tokens = qlex.tokenize(trig.action.strVal)
        let astNode = qpar.parse(tokens)
        if astNode.stmts.len > 0:
          discard executeQueryImpl(ctx, astNode)

proc validateConstraints*(ctx: ExecutionContext, tableName: string,
    fields: seq[string], values: seq[seq[string]], skipPkCheck: bool = false): (bool, string) =
  let tbl = ctx.getTableDef(tableName)

  for rowIdx, rowVals in values:
    for col in tbl.columns:
      let val = getValue(rowVals, fields, col.name)

      # NOT NULL check
      if col.isNotNull and isNull(val):
        return (false, "NOT NULL constraint violated for column '" & col.name & "'")

      # Type enforcement
      if col.colType.len > 0 and not isNull(val):
        let (typeOk, typeErr) = validateType(col.colType, val)
        if not typeOk:
          return (false, typeErr)

      # FK check — uses LSM get which searches memtable + SSTables
      if col.fkTable.len > 0 and col.fkColumn.len > 0 and not isNull(val):
        let fkKey = col.fkTable & "." & col.fkColumn & "=" & val
        let (fkExists, _) = ctx.db.get(fkKey)
        if not fkExists:
          return (false, "FOREIGN KEY violation: '" & val & "' not found in " & col.fkTable & "." & col.fkColumn)

    # PK uniqueness (skip during UPDATE — PK shouldn't change)
    if not skipPkCheck and tbl.pkColumns.len > 0:
      var pkVals: seq[string] = @[]
      var pkParts: seq[string] = @[]
      for pkCol in tbl.pkColumns:
        let pkVal = getValue(rowVals, fields, pkCol)
        pkVals.add(pkVal)
        pkParts.add(pkCol & "=" & escapeRowVal(pkVal))
      let pkStr = pkVals.join("|")
      # Check with composite PK format (as stored by execInsert)
      let pkKey = tableName & "." & pkParts.join(":")
      let (exists, _) = ctx.db.get(pkKey)
      if exists:
        return (false, "UNIQUE constraint violated: duplicate key '" & pkStr & "'")

    # UNIQUE constraint via B-Tree
    for col in tbl.columns:
      if col.isUnique:
        let uVal = getValue(rowVals, fields, col.name)
        if not isNull(uVal):
          let idxName = tableName & "." & col.name
          if idxName in ctx.btrees and ctx.btrees[idxName].contains(uVal):
            return (false, "UNIQUE constraint violated: duplicate '" & uVal & "' for column '" & col.name & "'")

    # CHECK constraints
    for check in tbl.checks:
      if check.checkNode != nil:
        var row = initTable[string, Value]()
        for i, f in fields:
          if i < rowVals.len:
            row[f] = rowVals[i]
          else:
            row[f] = Value(kind: vkNull)
        let checkExpr = lowerExpr(check.checkNode)
        let checkResult = evalExpr(checkExpr, row, ctx)
        if valueToString(checkResult) != "true":
          return (false, "CHECK constraint '" & check.name & "' violated")

  return (true, "")

proc applyDefaultValues*(tbl: TableDef, fields: var seq[string], values: var seq[seq[string]]) =
  for col in tbl.columns:
    if col.defaultVal.len == 0: continue
    var hasField = false
    for f in fields:
      if f.toLower() == col.name.toLower():
        hasField = true
        break
    if not hasField:
      fields.add(col.name)
      for rowIdx in 0..<values.len:
        values[rowIdx].add(col.defaultVal)
    else:
      for rowIdx in 0..<values.len:
        for i, f in fields:
          if f.toLower() == col.name.toLower() and i < values[rowIdx].len:
            if isNull(values[rowIdx][i]):
              values[rowIdx][i] = col.defaultVal
            break

# ----------------------------------------------------------------------
# Window Function Computation
# ----------------------------------------------------------------------

proc partitionKey(row: Row, partExprs: seq[IRExpr], ctx: ExecutionContext = nil): string =
  ## Compute a string partition key for a row
  result = ""
  for expr in partExprs:
    result &= valueToString(evalExpr(expr, row, ctx)) & "|"

proc compareRowsByOrder(a, b: Row, orderExprs: seq[IRExpr], orderDirs: seq[bool], ctx: ExecutionContext = nil): int =
  ## Compare two rows by their ORDER BY expressions
  for i, expr in orderExprs:
    let va = evalExpr(expr, a, ctx)
    let vb = evalExpr(expr, b, ctx)
    var cmpRes = 0
    try:
      let fa = parseFloat(valueToString(va))
      let fb = parseFloat(valueToString(vb))
      if fa < fb: cmpRes = -1
      elif fa > fb: cmpRes = 1
    except CatchableError:
      cmpRes = cmp(valueToString(va), valueToString(vb))
    if cmpRes != 0:
      return if orderDirs.len > i and orderDirs[i]: -cmpRes else: cmpRes
  return 0

proc resolveFrameBounds(pos, partLen: int, frameStart, frameEnd: string): (int, int) =
  ## Resolve frame boundaries for ROWS mode.
  ## Returns (startPos, endPos) inclusive within the partition.
  var startPos = 0
  var endPos = partLen - 1

  # Parse start boundary
  if frameStart == "UNBOUNDED PRECEDING":
    startPos = 0
  elif frameStart == "CURRENT ROW":
    startPos = pos
  elif frameStart.endsWith(" PRECEDING"):
    let nStr = frameStart[0..^11]
    var n = 0
    try: n = parseInt(nStr) except CatchableError: n = 0
    startPos = max(0, pos - n)
  elif frameStart.endsWith(" FOLLOWING"):
    let nStr = frameStart[0..^11]
    var n = 0
    try: n = parseInt(nStr) except CatchableError: n = 0
    startPos = min(partLen - 1, pos + n)

  # Parse end boundary
  if frameEnd == "UNBOUNDED FOLLOWING":
    endPos = partLen - 1
  elif frameEnd == "CURRENT ROW":
    endPos = pos
  elif frameEnd.endsWith(" PRECEDING"):
    let nStr = frameEnd[0..^11]
    var n = 0
    try: n = parseInt(nStr) except CatchableError: n = 0
    endPos = max(0, pos - n)
  elif frameEnd.endsWith(" FOLLOWING"):
    let nStr = frameEnd[0..^11]
    var n = 0
    try: n = parseInt(nStr) except CatchableError: n = 0
    endPos = min(partLen - 1, pos + n)

  if startPos > endPos:
    startPos = endPos
  return (startPos, endPos)

proc computeWindowValues*(rows: seq[Row], expr: IRExpr, ctx: ExecutionContext = nil): seq[string] =
  ## Compute a window function for all rows, returning a value per row.
  ## The expr must be of kind irekWindowFunc.
  result = newSeq[string](rows.len)
  if rows.len == 0: return

  let wfName = expr.wfName.toLower()
  let frameStart = expr.wfFrameStart
  let frameEnd = expr.wfFrameEnd

  # Partition rows
  var groups = initTable[string, seq[int]]()
  for i, row in rows:
    let pk = partitionKey(row, expr.wfPartition, ctx)
    if pk notin groups:
      groups[pk] = @[]
    groups[pk].add(i)

  # For each partition, sort by ORDER BY
  for pk, idxs in groups:
    var sortedIdxs = idxs
    sortedIdxs.sort(proc(a, b: int): int =
      compareRowsByOrder(rows[a], rows[b], expr.wfOrderBy, expr.wfOrderDirs, ctx)
    )

    case wfName
    of "row_number":
      for pos, rowIdx in sortedIdxs:
        result[rowIdx] = $(pos + 1)
    of "rank":
      var currentRank = 1
      for pos, rowIdx in sortedIdxs:
        if pos > 0:
          let cmpRes = compareRowsByOrder(rows[sortedIdxs[pos - 1]], rows[rowIdx], expr.wfOrderBy, expr.wfOrderDirs, ctx)
          if cmpRes != 0:
            currentRank = pos + 1
        result[rowIdx] = $currentRank
    of "dense_rank":
      var currentRank = 1
      for pos, rowIdx in sortedIdxs:
        if pos > 0:
          let cmpRes = compareRowsByOrder(rows[sortedIdxs[pos - 1]], rows[rowIdx], expr.wfOrderBy, expr.wfOrderDirs, ctx)
          if cmpRes != 0:
            currentRank += 1
        result[rowIdx] = $currentRank
    of "ntile":
      var n = 1
      if expr.wfArgs.len > 0:
        try: n = parseInt(valueToString(evalExpr(expr.wfArgs[0], rows[sortedIdxs[0]], ctx))) except CatchableError: n = 1
      if n < 1: n = 1
      let groupSize = sortedIdxs.len div n
      let remainder = sortedIdxs.len mod n
      for pos, rowIdx in sortedIdxs:
        var bucket = 1
        var threshold = groupSize
        if 0 < remainder: threshold += 1
        var cumulative = threshold
        while pos >= cumulative and bucket < n:
          bucket += 1
          threshold = groupSize
          if (bucket - 1) < remainder: threshold += 1
          cumulative += threshold
        result[rowIdx] = $bucket
    of "lead":
      var offset = 1
      var defaultVal = ""
      if expr.wfArgs.len > 1:
        try: offset = parseInt(valueToString(evalExpr(expr.wfArgs[1], rows[sortedIdxs[0]], ctx))) except CatchableError: offset = 1
      if expr.wfArgs.len > 2:
        defaultVal = valueToString(evalExpr(expr.wfArgs[2], rows[sortedIdxs[0]], ctx))
      for pos, rowIdx in sortedIdxs:
        let targetPos = pos + offset
        if targetPos < sortedIdxs.len:
          result[rowIdx] = valueToString(evalExpr(expr.wfArgs[0], rows[sortedIdxs[targetPos]], ctx))
        else:
          result[rowIdx] = defaultVal
    of "lag":
      var offset = 1
      var defaultVal = ""
      if expr.wfArgs.len > 1:
        try: offset = parseInt(valueToString(evalExpr(expr.wfArgs[1], rows[sortedIdxs[0]], ctx))) except CatchableError: offset = 1
      if expr.wfArgs.len > 2:
        defaultVal = valueToString(evalExpr(expr.wfArgs[2], rows[sortedIdxs[0]], ctx))
      for pos, rowIdx in sortedIdxs:
        let targetPos = pos - offset
        if targetPos >= 0:
          result[rowIdx] = valueToString(evalExpr(expr.wfArgs[0], rows[sortedIdxs[targetPos]], ctx))
        else:
          result[rowIdx] = defaultVal
    of "first_value":
      for pos, rowIdx in sortedIdxs:
        let (fStart, _) = resolveFrameBounds(pos, sortedIdxs.len, frameStart, frameEnd)
        result[rowIdx] = valueToString(evalExpr(expr.wfArgs[0], rows[sortedIdxs[fStart]], ctx))
    of "last_value":
      for pos, rowIdx in sortedIdxs:
        let (_, fEnd) = resolveFrameBounds(pos, sortedIdxs.len, frameStart, frameEnd)
        result[rowIdx] = valueToString(evalExpr(expr.wfArgs[0], rows[sortedIdxs[fEnd]], ctx))
    else:
      # Unknown window function — fill with null
      for rowIdx in sortedIdxs:
        result[rowIdx] = "\\N"

# ----------------------------------------------------------------------
# IR Plan Execution (with actual filter/sort/projection)
# ----------------------------------------------------------------------

proc expandStarRow(row: Row): Row =
  result = initTable[string, Value]()
  var seenCols = initTable[string, bool]()
  var qualifiedCount = initTable[string, int]()
  for k, v in row:
    if not k.startsWith("$") and k.contains("."):
      let parts = k.split(".")
      if parts.len == 2:
        qualifiedCount[parts[1]] = qualifiedCount.getOrDefault(parts[1], 0) + 1
  for k, v in row:
    if not k.startsWith("$") and not k.contains("."):
      result[k] = v
      seenCols[k] = true
  for k, v in row:
    if not k.startsWith("$") and k.contains("."):
      let parts = k.split(".")
      if parts.len == 2 and parts[1] in seenCols and qualifiedCount.getOrDefault(parts[1], 0) > 1:
        result[k] = v

proc executePlan*(ctx: ExecutionContext, plan: IRPlan): seq[Row] =
  if plan == nil: return @[]

  case plan.kind
  of irpkScan:
    return execScan(ctx, plan.scanTable)

  of irpkFilter:
    let sourceRows = executePlan(ctx, plan.filterSource)
    if plan.filterCond == nil: return sourceRows
    result = @[]
    for row in sourceRows:
      let evalResult = evalExpr(plan.filterCond, row, ctx)
      if valueToString(evalResult) == "true":
        result.add(row)

  of irpkProject:
    var sourceRows = executePlan(ctx, plan.projectSource)
    if plan.projectAliases.len == 0: return sourceRows
    # Scalar SELECT (no FROM): create a dummy row so expressions can be evaluated
    if sourceRows.len == 0 and plan.projectSource != nil and
       plan.projectSource.kind == irpkScan and plan.projectSource.scanTable.len == 0:
      sourceRows = @[initTable[string, Value]()]

    # Check if this projection contains aggregates without GROUP BY
    var hasAggs = false
    let sourceIsGroupBy = plan.projectSource != nil and plan.projectSource.kind == irpkGroupBy
    for expr in plan.projectExprs:
      if expr != nil and expr.kind == irekAggregate:
        # If source is GroupBy, aggregates are pre-computed in group rows
        if not sourceIsGroupBy:
          hasAggs = true
        break

    # Check if projection contains window functions
    var hasWindowFuncs = false
    for expr in plan.projectExprs:
      if expr != nil and expr.kind == irekWindowFunc:
        hasWindowFuncs = true
        break

    if hasWindowFuncs:
      # Pre-compute window function values for all source rows
      var winValues = newSeq[seq[string]](plan.projectExprs.len)
      for i, expr in plan.projectExprs:
        if expr != nil and expr.kind == irekWindowFunc:
          winValues[i] = computeWindowValues(sourceRows, expr)
      result = @[]
      for rowIdx, row in sourceRows:
        var newRow: Row
        for i, alias in plan.projectAliases:
          if i < plan.projectExprs.len:
            let expr = plan.projectExprs[i]
            if expr.kind == irekWindowFunc:
              newRow[alias] = winValues[i][rowIdx]
            elif expr.kind == irekStar:
              newRow = expandStarRow(row)
            else:
              let val = evalExpr(expr, row, ctx)
              if alias.len > 0: newRow[alias] = val
              else: newRow["col" & $i] = val
        if newRow.len > 0:
          result.add(newRow)
        else:
          result.add(row)
      return result

    if hasAggs:
      # Produce exactly one row with aggregate values
      var newRow: Row
      for i, alias in plan.projectAliases:
        if i < plan.projectExprs.len:
          let expr = plan.projectExprs[i]
          if expr.kind == irekStar:
            if sourceRows.len > 0:
              newRow = expandStarRow(sourceRows[0])
          elif expr.kind == irekAggregate:
            # Apply FILTER (WHERE ...) if present
            var filteredRows = sourceRows
            if expr.aggFilter != nil:
              filteredRows = @[]
              for row in sourceRows:
                if valueToString(evalExpr(expr.aggFilter, row, ctx)) == "true":
                  filteredRows.add(row)
            case expr.aggOp
            of irCount:
              if expr.aggArgs.len == 0:
                newRow[alias] = $filteredRows.len
              else:
                var count = 0
                for row in filteredRows:
                  let v = evalExpr(expr.aggArgs[0], row, ctx)
                  if v.kind != vkNull: count += 1
                newRow[alias] = $count
            of irSum:
              var sum = 0.0
              for row in filteredRows:
                let v = evalExpr(expr.aggArgs[0], row, ctx)
                try: sum += parseFloat(valueToString(v)) except CatchableError: discard
              newRow[alias] = $sum
            of irAvg:
              var sum = 0.0
              var count = 0
              for row in filteredRows:
                let v = evalExpr(expr.aggArgs[0], row, ctx)
                try: sum += parseFloat(valueToString(v)); count += 1 except CatchableError: discard
              newRow[alias] = if count > 0: $(sum / float(count)) else: "0"
            of irMin:
              var minVal = ""
              for row in filteredRows:
                let v = evalExpr(expr.aggArgs[0], row, ctx)
                if v.kind == vkNull: continue
                if minVal == "" or cmpMin(valueToString(v), minVal): minVal = valueToString(v)
              newRow[alias] = minVal
            of irMax:
              var maxVal = ""
              for row in filteredRows:
                let v = evalExpr(expr.aggArgs[0], row, ctx)
                if v.kind == vkNull: continue
                if maxVal == "" or cmpMax(valueToString(v), maxVal): maxVal = valueToString(v)
              newRow[alias] = maxVal
            of irArrayAgg:
              var arr: seq[string]
              for row in filteredRows:
                if expr.aggArgs.len > 0:
                  arr.add(valueToString(evalExpr(expr.aggArgs[0], row, ctx)))
              newRow[alias] = "[" & arr.join(", ") & "]"
            of irStringAgg:
              var parts: seq[string]
              let delim = if expr.aggArgs.len > 1: evalExpr(expr.aggArgs[1], initTable[string, Value](), ctx) else: Value(kind: vkString, strVal: ",")
              for row in filteredRows:
                if expr.aggArgs.len > 0:
                  parts.add(valueToString(evalExpr(expr.aggArgs[0], row, ctx)))
              newRow[alias] = parts.join(valueToString(delim))
          else:
            let val = evalExpr(expr, if sourceRows.len > 0: sourceRows[0] else: initTable[string, Value](), ctx)
            if alias.len > 0: newRow[alias] = val
            else: newRow["col" & $i] = val
      result = @[newRow]
      return result

    result = @[]
    for row in sourceRows:
      var newRow: Row
      for i, alias in plan.projectAliases:
        if i < plan.projectExprs.len:
          let expr = plan.projectExprs[i]
          if expr.kind == irekStar:
            newRow = expandStarRow(row)
          elif expr.kind == irekAggregate and sourceIsGroupBy:
            # Look up pre-computed aggregate from GroupBy row
            let aggKey = "$agg_" & $expr.aggOp
            var found = false
            for k, v in row:
              if k.startsWith(aggKey):
                if alias.len > 0: newRow[alias] = v
                else: newRow["col" & $i] = v
                found = true
                break
            if not found:
              if alias.len > 0: newRow[alias] = "0"
              else: newRow["col" & $i] = "0"
          else:
            let val = evalExpr(expr, row, ctx)
            if alias.len > 0: newRow[alias] = val
            else: newRow["col" & $i] = val
      if newRow.len > 0:
        result.add(newRow)
      else:
        result.add(row)

  of irpkSort:
    var sourceRows = executePlan(ctx, plan.sortSource)
    if plan.sortExprs.len == 0: return sourceRows
    proc sortCmp(a, b: Row): int =
      for i, sortExpr in plan.sortExprs:
        let ascending = if i < plan.sortDirs.len: plan.sortDirs[i] else: true
        let va = evalExpr(sortExpr, a, ctx)
        let vb = evalExpr(sortExpr, b, ctx)
        var cmpRes = 0
        try:
          let fa = parseFloat(valueToString(va))
          let fb = parseFloat(valueToString(vb))
          if fa < fb: cmpRes = -1
          elif fa > fb: cmpRes = 1
        except CatchableError:
          cmpRes = cmp(valueToString(va), valueToString(vb))
        if not ascending: cmpRes = -cmpRes
        if cmpRes != 0: return cmpRes
      return 0
    sourceRows.sort(sortCmp, Ascending)
    return sourceRows

  of irpkLimit:
    let sourceRows = executePlan(ctx, plan.limitSource)
    var start = int(plan.limitOffset)
    if start > sourceRows.len: start = sourceRows.len
    if plan.limitCount == 0:
      return @[]
    var endIdx = start + int(plan.limitCount)
    if endIdx > sourceRows.len:
      endIdx = sourceRows.len
    return sourceRows[start..<endIdx]

  of irpkGroupBy:
    let sourceRows = executePlan(ctx, plan.groupSource)
    if plan.groupKeys.len == 0 and plan.groupingSetsKind == irgskNone: return sourceRows

    # Generate grouping sets
    var groupingSets: seq[seq[IRExpr]]
    case plan.groupingSetsKind
    of irgskNone:
      groupingSets = @[plan.groupKeys]
    of irgskGroupingSets:
      groupingSets = plan.groupingSets
    of irgskRollup:
      # ROLLUP(a, b) => GROUPING SETS ((a, b), (a), ())
      groupingSets = @[]
      for i in countdown(plan.groupKeys.len, 0):
        groupingSets.add(plan.groupKeys[0..<i])
    of irgskCube:
      # CUBE(a, b) => GROUPING SETS ((a, b), (a), (b), ())
      groupingSets = @[@[]]  # start with empty set
      for key in plan.groupKeys:
        var newSets: seq[seq[IRExpr]]
        for s in groupingSets:
          newSets.add(s)
          var s2 = s
          s2.add(key)
          newSets.add(s2)
        groupingSets = newSets

    result = @[]
    for gkeys in groupingSets:
      # Group rows by this set's key values
      var groups = initTable[string, seq[Row]]()
      for row in sourceRows:
        var groupKey = ""
        for gk in gkeys:
          groupKey &= valueToString(evalExpr(gk, row, ctx)) & "|"
        if groupKey notin groups:
          groups[groupKey] = @[]
        groups[groupKey].add(row)
      for gk, groupRows in groups:
        var aggRow: Row
        # Populate GROUP BY key columns
        for gkExpr in gkeys:
          if gkExpr.kind == irekField and gkExpr.fieldPath.len > 0:
            aggRow[gkExpr.fieldPath[^1]] = evalExpr(gkExpr, groupRows[0], ctx)
        # Populate non-aggregated columns from first row in group
        if groupRows.len > 0:
          for k, v in groupRows[0]:
            if not k.startsWith("$") and k notin aggRow:
              aggRow[k] = v
        # Compute each aggregate expression
        for aggExpr in plan.groupAggs:
          let aggKey = "$agg_" & $aggExpr.aggOp & "_" & $plan.groupAggs.find(aggExpr)
          var filteredRows = groupRows
          if aggExpr.aggFilter != nil:
            filteredRows = @[]
            for row in groupRows:
              if valueToString(evalExpr(aggExpr.aggFilter, row, ctx)) == "true":
                filteredRows.add(row)
          case aggExpr.aggOp
          of irCount:
            if aggExpr.aggArgs.len == 0:
              aggRow[aggKey] = $filteredRows.len
            else:
              var count = 0
              for row in filteredRows:
                let v = evalExpr(aggExpr.aggArgs[0], row, ctx)
                if v.kind != vkNull: count += 1
              aggRow[aggKey] = $count
          of irSum:
            var sum = 0.0
            for row in filteredRows:
              let v = evalExpr(aggExpr.aggArgs[0], row, ctx)
              try: sum += parseFloat(valueToString(v)) except CatchableError: discard
            aggRow[aggKey] = $sum
          of irAvg:
            var sum = 0.0
            var count = 0
            for row in filteredRows:
              let v = evalExpr(aggExpr.aggArgs[0], row, ctx)
              try: sum += parseFloat(valueToString(v)); count += 1 except CatchableError: discard
            aggRow[aggKey] = if count > 0: $(sum / float(count)) else: "0"
          of irMin:
            var minVal = ""
            for row in filteredRows:
              let v = evalExpr(aggExpr.aggArgs[0], row, ctx)
              if v.kind == vkNull: continue
              if minVal == "" or cmpMin(valueToString(v), minVal): minVal = valueToString(v)
            aggRow[aggKey] = minVal
          of irMax:
            var maxVal = ""
            for row in filteredRows:
              let v = evalExpr(aggExpr.aggArgs[0], row, ctx)
              if v.kind == vkNull: continue
              if maxVal == "" or cmpMax(valueToString(v), maxVal): maxVal = valueToString(v)
            aggRow[aggKey] = maxVal
          of irArrayAgg:
            var arr: seq[string]
            for row in filteredRows:
              if aggExpr.aggArgs.len > 0:
                arr.add(valueToString(evalExpr(aggExpr.aggArgs[0], row, ctx)))
            aggRow[aggKey] = "[" & arr.join(", ") & "]"
          of irStringAgg:
            var parts: seq[string]
            let delim = if aggExpr.aggArgs.len > 1: evalExpr(aggExpr.aggArgs[1], initTable[string, Value](), ctx) else: Value(kind: vkString, strVal: ",")
            for row in filteredRows:
              if aggExpr.aggArgs.len > 0:
                parts.add(valueToString(evalExpr(aggExpr.aggArgs[0], row, ctx)))
            aggRow[aggKey] = parts.join(valueToString(delim))
        # Apply HAVING filter
        if plan.groupHaving != nil:
          if valueToString(evalExpr(plan.groupHaving, aggRow, ctx)) != "true":
            continue
        result.add(aggRow)
    return result

  of irpkJoin:
    let leftRows = executePlan(ctx, plan.joinLeft)
    result = @[]

    proc getScanTable(p: IRPlan): string =
      if p == nil: return ""
      case p.kind
      of irpkScan: p.scanTable
      of irpkJoin: getScanTable(p.joinRight)
      else: ""

    proc getLeftmostScanTable(p: IRPlan): string =
      if p == nil: return ""
      case p.kind
      of irpkScan: p.scanTable
      of irpkJoin: getLeftmostScanTable(p.joinLeft)
      else: ""

    proc mergeRow(left, right: Row, leftAlias, rightAlias, leftTable, rightTable: string): Row =
      result = initTable[string, Value]()
      for k, v in left:
        if not k.startsWith("$"):
          result[k] = v
      for k, v in right:
        if not k.startsWith("$") and k notin result:
          result[k] = v
      let lq = if leftAlias.len > 0: leftAlias elif leftTable.len > 0: leftTable else: ""
      if lq.len > 0:
        for k, v in left:
          if not k.startsWith("$"):
            result[lq & "." & k] = v
      let rq = if rightAlias.len > 0: rightAlias elif rightTable.len > 0: rightTable else: ""
      if rq.len > 0:
        for k, v in right:
          if not k.startsWith("$"):
            result[rq & "." & k] = v

    let leftAlias = if plan.joinLeft != nil and plan.joinLeft.kind == irpkScan:
                      plan.joinLeft.scanAlias else: ""
    let leftTable = getLeftmostScanTable(plan.joinLeft)

    # LATERAL JOIN: for each left row, scan right, merge, then filter/sort/limit
    if plan.joinLateral:
      let rightAlias = plan.joinAlias
      # Walk down right plan to extract filter, sort, limit
      var rightFilter: IRExpr = nil
      var rightSortExprs: seq[IRExpr]
      var rightSortDirs: seq[bool]
      var rightLimit: int = -1
      var rightScanPlan: IRPlan = plan.joinRight
      while rightScanPlan != nil:
        case rightScanPlan.kind
        of irpkScan: break
        of irpkFilter:
          if rightFilter == nil:
            rightFilter = rightScanPlan.filterCond
          else:
            rightFilter = IRExpr(kind: irekBinary, binOp: irAnd,
                                 binLeft: rightFilter, binRight: rightScanPlan.filterCond)
          rightScanPlan = rightScanPlan.filterSource
        of irpkSort:
          rightSortExprs = rightScanPlan.sortExprs
          rightSortDirs = rightScanPlan.sortDirs
          rightScanPlan = rightScanPlan.sortSource
        of irpkLimit:
          rightLimit = rightScanPlan.limitCount
          rightScanPlan = rightScanPlan.limitSource
        of irpkProject:
          rightScanPlan = rightScanPlan.projectSource
        of irpkGroupBy:
          rightScanPlan = rightScanPlan.groupSource
        else: break

      for l in leftRows:
        var rawRightRows: seq[Row]
        if rightScanPlan != nil and rightScanPlan.kind == irpkScan:
          rawRightRows = execScan(ctx, rightScanPlan.scanTable)
        else:
          rawRightRows = @[]

        # Merge, filter
        var mergedRows: seq[Row]
        for r in rawRightRows:
          let merged = mergeRow(l, r, leftAlias, rightAlias, leftTable, getScanTable(plan.joinRight))
          if rightFilter != nil and valueToString(evalExpr(rightFilter, merged, ctx)) != "true":
            continue
          if plan.joinCond != nil and valueToString(evalExpr(plan.joinCond, merged, ctx)) != "true":
            continue
          mergedRows.add(merged)

        # Apply sort from subquery
        if rightSortExprs.len > 0 and mergedRows.len > 1:
          mergedRows.sort(proc(a, b: Row): int =
            for i, sExpr in rightSortExprs:
              let aVal = evalExpr(sExpr, a, ctx)
              let bVal = evalExpr(sExpr, b, ctx)
              let asc = if i < rightSortDirs.len: rightSortDirs[i] else: true
              var cmp = 0
              let aNum = parseFloat(valueToString(aVal))
              let bNum = parseFloat(valueToString(bVal))
              if aNum < bNum: cmp = -1
              elif aNum > bNum: cmp = 1
              if cmp != 0:
                return if asc: cmp else: -cmp
            return 0
          )

        # Apply limit from subquery
        let limitRows = if rightLimit >= 0 and rightLimit < mergedRows.len:
                          mergedRows[0 ..< rightLimit]
                        else:
                          mergedRows

        if limitRows.len > 0:
          for row in limitRows:
            result.add(row)
        elif plan.joinKind == irjkLeft or plan.joinKind == irjkFull:
          var rightCols: seq[string]
          # Build rightCols from filtered rows if available, otherwise from raw rows
          let sourceForCols = if mergedRows.len > 0: mergedRows else: rawRightRows
          for r in sourceForCols:
            for k, _ in r:
              if not k.startsWith("$") and k notin rightCols:
                rightCols.add(k)
          # If still no right rows, get column names from table definition
          if rightCols.len == 0 and rightScanPlan != nil and rightScanPlan.kind == irpkScan:
            let rightTable = rightScanPlan.scanTable
            if rightTable.len > 0:
              let tbl = ctx.getTableDef(rightTable)
              for col in tbl.columns:
                rightCols.add(col.name)
          var padded = initTable[string, Value]()
          for k, v in l:
            if not k.startsWith("$"):
              padded[k] = v
          for col in rightCols:
            if col notin padded: padded[col] = Value(kind: vkNull)
          if leftAlias.len > 0:
            for k, v in l:
              if not k.startsWith("$"):
                padded[leftAlias & "." & k] = v
          if rightAlias.len > 0:
            for col in rightCols:
              padded[rightAlias & "." & col] = Value(kind: vkNull)
          result.add(padded)
      return result

    # Non-LATERAL: choose join strategy
    chooseJoinStrategy(ctx, plan)
    # Hash join and index nested loop are only safe for INNER JOIN
    # (padding logic for outer joins is complex)
    if plan.joinKind != irjkInner and plan.joinStrategy in {irjsHash, irjsIndexNestedLoop}:
      plan.joinStrategy = irjsNestedLoop
    let rightRows = executePlan(ctx, plan.joinRight)

    # Collect all unique column names from each side (excluding internal $ keys)
    var leftCols, rightCols: seq[string]
    for l in leftRows:
      for k, _ in l:
        if not k.startsWith("$") and k notin leftCols:
          leftCols.add(k)
    for r in rightRows:
      for k, _ in r:
        if not k.startsWith("$") and k notin rightCols:
          rightCols.add(k)

    let rightAlias = if plan.joinRight != nil and plan.joinRight.kind == irpkScan:
                       plan.joinRight.scanAlias else: ""
    let rightTable = getScanTable(plan.joinRight)

    if plan.joinKind == irjkCross:
      for l in leftRows:
        for r in rightRows:
          result.add(mergeRow(l, r, leftAlias, rightAlias, leftTable, rightTable))
      return result

    case plan.joinStrategy
    of irjsHash:
      # Hash Join: build hash table on the smaller side
      let (leftCol, rightCol) = extractJoinEquality(plan.joinCond)
      var buildRows, probeRows: seq[Row]
      var buildCol, probeCol: string
      var buildAlias, probeAlias: string
      var buildIsLeft: bool

      if leftRows.len <= rightRows.len:
        buildRows = leftRows
        buildCol = leftCol
        buildAlias = leftAlias
        probeRows = rightRows
        probeCol = rightCol
        probeAlias = rightAlias
        buildIsLeft = true
      else:
        buildRows = rightRows
        buildCol = rightCol
        buildAlias = rightAlias
        probeRows = leftRows
        probeCol = leftCol
        probeAlias = leftAlias
        buildIsLeft = false

      var hashTable = initTable[string, seq[Row]]()
      for row in buildRows:
        let key = if buildAlias.len > 0 and buildCol in row: valueToString(row[buildCol])
                  elif buildCol in row: valueToString(row[buildCol])
                  else: ""
        if key.len > 0 :
          if key notin hashTable: hashTable[key] = @[]
          hashTable[key].add(row)

      var matchedProbe = initTable[int, bool]()
      for i, prow in probeRows:
        let key = if probeAlias.len > 0 and probeCol in prow: valueToString(prow[probeCol])
                  elif probeCol in prow: valueToString(prow[probeCol])
                  else: ""
        if key in hashTable:
          matchedProbe[i] = true
          for brow in hashTable[key]:
            if buildIsLeft:
              result.add(mergeRow(brow, prow, leftAlias, rightAlias, leftTable, rightTable))
            else:
              result.add(mergeRow(prow, brow, leftAlias, rightAlias, leftTable, rightTable))

      # LEFT / RIGHT / FULL padding for non-matching probe rows
      if plan.joinKind == irjkLeft or plan.joinKind == irjkFull or plan.joinKind == irjkRight:
        for i, prow in probeRows:
          if not matchedProbe.getOrDefault(i, false):
            var padded = initTable[string, Value]()
            for k, v in prow:
              if not k.startsWith("$"):
                padded[k] = v
            if buildIsLeft:
              # probe is right side
              for col in leftCols:
                if col notin padded: padded[col] = Value(kind: vkNull)
              if probeAlias.len > 0:
                for k, v in prow:
                  if not k.startsWith("$"):
                    padded[probeAlias & "." & k] = v
              if leftAlias.len > 0:
                for col in leftCols:
                  padded[leftAlias & "." & col] = Value(kind: vkNull)
            else:
              # probe is left side
              for col in rightCols:
                if col notin padded: padded[col] = Value(kind: vkNull)
              if probeAlias.len > 0:
                for k, v in prow:
                  if not k.startsWith("$"):
                    padded[probeAlias & "." & k] = v
              if rightAlias.len > 0:
                for col in rightCols:
                  padded[rightAlias & "." & col] = Value(kind: vkNull)
            result.add(padded)

      # RIGHT / FULL padding for non-matching build rows
      if plan.joinKind == irjkRight or plan.joinKind == irjkFull:
        for i, brow in buildRows:
          var found = false
          for j, prow in probeRows:
            let pkey = if probeAlias.len > 0 and probeCol in prow: valueToString(prow[probeCol])
                       elif probeCol in prow: valueToString(prow[probeCol])
                       else: ""
            let bkey = if buildAlias.len > 0 and buildCol in brow: valueToString(brow[buildCol])
                       elif buildCol in brow: valueToString(brow[buildCol])
                       else: ""
            if pkey == bkey and bkey.len > 0:
              found = true
              break
          if not found:
            var padded = initTable[string, Value]()
            for k, v in brow:
              if not k.startsWith("$"):
                padded[k] = v
            if buildIsLeft:
              for col in rightCols:
                if col notin padded: padded[col] = Value(kind: vkNull)
              if leftAlias.len > 0:
                for k, v in brow:
                  if not k.startsWith("$"):
                    padded[leftAlias & "." & k] = v
              if rightAlias.len > 0:
                for col in rightCols:
                  padded[rightAlias & "." & col] = Value(kind: vkNull)
            else:
              for col in leftCols:
                if col notin padded: padded[col] = Value(kind: vkNull)
              if rightAlias.len > 0:
                for k, v in brow:
                  if not k.startsWith("$"):
                    padded[rightAlias & "." & k] = v
              if leftAlias.len > 0:
                for col in leftCols:
                  padded[leftAlias & "." & col] = Value(kind: vkNull)
            result.add(padded)

    of irjsIndexNestedLoop:
      let (leftCol, rightCol) = extractJoinEquality(plan.joinCond)
      var outerRows: seq[Row]
      var outerAlias, innerAlias: string
      var outerCol, innerCol: string
      var idxName: string
      var outerIsLeft: bool

      if plan.joinHashCol == rightCol:
        outerRows = leftRows
        outerAlias = leftAlias
        innerAlias = rightAlias
        outerCol = leftCol
        innerCol = rightCol
        idxName = (if plan.joinRight != nil and plan.joinRight.kind == irpkScan: plan.joinRight.scanTable else: "") & "." & rightCol
        outerIsLeft = true
      else:
        outerRows = rightRows
        outerAlias = rightAlias
        innerAlias = leftAlias
        outerCol = rightCol
        innerCol = leftCol
        idxName = (if plan.joinLeft != nil and plan.joinLeft.kind == irpkScan: plan.joinLeft.scanTable else: "") & "." & leftCol
        outerIsLeft = false

      if idxName notin ctx.btrees:
        # Fallback to nested loop if index disappeared
        plan.joinStrategy = irjsNestedLoop
        # Fall through to nested loop below
      else:
        let btree = ctx.btrees[idxName]
        var matchedOuter = initTable[int, bool]()
        for i, orow in outerRows:
          let key = if orow.hasKey(outerCol): valueToString(orow[outerCol]) else: ""
          if key.len > 0 :
            let entries = btree.get(key)
            if entries.len > 0:
              matchedOuter[i] = true
            for entry in entries:
              let parsed = parseRowDataToValueRow(entry.rowValue)
              if outerIsLeft:
                result.add(mergeRow(orow, parsed, leftAlias, rightAlias, leftTable, rightTable))
              else:
                result.add(mergeRow(parsed, orow, leftAlias, rightAlias, leftTable, rightTable))
          elif plan.joinKind == irjkLeft or plan.joinKind == irjkRight or plan.joinKind == irjkFull:
            matchedOuter[i] = false

        # Padding for non-matching outer rows
        if plan.joinKind == irjkLeft or plan.joinKind == irjkRight or plan.joinKind == irjkFull:
          for i, orow in outerRows:
            if not matchedOuter.getOrDefault(i, false):
              var padded = initTable[string, Value]()
              for k, v in orow:
                if not k.startsWith("$"):
                  padded[k] = v
              if outerIsLeft:
                for col in rightCols:
                  if col notin padded: padded[col] = Value(kind: vkNull)
                if leftAlias.len > 0:
                  for k, v in orow:
                    if not k.startsWith("$"):
                      padded[leftAlias & "." & k] = v
                if rightAlias.len > 0:
                  for col in rightCols:
                    padded[rightAlias & "." & col] = Value(kind: vkNull)
              else:
                for col in leftCols:
                  if col notin padded: padded[col] = Value(kind: vkNull)
                if rightAlias.len > 0:
                  for k, v in orow:
                    if not k.startsWith("$"):
                      padded[rightAlias & "." & k] = v
                if leftAlias.len > 0:
                  for col in leftCols:
                    padded[leftAlias & "." & col] = Value(kind: vkNull)
              result.add(padded)
        return result

    of irjsNestedLoop:
      for l in leftRows:
        var matched = false
        for r in rightRows:
          let merged = mergeRow(l, r, leftAlias, rightAlias, leftTable, rightTable)
          if plan.joinCond == nil or valueToString(evalExpr(plan.joinCond, merged, ctx)) == "true":
            result.add(merged)
            matched = true
        if not matched and (plan.joinKind == irjkLeft or plan.joinKind == irjkFull):
          var padded = initTable[string, Value]()
          for k, v in l:
            if not k.startsWith("$"):
              padded[k] = v
          for col in rightCols:
            if col notin padded: padded[col] = Value(kind: vkNull)
          if leftAlias.len > 0:
            for k, v in l:
              if not k.startsWith("$"):
                padded[leftAlias & "." & k] = v
          if rightAlias.len > 0:
            for col in rightCols:
              padded[rightAlias & "." & col] = Value(kind: vkNull)
          result.add(padded)

      if plan.joinKind == irjkRight or plan.joinKind == irjkFull:
        for r in rightRows:
          var found = false
          for l in leftRows:
            let merged = mergeRow(l, r, leftAlias, rightAlias, leftTable, rightTable)
            if plan.joinCond == nil or valueToString(evalExpr(plan.joinCond, merged, ctx)) == "true":
              found = true
              break
          if not found:
            var padded = initTable[string, Value]()
            for k, v in r:
              if not k.startsWith("$"):
                padded[k] = v
            for col in leftCols:
              if col notin padded: padded[col] = Value(kind: vkNull)
            if rightAlias.len > 0:
              for k, v in r:
                if not k.startsWith("$"):
                  padded[rightAlias & "." & k] = v
            if leftAlias.len > 0:
              for col in leftCols:
                padded[leftAlias & "." & col] = Value(kind: vkNull)
            result.add(padded)

    return result

  of irpkPivot:
    let sourceRows = executePlan(ctx, plan.pivotSource)
    result = @[]
    # Determine which columns are "group by" (all except pivot column and aggregate target)
    var groupCols: seq[string]
    if sourceRows.len > 0:
      for k, _ in sourceRows[0]:
        if not k.startsWith("$") and k != plan.pivotForCol:
          # Check if this column is the aggregate value column
          let isAggTarget = plan.pivotAgg.kind == irekAggregate and
                           plan.pivotAgg.aggArgs.len > 0 and
                           plan.pivotAgg.aggArgs[0].kind == irekField and
                           plan.pivotAgg.aggArgs[0].fieldPath.len > 0 and
                           plan.pivotAgg.aggArgs[0].fieldPath[^1] == k
          if not isAggTarget:
            groupCols.add(k)
    # Group rows by group columns
    var groups = initTable[string, seq[Row]]()
    for row in sourceRows:
      var groupKey = ""
      for col in groupCols:
        groupKey &= (if col in row: valueToString(row[col]) else: "") & "|"
      if groupKey notin groups:
        groups[groupKey] = @[]
      groups[groupKey].add(row)
    # For each group, create a pivoted row
    for gk, groupRows in groups:
      var newRow: Row
      for col in groupCols:
        if col in groupRows[0]:
          newRow[col] = groupRows[0][col]
      # For each pivot value, compute the aggregate
      for pivotVal in plan.pivotInValues:
        var matchingRows: seq[Row]
        for row in groupRows:
          if plan.pivotForCol in row and valueToString(row[plan.pivotForCol]) == pivotVal:
            matchingRows.add(row)
        # Compute aggregate
        var aggResult = ""
        if plan.pivotAgg.kind == irekAggregate:
          case plan.pivotAgg.aggOp
          of irCount:
            if plan.pivotAgg.aggArgs.len == 0:
              aggResult = $matchingRows.len
            else:
              var count = 0
              for row in matchingRows:
                let v = evalExpr(plan.pivotAgg.aggArgs[0], row, ctx)
                if v.kind != vkNull: count += 1
              aggResult = $count
          of irSum:
            var sum = 0.0
            for row in matchingRows:
              let v = evalExpr(plan.pivotAgg.aggArgs[0], row, ctx)
              try: sum += parseFloat(valueToString(v)) except CatchableError: discard
            aggResult = $sum
          of irAvg:
            var sum = 0.0
            var count = 0
            for row in matchingRows:
              let v = evalExpr(plan.pivotAgg.aggArgs[0], row, ctx)
              try: sum += parseFloat(valueToString(v)); count += 1 except CatchableError: discard
            aggResult = if count > 0: $(sum / float(count)) else: "0"
          of irMin:
            var minVal = ""
            for row in matchingRows:
              let v = evalExpr(plan.pivotAgg.aggArgs[0], row, ctx)
              if v.kind == vkNull: continue
              if minVal == "" or cmpMin(valueToString(v), minVal): minVal = valueToString(v)
            aggResult = minVal
          of irMax:
            var maxVal = ""
            for row in matchingRows:
              let v = evalExpr(plan.pivotAgg.aggArgs[0], row, ctx)
              if v.kind == vkNull: continue
              if maxVal == "" or cmpMax(valueToString(v), maxVal): maxVal = valueToString(v)
            aggResult = maxVal
          else: discard
        # Clean pivot value (remove quotes)
        let cleanVal = pivotVal.strip(chars = {'\''})
        newRow[cleanVal] = aggResult
      result.add(newRow)
    return result

  of irpkUnpivot:
    let sourceRows = executePlan(ctx, plan.unpivotSource)
    result = @[]
    # Determine which columns are "identity" (all except the IN columns)
    var identityCols: seq[string]
    if sourceRows.len > 0:
      for k, _ in sourceRows[0]:
        if not k.startsWith("$") and k notin plan.unpivotInCols:
          identityCols.add(k)
    # For each source row, create one row per IN column
    for row in sourceRows:
      for inCol in plan.unpivotInCols:
        var newRow: Row
        for col in identityCols:
          if col in row:
            newRow[col] = row[col]
        newRow[plan.unpivotForCol] = inCol
        newRow[plan.unpivotValueCol] = (if inCol in row: row[inCol] else: Value(kind: vkNull))
        result.add(newRow)
    return result

  of irpkGraphTraversal:
    # Execute real graph traversal using the graph engine
    result = @[]
    let graphName = plan.graphName
    if graphName notin ctx.graphs:
      return @[]

    let g = ctx.graphs[graphName]
    if g == nil or g.nodes.len == 0:
      return @[]

    let algo = plan.graphAlgo.toLowerAscii()
    let returnCols = plan.graphReturnCols
    let firstNodeId = if g.nodes.len > 0: g.nodes.keys.toSeq[0] else: gengine.NodeId(0)
    let explicitStart = try: parseUInt(plan.graphStartNode) except CatchableError: 0'u64
    let explicitEnd = try: parseUInt(plan.graphEndNode) except CatchableError: 0'u64

    case algo
    of "bfs":
      let startId = if explicitStart > 0: gengine.NodeId(explicitStart) else: firstNodeId
      let maxDepth = if plan.graphMaxDepth >= 0: plan.graphMaxDepth else: -1
      let traverseResult = gengine.bfs(g, startId, maxDepth)
      for nodeId in traverseResult:
        var row = initTable[string, Value]()
        let nid = uint64(nodeId)
        row["_node_id"] = $nid
        if nodeId in g.nodes:
          let gn = g.nodes[nodeId]
          row["_node_label"] = gn.label
          for col in returnCols:
            if col == "label":
              row[col] = gn.label
            elif col == "id":
              row[col] = $nid
            elif col in gn.properties:
              row[col] = gn.properties[col]
        result.add(row)

    of "dfs":
      let startId = if explicitStart > 0: gengine.NodeId(explicitStart) else: firstNodeId
      let maxDepth = if plan.graphMaxDepth >= 0: plan.graphMaxDepth else: -1
      let traverseResult = gengine.dfs(g, startId, maxDepth)
      for nodeId in traverseResult:
        var row = initTable[string, Value]()
        let nid = uint64(nodeId)
        row["_node_id"] = $nid
        if nodeId in g.nodes:
          let gn = g.nodes[nodeId]
          row["_node_label"] = gn.label
          for col in returnCols:
            if col == "label":
              row[col] = gn.label
            elif col == "id":
              row[col] = $nid
            elif col in gn.properties:
              row[col] = gn.properties[col]
        result.add(row)

    of "pagerank", "page_rank":
      let prResult = gengine.pageRank(g, 20, 0.85)
      var sortedNodes = prResult.keys.toSeq
      sortedNodes.sort(proc(a, b: gengine.NodeId): int =
        let va = prResult.getOrDefault(a, 0.0)
        let vb = prResult.getOrDefault(b, 0.0)
        if va > vb: return -1 elif va < vb: return 1 else: return 0)
      for nodeId in sortedNodes:
        var row = initTable[string, Value]()
        let nid = uint64(nodeId)
        row["_node_id"] = $nid
        row["rank"] = $prResult.getOrDefault(nodeId, 0.0)
        if nodeId in g.nodes:
          row["_node_label"] = g.nodes[nodeId].label
          for col in returnCols:
            if col == "rank": row["rank"] = $prResult.getOrDefault(nodeId, 0.0)
            elif col == "id": row[col] = $nid
            elif col == "label": row[col] = g.nodes[nodeId].label
            elif col in g.nodes[nodeId].properties: row[col] = g.nodes[nodeId].properties[col]
        result.add(row)

    of "shortest_path", "shortestpath":
      if explicitStart > 0 and explicitEnd > 0:
        let startId = gengine.NodeId(explicitStart)
        let endId = gengine.NodeId(explicitEnd)
        let path = gengine.shortestPath(g, startId, endId)
        for nodeId in path:
          var row = initTable[string, Value]()
          let nid = uint64(nodeId)
          row["_node_id"] = $nid
          if nodeId in g.nodes:
            row["_node_label"] = g.nodes[nodeId].label
            for col in returnCols:
              if col == "id": row[col] = $nid
              elif col == "label": row[col] = g.nodes[nodeId].label
              elif col in g.nodes[nodeId].properties: row[col] = g.nodes[nodeId].properties[col]
          result.add(row)
      else:
        return @[]

    of "dijkstra":
      if explicitStart > 0:
        let startId = gengine.NodeId(explicitStart)
        let dists = gengine.dijkstra(g, startId)
        for nodeId, dist in dists:
          var row = initTable[string, Value]()
          row["_node_id"] = $(uint64(nodeId))
          row["distance"] = $dist
          if nodeId in g.nodes:
            row["_node_label"] = g.nodes[nodeId].label
          result.add(row)
      else:
        return @[]

    of "community", "community_detect", "louvain":
      let louvainResult = gcomm.louvain(g)
      for nodeId, communityId in louvainResult.communities:
        var row = initTable[string, Value]()
        row["_node_id"] = $(uint64(nodeId))
        row["community"] = $communityId
        if nodeId in g.nodes:
          row["_node_label"] = g.nodes[nodeId].label
        result.add(row)

    else:
      for nodeId in g.nodes.keys:
        var row = initTable[string, Value]()
        let nid = uint64(nodeId)
        row["_node_id"] = $nid
        row["_node_label"] = g.nodes[nodeId].label
        for col in returnCols:
          if col == "id": row[col] = $nid
          elif col == "label": row[col] = g.nodes[nodeId].label
          elif col in g.nodes[nodeId].properties: row[col] = g.nodes[nodeId].properties[col]
        result.add(row)

  else:
    return @[]

# ----------------------------------------------------------------------
# High-level execute
# ----------------------------------------------------------------------

proc executeQueryImpl(ctx: ExecutionContext, astNode: Node, params: seq[WireValue] = @[]): ExecResult =
  if astNode == nil or astNode.stmts.len == 0:
    return okResult()

  var boundAst = astNode
  if params.len > 0:
    boundAst = bindParams(astNode, params)

  let stmt = boundAst.stmts[0]
  let spanName = case stmt.kind
    of nkSelect: "SELECT"
    of nkInsert: "INSERT"
    of nkUpdate: "UPDATE"
    of nkDelete: "DELETE"
    of nkMerge: "MERGE"
    else: $stmt.kind
  let span = defaultTracer.beginSpan(spanName)
  defer: defaultTracer.endSpan(span)

  case stmt.kind
  of nkSelect:
    defer:
      ctx.cteTables.clear()
    # Execute CTEs if present
    if stmt.selWith.len > 0:
      for (cteName, cteQuery, isRecursive) in stmt.selWith:
        if isRecursive:
          # Recursive CTE: must be UNION ALL with anchor + recursive member
          if cteQuery.kind == nkSetOp and cteQuery.setOpKind == sdkUnion:
            var allRows: seq[Row] = @[]

            # Step 1: Execute the non-recursive anchor (left side of UNION)
            var innerLeft = Node(kind: nkStatementList, stmts: @[])
            innerLeft.stmts.add(cteQuery.setOpLeft)
            let anchorRes = executeQueryImpl(ctx, innerLeft)
            for row in anchorRes.rows:
              allRows.add(row)

            var workTable = anchorRes.rows
            const maxIterations = 1000
            var iteration = 0

            # Step 2: Iteratively execute the recursive member
            while workTable.len > 0 and iteration < maxIterations:
              # Save CTE state; recursive member's executeQuery will clear it via defer
              let savedCte = ctx.cteTables
              ctx.cteTables = {cteName: workTable}.toTable()

              var innerRight = Node(kind: nkStatementList, stmts: @[])
              innerRight.stmts.add(cteQuery.setOpRight)
              let rightRes = executeQueryImpl(ctx, innerRight)

              ctx.cteTables = savedCte

              var newRows: seq[Row] = @[]
              if not cteQuery.setOpAll:
                # UNION: deduplicate against all already-accumulated rows
                var seen = initTable[string, bool]()
                for existing in allRows:
                  let key = if "$value" in existing: valueToString(existing["$value"]) else: $existing
                  if key.len > 0:
                    seen[key] = true
                for row in rightRes.rows:
                  let key = if "$value" in row: valueToString(row["$value"]) else: $row
                  if not seen.getOrDefault(key, false):
                    if key.len > 0:
                      seen[key] = true
                    newRows.add(row)
              else:
                newRows = rightRes.rows

              if newRows.len == 0:
                break

              for row in newRows:
                allRows.add(row)
              workTable = newRows
              iteration += 1

            ctx.cteTables[cteName] = allRows
          else:
            # Recursive CTE without UNION — treat as non-recursive fallback
            var inner = Node(kind: nkStatementList, stmts: @[])
            inner.stmts.add(cteQuery)
            let cteRes = executeQueryImpl(ctx, inner)
            var cteRows: seq[Row] = @[]
            for row in cteRes.rows:
              cteRows.add(row)
            ctx.cteTables[cteName] = cteRows
        else:
          var inner = Node(kind: nkStatementList, stmts: @[])
          inner.stmts.add(cteQuery)
          let savedCte = ctx.cteTables
          let cteRes = executeQueryImpl(ctx, inner)
          ctx.cteTables = savedCte
          var cteRows: seq[Row] = @[]
          for row in cteRes.rows:
            cteRows.add(row)
          ctx.cteTables[cteName] = cteRows

    # Expand view if FROM table is a view
    if stmt.selFrom != nil and stmt.selFrom.kind == nkFrom and stmt.selFrom.fromTable in ctx.views:
      let viewQuery = ctx.views[stmt.selFrom.fromTable]
      if viewQuery != nil and viewQuery.kind == nkSelect:
        # Execute the view's underlying query
        var inner = Node(kind: nkStatementList, stmts: @[])
        inner.stmts.add(viewQuery)
        let innerResult = executeQueryImpl(ctx, inner)
        # Now filter and project with outer query constraints
        var filteredRows = innerResult.rows
        var cols = innerResult.columns
        if stmt.selWhere != nil and stmt.selWhere.whereExpr != nil:
          let whereIr = lowerExpr(stmt.selWhere.whereExpr)
          var tmp: seq[Row] = @[]
          for row in filteredRows:
            if valueToString(evalExpr(whereIr, row, ctx)) == "true":
              tmp.add(row)
          filteredRows = tmp
        if stmt.selOrderBy.len > 0:
          let sortExpr = lowerExpr(stmt.selOrderBy[0].orderByExpr)
          let asc = stmt.selOrderBy[0].orderByDir == sdAsc
          proc sortCmp(a, b: Row): int =
            let va = evalExpr(sortExpr, a, ctx)
            let vb = evalExpr(sortExpr, b, ctx)
            try:
              let fa = parseFloat(valueToString(va))
              let fb = parseFloat(valueToString(vb))
              if fa < fb: return -1
              if fa > fb: return 1
              return 0
            except CatchableError:
              return cmp(valueToString(va), valueToString(vb))
          filteredRows.sort(sortCmp, if asc: Ascending else: Descending)
        if stmt.selLimit != nil:
          let limitVal = if stmt.selLimit.limitExpr.kind == nkIntLit:
            int(stmt.selLimit.limitExpr.intVal) else: 0
          if limitVal > 0 and limitVal < filteredRows.len:
            filteredRows = filteredRows[0..<limitVal]
        return okResult(filteredRows, cols)
      else:
        return errResult("Invalid view definition")

    # Try B-Tree index point read first
    if stmt.selFrom != nil and stmt.selFrom.kind == nkFrom and stmt.selFrom.fromTable.len > 0:
      if stmt.selWhere != nil and stmt.selWhere.whereExpr != nil:
        let w = stmt.selWhere.whereExpr
        # Multi-column exact match: AND chain of =
        var eqConds: seq[(string, string)] = @[]
        var rangeCond: tuple[col: string, op: BinOpKind, val: string] = ("", bkEq, "")
        proc collectEq(node: Node) =
          if node.kind == nkBinOp and node.binOp == bkEq and node.binLeft.kind == nkIdent and node.binRight.kind == nkStringLit:
            eqConds.add((node.binLeft.identName, node.binRight.strVal))
          elif node.kind == nkBinOp and node.binOp == bkAnd:
            collectEq(node.binLeft)
            collectEq(node.binRight)
          elif node.kind == nkBinOp and node.binOp in {bkGt, bkGtEq, bkLt, bkLtEq} and
               node.binLeft.kind == nkIdent and node.binRight.kind == nkStringLit:
            rangeCond = (node.binLeft.identName, node.binOp, node.binRight.strVal)
        collectEq(w)
        # Multi-column exact match
        if eqConds.len >= 2:
          var idxCols: seq[string] = @[]
          for c in eqConds: idxCols.add(c[0])
          let idxName = stmt.selFrom.fromTable & "." & idxCols.join(".")
          if idxName in ctx.btrees:
            var idxVals: seq[string] = @[]
            for c in eqConds: idxVals.add(c[1])
            let idxVal = idxVals.join("|")
            let entries = ctx.btrees[idxName].get(idxVal)
            if entries.len > 0:
              var rows: seq[Row] = @[]
              for entry in entries:
                let (found, val) = ctx.db.get(entry.lsmKey)
                if found:
                  rows.add(parseRowDataToValueRow(cast[string](val)))
              let tbl = ctx.getTableDef(stmt.selFrom.fromTable)
              var cols: seq[string] = @[]
              for c in tbl.columns: cols.add(c.name)
              if cols.len == 0: cols = @["key", "value"]
              return okResult(rows, cols)
        # Multi-column range scan: exact match on prefix + range on last column
        if eqConds.len >= 1 and rangeCond.col.len > 0:
          var idxCols: seq[string] = @[]
          for c in eqConds: idxCols.add(c[0])
          idxCols.add(rangeCond.col)
          let idxName = stmt.selFrom.fromTable & "." & idxCols.join(".")
          if idxName in ctx.btrees:
            var prefix: string = ""
            for c in eqConds:
              if prefix.len > 0: prefix.add("|")
              prefix.add(c[1])
            if prefix.len > 0: prefix.add("|")
            var startKey, endKey: string
            case rangeCond.op
            of bkGt:
              startKey = prefix & rangeCond.val & "\x01"  # just above the value
              endKey = prefix & "\xFF"
            of bkGtEq:
              startKey = prefix & rangeCond.val
              endKey = prefix & "\xFF"
            of bkLt:
              startKey = prefix
              endKey = prefix & rangeCond.val
            of bkLtEq:
              startKey = prefix
              endKey = prefix & rangeCond.val & "\x01"
            else:
              startKey = prefix; endKey = prefix
            let scanned = ctx.btrees[idxName].scan(startKey, endKey)
            var rows: seq[Row] = @[]
            for (k, entries) in scanned:
              for entry in entries:
                let (found, val) = ctx.db.get(entry.lsmKey)
                if found:
                  rows.add(parseRowDataToValueRow(cast[string](val)))
            let tbl = ctx.getTableDef(stmt.selFrom.fromTable)
            var cols: seq[string] = @[]
            for c in tbl.columns: cols.add(c.name)
            if cols.len == 0: cols = @["key", "value"]
            return okResult(rows, cols)
        if w.kind == nkBinOp and w.binOp == bkEq:
          if w.binLeft.kind == nkIdent and w.binRight.kind == nkStringLit:
            let colName = w.binLeft.identName
            let idxName = stmt.selFrom.fromTable & "." & colName
            if idxName in ctx.btrees:
              let entries = ctx.btrees[idxName].get(w.binRight.strVal)
              if entries.len > 0:
                # Check for covering index: SELECT list matches index column
                var isCovered = true
                var coveredCols: seq[string] = @[]
                for e in stmt.selResult:
                  if e.kind == nkIdent:
                    coveredCols.add(e.identName)
                    if e.identName != colName:
                      isCovered = false
                  elif e.kind != nkStar:
                    isCovered = false
                if isCovered and coveredCols.len > 0:
                  var rows: seq[Row] = @[]
                  for entry in entries:
                    var row = initTable[string, Value]()
                    row[colName] = w.binRight.strVal
                    rows.add(row)
                  return okResult(rows, coveredCols)
                # Fetch actual row data from LSM
                let rows = execPointRead(ctx, stmt.selFrom.fromTable, colName & "=" & w.binRight.strVal)
                let tbl = ctx.getTableDef(stmt.selFrom.fromTable)
                var cols: seq[string] = @[]
                for c in tbl.columns: cols.add(c.name)
                if cols.len == 0: cols = @["key", "value"]
                return okResult(rows, cols)

        # B-Tree range scan for BETWEEN
        if w.kind == nkBetweenExpr:
          if w.betweenExpr.kind == nkIdent and w.betweenLow.kind == nkStringLit and w.betweenHigh.kind == nkStringLit:
            let colName = w.betweenExpr.identName
            let idxName = stmt.selFrom.fromTable & "." & colName
            if idxName in ctx.btrees:
              let scanned = ctx.btrees[idxName].scan(w.betweenLow.strVal, w.betweenHigh.strVal)
              var rows: seq[Row] = @[]
              for (k, entries) in scanned:
                for entry in entries:
                  let (found, val) = ctx.db.get(entry.lsmKey)
                  if found:
                    rows.add(parseRowDataToValueRow(cast[string](val)))
              let tbl = ctx.getTableDef(stmt.selFrom.fromTable)
              var cols: seq[string] = @[]
              for c in tbl.columns: cols.add(c.name)
              if cols.len == 0: cols = @["key", "value"]
              return okResult(rows, cols)

        # B-Tree range scan for > >= < <=
        if w.kind == nkBinOp and w.binLeft.kind == nkIdent and w.binRight.kind == nkStringLit:
          let colName = w.binLeft.identName
          let idxName = stmt.selFrom.fromTable & "." & colName
          if idxName in ctx.btrees:
            var startKey = ""
            var endKey = ""
            case w.binOp
            of bkGt:
              startKey = w.binRight.strVal & "\x00"
              endKey = "\x7f"
            of bkGtEq:
              startKey = w.binRight.strVal
              endKey = "\x7f"
            of bkLt:
              startKey = ""
              endKey = w.binRight.strVal
            of bkLtEq:
              startKey = ""
              endKey = w.binRight.strVal
            else: discard
            if startKey != "" or endKey != "":
              let scanned = ctx.btrees[idxName].scan(startKey, endKey)
              var rows: seq[Row] = @[]
              for (k, entries) in scanned:
                for entry in entries:
                  let (found, val) = ctx.db.get(entry.lsmKey)
                  if found:
                    rows.add(parseRowDataToValueRow(cast[string](val)))
              let tbl = ctx.getTableDef(stmt.selFrom.fromTable)
              var cols: seq[string] = @[]
              for c in tbl.columns: cols.add(c.name)
              if cols.len == 0: cols = @["key", "value"]
              return okResult(rows, cols)

    # Full pipeline execution
    let plan = lowerSelect(stmt)
    let rows = executePlan(ctx, plan)
    var cols = getSelectColumns(stmt)
    # Expand star to table columns
    if "*" in cols:
      var expandedCols: seq[string] = @[]
      var seenColNames = initTable[string, bool]()
      let fromTable = if stmt.selFrom != nil and stmt.selFrom.kind == nkFrom: stmt.selFrom.fromTable else: ""
      let fromAlias = if stmt.selFrom != nil and stmt.selFrom.kind == nkFrom: stmt.selFrom.fromAlias else: ""
      for c in cols:
        if c == "*":
          if fromTable.len > 0:
            let tbl = ctx.getTableDef(fromTable)
            for tc in tbl.columns:
              expandedCols.add(tc.name)
              seenColNames[tc.name] = true
          for j in stmt.selJoins:
            if j.kind == nkJoin and j.joinTarget != nil and j.joinTarget.kind == nkFrom:
              let joinTbl = ctx.getTableDef(j.joinTarget.fromTable)
              let alias = j.joinTarget.fromAlias
              for tc in joinTbl.columns:
                if tc.name in seenColNames:
                  if alias.len > 0:
                    expandedCols.add(alias & "." & tc.name)
                  else:
                    expandedCols.add(j.joinTarget.fromTable & "." & tc.name)
                else:
                  expandedCols.add(tc.name)
                  seenColNames[tc.name] = true
        else:
          expandedCols.add(c)
      cols = expandedCols
    if cols.len == 0:
      let tbl = ctx.getTableDef(if stmt.selFrom != nil and stmt.selFrom.kind == nkFrom: stmt.selFrom.fromTable else: "")
      for c in tbl.columns: cols.add(c.name)
    if cols.len == 0 and rows.len > 0:
      for k, _ in rows[0]: cols.add(k)
    return okResult(rows, cols)

  of nkSetOp:
    # Execute left and right queries
    var innerLeft = Node(kind: nkStatementList, stmts: @[])
    innerLeft.stmts.add(stmt.setOpLeft)
    let leftRes = executeQueryImpl(ctx, innerLeft)

    var innerRight = Node(kind: nkStatementList, stmts: @[])
    innerRight.stmts.add(stmt.setOpRight)
    let rightRes = executeQueryImpl(ctx, innerRight)

    # Derive columns from left side
    var cols = leftRes.columns
    if cols.len == 0:
      cols = rightRes.columns

    var rows: seq[Row] = @[]
    case stmt.setOpKind
    of sdkUnion:
      rows = leftRes.rows
      if stmt.setOpAll:
        # UNION ALL: simple concatenation
        for row in rightRes.rows:
          rows.add(row)
      else:
        # UNION: deduplicate
        var seen: Table[string, bool]
        for row in leftRes.rows:
          seen[valueToString(row["$value"])] = true
        for row in rightRes.rows:
          if not seen.getOrDefault(valueToString(row["$value"]), false):
            seen[valueToString(row["$value"])] = true
            rows.add(row)

    of sdkIntersect:
      var leftSet: Table[string, bool]
      for row in leftRes.rows:
        leftSet[valueToString(row["$value"])] = true
      for row in rightRes.rows:
        if leftSet.getOrDefault(valueToString(row["$value"]), false):
          rows.add(row)
          if not stmt.setOpAll:
            leftSet.del(valueToString(row["$value"]))  # remove to prevent duplicates for INTERSECT (not ALL)

    of sdkExcept:
      var rightSet: Table[string, bool]
      for row in rightRes.rows:
        rightSet[valueToString(row["$value"])] = true
      for row in leftRes.rows:
        if not rightSet.getOrDefault(valueToString(row["$value"]), false):
          rows.add(row)

    return okResult(rows, cols)

  of nkInsert:
    var fields: seq[string] = @[]
    for f in stmt.insFields:
      if f.kind == nkIdent: fields.add(f.identName)
      else: fields.add("")

    var values: seq[seq[string]] = @[]
    for rowNode in stmt.insValues:
      var row: seq[string] = @[]
      if rowNode.kind == nkArrayLit:
        for v in rowNode.arrayElems:
          if v.kind == nkStringLit: row.add(v.strVal)
          elif v.kind == nkIntLit: row.add($v.intVal)
          elif v.kind == nkFloatLit: row.add($v.floatVal)
          elif v.kind == nkBoolLit: row.add($v.boolVal)
          elif v.kind == nkNullLit: row.add("\\N")
          else: row.add(evalNodeToString(v))
      else:
        if rowNode.kind == nkStringLit: row.add(rowNode.strVal)
        elif rowNode.kind == nkIntLit: row.add($rowNode.intVal)
        elif rowNode.kind == nkFloatLit: row.add($rowNode.floatVal)
        elif rowNode.kind == nkBoolLit: row.add($rowNode.boolVal)
        elif rowNode.kind == nkNullLit: row.add("\\N")
        else: row.add(evalNodeToString(rowNode))
      values.add(row)

    if fields.len == 0:
      let tbl = ctx.getTableDef(stmt.insTarget)
      for col in tbl.columns: fields.add(col.name)

    let tbl = ctx.getTableDef(stmt.insTarget)

    # Auto-increment: populate missing auto-increment columns
    var mutableFields = fields
    var mutableValues = values
    for col in tbl.columns:
      if col.autoIncrement and col.name notin mutableFields:
        let counterKey = stmt.insTarget & "." & col.name
        var nextVal: int64 = 1
        acquire(ctx.sharedLock.lock)
        try:
          if counterKey in ctx.autoIncCounters:
            nextVal = ctx.autoIncCounters[counterKey]
          ctx.autoIncCounters[counterKey] = nextVal + int64(mutableValues.len)
        finally:
          release(ctx.sharedLock.lock)
        # Insert at position 0 so it becomes the primary storage key
        mutableFields.insert(col.name, 0)
        for i in 0..<mutableValues.len:
          mutableValues[i].insert($(nextVal + int64(i)), 0)
      elif col.autoIncrement and col.name in mutableFields:
        # User provided value — update counter to max
        let idx = mutableFields.find(col.name)
        if idx >= 0:
          for rowVals in mutableValues.mitems:
            if idx < rowVals.len:
              let providedVal = rowVals[idx]
              try:
                let intVal = parseInt(providedVal)
                let counterKey = stmt.insTarget & "." & col.name
                acquire(ctx.sharedLock.lock)
                try:
                  if counterKey notin ctx.autoIncCounters or intVal >= ctx.autoIncCounters[counterKey]:
                    ctx.autoIncCounters[counterKey] = intVal + 1
                finally:
                  release(ctx.sharedLock.lock)
              except CatchableError: discard

    applyDefaultValues(tbl, mutableFields, mutableValues)

    let (valid, errMsg) = validateConstraints(ctx, stmt.insTarget, mutableFields, mutableValues)
    if not valid: return errResult(errMsg)

    # Fire BEFORE INSERT triggers
    var row = initTable[string, Value]()
    if mutableValues.len > 0:
      for i, f in mutableFields:
        if i < mutableValues[0].len:
          row[f] = mutableValues[0][i]
    fireTriggers(ctx, stmt.insTarget, "before", "insert", row)

    var kvPairs: seq[(string, seq[byte])]
    let count = execInsert(ctx, stmt.insTarget, mutableFields, mutableValues, kvPairs)

    # Fire AFTER INSERT triggers
    fireTriggers(ctx, stmt.insTarget, "after", "insert", row)

    if ctx.onChange != nil:
      for i in 0..<count:
        ctx.onChange(ChangeEvent(table: stmt.insTarget, kind: ckInsert, key: "", data: ""))

    # RETURNING clause
    if stmt.insReturning.len > 0 and mutableValues.len > 0:
      var returnRows: seq[Row] = @[]
      var returnCols: seq[string] = @[]
      for retExpr in stmt.insReturning:
        if retExpr.kind == nkIdent:
          returnCols.add(retExpr.identName)
        elif retExpr.kind == nkStar:
          returnCols.add("*")
        elif retExpr.exprAlias.len > 0:
          returnCols.add(retExpr.exprAlias)
        else:
          returnCols.add("col" & $returnCols.len)
      for rowVals in mutableValues:
        var rowMap = initTable[string, Value]()
        for i, f in mutableFields:
          if i < rowVals.len:
            rowMap[f] = rowVals[i]
        var returnRow = initTable[string, Value]()
        for i, retExpr in stmt.insReturning:
          let ir = lowerExpr(retExpr)
          let val = evalExpr(ir, rowMap, ctx)
          if returnCols[i] == "*":
            for k, v in rowMap:
              returnRow[k] = v
          else:
            returnRow[returnCols[i]] = val
        returnRows.add(returnRow)
      if returnCols.contains("*"):
        var expandedCols: seq[string] = @[]
        for c in tbl.columns: expandedCols.add(c.name)
        return okResult(returnRows, expandedCols, affected=count)
      return okResult(returnRows, returnCols, affected=count)

    return okResult(affected=count, kvPairs=kvPairs)

  of nkUpdate:
    if stmt.updSet.len == 0: return okResult()
    # Simple UPDATE: scan table, filter by WHERE, apply SET
    # Scan and apply
    let rows = execScan(ctx, stmt.updTarget)
    var count = 0
    var kvPairs: seq[(string, seq[byte])]
    for row in rows:
      # Compute sets for this row (expressions may reference columns)
      var sets = initTable[string, string]()
      for s in stmt.updSet:
        if s.kind == nkBinOp and s.binOp == bkAssign:
          if s.binLeft.kind == nkIdent:
            let val = if s.binRight.kind == nkStringLit: s.binRight.strVal
                      elif s.binRight.kind == nkIntLit: $s.binRight.intVal
                      elif s.binRight.kind == nkFloatLit: $s.binRight.floatVal
                      elif s.binRight.kind == nkBoolLit: $s.binRight.boolVal
                      elif s.binRight.kind == nkNullLit: "\\N"
                      else: valueToString(evalExpr(lowerExpr(s.binRight), row, ctx))
            sets[s.binLeft.identName] = val
      # Check WHERE
      if stmt.updWhere != nil and stmt.updWhere.whereExpr != nil:
        let whereExpr = lowerExpr(stmt.updWhere.whereExpr)
        if valueToString(evalExpr(whereExpr, row, ctx)) != "true": continue
      # Get key from row
      if "$key" in row:
        let old = valueToString(row["$key"])
        # Build updated row for constraint validation
        var updFields: seq[string] = @[]
        var updValues: seq[string] = @[]
        for col in ctx.getTableDef(stmt.updTarget).columns:
          updFields.add(col.name)
          if col.name in sets:
            updValues.add(sets[col.name])
          elif col.name in row:
            updValues.add(valueToString(row[col.name]))
          else:
            updValues.add("\\N")
        let (valid, errMsg) = validateConstraints(ctx, stmt.updTarget, updFields, @[updValues], skipPkCheck = true)
        if not valid: return errResult(errMsg)
        # FK ON UPDATE enforcement (parent side)
        var refCols: seq[string] = @[]
        for _, childTbl in ctx.tables:
          for col in childTbl.columns:
            if col.fkTable == stmt.updTarget and col.fkColumn notin refCols:
              refCols.add(col.fkColumn)
        for refCol in refCols:
          if refCol in sets and refCol in row:
            let (fkOk, fkErr) = enforceFkOnUpdate(ctx, stmt.updTarget, refCol, valueToString(row[refCol]), sets[refCol])
            if not fkOk:
              return errResult(fkErr)
        # FK ON UPDATE enforcement (child side — validate new FK values)
        for colName, newVal in sets:
          let (fkOk, fkErr) = enforceFkOnChildUpdate(ctx, stmt.updTarget, colName, newVal)
          if not fkOk:
            return errResult(fkErr)
        # Fire BEFORE UPDATE triggers
        var oldRow = row
        var newRow = row
        for col, val in sets:
          newRow[col] = Value(kind: vkString, strVal: val)
        fireTriggers(ctx, stmt.updTarget, "before", "update", oldRow)

        count += execUpdateRow(ctx, stmt.updTarget, valueToString(row["$key"]), sets, kvPairs)

        # Fire AFTER UPDATE triggers
        fireTriggers(ctx, stmt.updTarget, "after", "update", newRow)

        if ctx.onChange != nil:
          ctx.onChange(ChangeEvent(table: stmt.updTarget, kind: ckUpdate, key: old, data: ""))
    return okResult(affected=count, kvPairs=kvPairs)

  of nkDelete:
    # Delete all rows matching WHERE
    let rows = execScan(ctx, stmt.delTarget)
    var count = 0
    var kvPairs: seq[(string, seq[byte])]
    for row in rows:
      if stmt.delWhere != nil and stmt.delWhere.whereExpr != nil:
        let whereExpr = lowerExpr(stmt.delWhere.whereExpr)
        if valueToString(evalExpr(whereExpr, row, ctx)) != "true": continue
      if "$key" in row:
        let old = valueToString(row["$key"])
        # Fire BEFORE DELETE triggers
        fireTriggers(ctx, stmt.delTarget, "before", "delete", row)

        # FK ON DELETE enforcement
        var refCols: seq[string] = @[]
        for _, childTbl in ctx.tables:
          for col in childTbl.columns:
            if col.fkTable == stmt.delTarget and col.fkColumn notin refCols:
              refCols.add(col.fkColumn)
        for refCol in refCols:
          if refCol in row:
            let (fkOk, fkErr) = enforceFkOnDelete(ctx, stmt.delTarget, refCol, valueToString(row[refCol]))
            if not fkOk:
              return errResult(fkErr)

        count += execDelete(ctx, stmt.delTarget, valueToString(row["$key"]), kvPairs)

        # Fire AFTER DELETE triggers
        fireTriggers(ctx, stmt.delTarget, "after", "delete", row)

        if ctx.onChange != nil:
          ctx.onChange(ChangeEvent(table: stmt.delTarget, kind: ckDelete, key: old, data: ""))
    return okResult(affected=count, kvPairs=kvPairs)

  of nkMerge:
    # Execute source: subquery or table scan
    var sourceRows: seq[Row] = @[]
    if stmt.mergeSource != nil:
      if stmt.mergeSource.kind == nkSelect:
        let srcRes = executeQueryImpl(ctx, Node(kind: nkStatementList, stmts: @[stmt.mergeSource]))
        sourceRows = srcRes.rows
      elif stmt.mergeSource.kind == nkIdent:
        sourceRows = execScan(ctx, stmt.mergeSource.identName)

    let targetRows = execScan(ctx, stmt.mergeTarget)
    var count = 0
    var kvPairs: seq[(string, seq[byte])]

    for srcRow in sourceRows:
      var matched = false
      var combinedRow = srcRow
      for k, v in srcRow:
        combinedRow[stmt.mergeSourceAlias & "." & k] = v
      for tgtRow in targetRows:
        # Evaluate ON condition with both source and target rows visible
        var rowWithTarget = combinedRow
        for k, v in tgtRow:
          rowWithTarget[stmt.mergeTargetAlias & "." & k] = v
        let onExpr = lowerExpr(stmt.mergeOn)
        if valueToString(evalExpr(onExpr, rowWithTarget, ctx)) == "true":
          matched = true
          if stmt.mergeMatchedUpdate.len > 0 and "$key" in tgtRow:
            var updateSets = initTable[string, string]()
            for s in stmt.mergeMatchedUpdate:
              if s.kind == nkBinOp and s.binOp == bkAssign:
                if s.binLeft.kind == nkIdent:
                  let valExpr = lowerExpr(s.binRight)
                  updateSets[s.binLeft.identName] = valueToString(evalExpr(valExpr, rowWithTarget, ctx))
            var newRow = tgtRow
            for col, val in updateSets:
              newRow[col] = Value(kind: vkString, strVal: val)
            fireTriggers(ctx, stmt.mergeTarget, "before", "update", tgtRow)
            count += execUpdateRow(ctx, stmt.mergeTarget, valueToString(tgtRow["$key"]), updateSets, kvPairs)
            fireTriggers(ctx, stmt.mergeTarget, "after", "update", newRow)
            if ctx.onChange != nil:
              ctx.onChange(ChangeEvent(table: stmt.mergeTarget, kind: ckUpdate, key: valueToString(tgtRow["$key"]), data: ""))
          break

      if not matched and stmt.mergeNotMatchedInsert.len > 0:
        var fields: seq[string] = @[]
        var values: seq[string] = @[]
        for i, colNode in stmt.mergeNotMatchedInsert:
          if colNode.kind == nkIdent:
            fields.add(colNode.identName)
            if i < stmt.mergeNotMatchedValues.len:
              let v = stmt.mergeNotMatchedValues[i]
              let valExpr = lowerExpr(v)
              values.add(valueToString(evalExpr(valExpr, combinedRow, ctx)))
            else:
              values.add("\\N")
        if fields.len > 0:
          var row = initTable[string, Value]()
          for i, f in fields:
            if i < values.len: row[f] = Value(kind: vkString, strVal: values[i])
          fireTriggers(ctx, stmt.mergeTarget, "before", "insert", row)
          var insKvPairs: seq[(string, seq[byte])]
          count += execInsert(ctx, stmt.mergeTarget, fields, @[values], insKvPairs)
          for kv in insKvPairs: kvPairs.add(kv)
          fireTriggers(ctx, stmt.mergeTarget, "after", "insert", row)
          if ctx.onChange != nil:
            ctx.onChange(ChangeEvent(table: stmt.mergeTarget, kind: ckInsert, key: "", data: ""))

    return okResult(affected=count, kvPairs=kvPairs)

  of nkCreateTable:
    var tbl = TableDef(name: stmt.crtName, columns: @[], pkColumns: @[],
                       foreignKeys: @[], checks: @[])
    # First pass: collect table-level constraints
    for cstNode in stmt.crtConstraints:
      if cstNode.kind == nkConstraintDef:
        if cstNode.cstType == "pkey":
          for c in cstNode.cstColumns: tbl.pkColumns.add(c)
          for i, c in tbl.columns:
            if c.name in cstNode.cstColumns:
              tbl.columns[i].isPk = true
              ctx.btrees[stmt.crtName & "." & c.name] = newBTreeIndex[string, IndexEntry]()
        elif cstNode.cstType == "fkey":
          tbl.foreignKeys.add(ForeignKeyDef(
            refTable: cstNode.cstRefTable,
            refColumn: if cstNode.cstRefColumns.len > 0: cstNode.cstRefColumns[0] else: "",
            onDelete: cstNode.cstOnDelete,
            onUpdate: cstNode.cstOnUpdate))
          if cstNode.cstColumns.len > 0:
            for i, c in tbl.columns:
              if c.name in cstNode.cstColumns:
                tbl.columns[i].fkTable = cstNode.cstRefTable
                tbl.columns[i].fkColumn = if cstNode.cstRefColumns.len > 0: cstNode.cstRefColumns[0] else: ""
                tbl.columns[i].fkOnDelete = cstNode.cstOnDelete
                tbl.columns[i].fkOnUpdate = cstNode.cstOnUpdate
        elif cstNode.cstType == "check":
          tbl.checks.add(CheckDef(name: "check_" & $tbl.checks.len, checkNode: cstNode.cstCheck))

    # Second pass: column definitions
    for col in stmt.crtColumns:
      if col.kind == nkColumnDef:
        var colDef = ColumnDef(name: col.cdName, colType: col.cdType)
        colDef.autoIncrement = col.cdAutoIncrement
        for cst in col.cdConstraints:
          if cst.kind == nkConstraintDef:
            case cst.cstType
            of "pkey":
              colDef.isPk = true
              if col.cdName notin tbl.pkColumns: tbl.pkColumns.add(col.cdName)
              ctx.btrees[stmt.crtName & "." & col.cdName] = newBTreeIndex[string, IndexEntry]()
            of "notnull": colDef.isNotNull = true
            of "unique":
              colDef.isUnique = true
              ctx.btrees[stmt.crtName & "." & col.cdName] = newBTreeIndex[string, IndexEntry]()
            of "default":
              if cst.cstDefault != nil:
                if cst.cstDefault.kind == nkStringLit: colDef.defaultVal = cst.cstDefault.strVal
                elif cst.cstDefault.kind == nkIntLit: colDef.defaultVal = $cst.cstDefault.intVal
                elif cst.cstDefault.kind == nkBoolLit: colDef.defaultVal = $cst.cstDefault.boolVal
                elif cst.cstDefault.kind == nkFloatLit: colDef.defaultVal = $cst.cstDefault.floatVal
            of "fkey":
              colDef.fkTable = cst.cstRefTable
              colDef.fkColumn = if cst.cstRefColumns.len > 0: cst.cstRefColumns[0] else: ""
              colDef.fkOnDelete = cst.cstOnDelete
              colDef.fkOnUpdate = cst.cstOnUpdate
            of "check":
              tbl.checks.add(CheckDef(name: "check_" & col.cdName, checkNode: cst.cstCheck))
            else: discard
        tbl.columns.add(colDef)
    # Third pass: apply table-level constraints to columns
    for cstNode in stmt.crtConstraints:
      if cstNode.kind == nkConstraintDef:
        if cstNode.cstType == "pkey":
          for i, c in tbl.columns:
            if c.name in cstNode.cstColumns:
              tbl.columns[i].isPk = true
        elif cstNode.cstType == "fkey":
          if cstNode.cstColumns.len > 0:
            for i, c in tbl.columns:
              if c.name in cstNode.cstColumns:
                tbl.columns[i].fkTable = cstNode.cstRefTable
                tbl.columns[i].fkColumn = if cstNode.cstRefColumns.len > 0: cstNode.cstRefColumns[0] else: ""
                tbl.columns[i].fkOnDelete = cstNode.cstOnDelete
                tbl.columns[i].fkOnUpdate = cstNode.cstOnUpdate
    ctx.tables[stmt.crtName] = tbl
    persistTableSchema(ctx, tbl)
    return okResult()

  of nkDropTable:
    let dropName = stmt.drtName
    ctx.tables.del(dropName)
    var toDelete: seq[string] = @[]
    for idxName in ctx.btrees.keys.toSeq():
      if idxName.startsWith(dropName & "."): toDelete.add(idxName)
    for idxName in toDelete: ctx.btrees.del(idxName)
    # Remove durable schema entry
    dropTableSchema(ctx, dropName)
    # Remove row data for this table
    var dataKeys: seq[string] = @[]
    let prefix = dropName & "."
    for (key, _) in ctx.db.scanAll():
      if key.startsWith(prefix):
        dataKeys.add(key)
    for key in dataKeys:
      ctx.db.delete(key)
    # Drop orphan legacy schema keys that mentioned this table
    var legacyKeys: seq[string] = @[]
    for (key, value) in ctx.db.scanAll():
      if key.startsWith(SchemaLegacyCreatePrefix):
        let ddl = cast[string](value)
        if ddl.contains("CREATE TABLE " & dropName) or ddl.contains("CREATE TABLE \"" & dropName):
          legacyKeys.add(key)
    for key in legacyKeys:
      ctx.db.delete(key)
    return okResult()

  of nkCreateGraph:
    let name = stmt.cgName
    if name in ctx.graphs:
      if not stmt.cgIfNotExists:
        return errResult("Graph '" & name & "' already exists")
      return okResult(msg="Graph '" & name & "' already exists")
    var g = gengine.newGraph()
    ctx.graphs[name] = g
    var createNodesSql = "CREATE TABLE " & name & "_nodes (id INTEGER PRIMARY KEY, node_label TEXT, properties TEXT)"
    var createEdgesSql = "CREATE TABLE " & name & "_edges (source_id INTEGER, dest_id INTEGER, edge_label TEXT, weight REAL)"
    let nodesTokens = qlex.tokenize(createNodesSql)
    let nodesAst = qpar.parse(nodesTokens)
    let nodesRes = executeQueryImpl(ctx, nodesAst)
    if not nodesRes.success:
      ctx.graphs.del(name)
      return errResult("Failed to create graph nodes table: " & nodesRes.message)
    let edgesTokens = qlex.tokenize(createEdgesSql)
    let edgesAst = qpar.parse(edgesTokens)
    let edgesRes = executeQueryImpl(ctx, edgesAst)
    if not edgesRes.success:
      ctx.tables.del(name & "_nodes")
      ctx.graphs.del(name)
      return errResult("Failed to create graph edges table: " & edgesRes.message)
    return okResult(msg="CREATE GRAPH " & name)

  of nkDropGraph:
    let name = stmt.dgName
    if name notin ctx.graphs:
      if stmt.dgIfExists:
        return okResult()
      return errResult("Graph '" & name & "' does not exist")
    ctx.graphs.del(name)
    var dropNodesSql = "DROP TABLE " & name & "_nodes"
    var dropEdgesSql = "DROP TABLE " & name & "_edges"
    let nodesTokens = qlex.tokenize(dropNodesSql)
    let nodesAst = qpar.parse(nodesTokens)
    discard executeQueryImpl(ctx, nodesAst)
    let edgesTokens = qlex.tokenize(dropEdgesSql)
    let edgesAst = qpar.parse(edgesTokens)
    discard executeQueryImpl(ctx, edgesAst)
    return okResult(msg="DROP GRAPH " & name)

  of nkBeginTxn:
    if ctx.pendingTxn != nil and ctx.pendingTxn.state == tsActive:
      discard ctx.txnManager.commit(ctx.pendingTxn)
    ctx.pendingTxn = ctx.txnManager.beginTxn(ilReadCommitted)
    return okResult(msg="Transaction started")

  of nkCommitTxn:
    if ctx.pendingTxn != nil and ctx.pendingTxn.state == tsActive:
      var kvPairs: seq[(string, seq[byte])]
      for key, version in ctx.pendingTxn.writeSet:
        if version.isDelete:
          ctx.db.delete(key)
        else:
          ctx.db.put(key, version.value)
        kvPairs.add((key, version.value))
      discard ctx.txnManager.commit(ctx.pendingTxn)
      ctx.pendingTxn = nil
      return okResult(msg="Transaction committed", kvPairs=kvPairs)
    return errResult("No active transaction to commit")

  of nkRollbackTxn:
    if ctx.pendingTxn != nil:
      discard ctx.txnManager.abortTxn(ctx.pendingTxn)
      ctx.pendingTxn = nil
      return okResult(msg="Transaction rolled back")
    return errResult("No active transaction to rollback")

  of nkCreateType:
    return okResult()

  of nkExplainStmt:
    if stmt.expStmt != nil and stmt.expStmt.kind == nkSelect:
      var planStr = "EXPLAIN "
      if stmt.expStmt.selFrom != nil and stmt.expStmt.selFrom.kind == nkFrom:
        planStr &= "SELECT on " & stmt.expStmt.selFrom.fromTable
      var indexUsed = false
      if stmt.expStmt.selFrom != nil and stmt.expStmt.selFrom.kind == nkFrom and stmt.expStmt.selFrom.fromTable.len > 0:
        if stmt.expStmt.selWhere != nil and stmt.expStmt.selWhere.whereExpr != nil:
          let w = stmt.expStmt.selWhere.whereExpr
          if w.kind == nkBinOp and w.binOp == bkEq:
            if w.binLeft.kind == nkIdent:
              let idxName = stmt.expStmt.selFrom.fromTable & "." & w.binLeft.identName
              if idxName in ctx.btrees:
                planStr &= " (using B-Tree index on " & w.binLeft.identName & ")"
                indexUsed = true
      if not indexUsed: planStr &= " (full table scan)"
      return okResult(msg=planStr)
    return okResult(msg="EXPLAIN")

  of nkAlterTable:
    if stmt.altName in ctx.tables:
      var tbl = ctx.tables[stmt.altName]
      for op in stmt.altOps:
        if op.kind == nkColumnDef:
          var colDef = ColumnDef(name: op.cdName, colType: op.cdType)
          tbl.columns.add(colDef)
      ctx.tables[stmt.altName] = tbl
      persistTableSchema(ctx, tbl)
      return okResult(msg="ALTER TABLE " & stmt.altName & " executed")
    return errResult("Table '" & stmt.altName & "' does not exist")

  of nkRecoverToTimestamp:
    let walPath = ctx.db.dir & "/wal.log"
    let entries = readEntries(walPath)
    var applied = 0
    for entry in entries:
      if entry.kind == wekPut:
        ctx.db.put(cast[string](entry.key), entry.value)
        inc applied
      elif entry.kind == wekDelete:
        ctx.db.delete(cast[string](entry.key))
        inc applied
    ctx.restoreSchema()
    return okResult(msg="RECOVERED " & $applied & " entries from WAL")

  of nkCreateView:
    ctx.views[stmt.cvName] = stmt.cvQuery
    let viewKey = "_schema:views:" & stmt.cvName
    let viewSql = selectToSql(stmt.cvQuery)
    let viewDdl = "CREATE VIEW \"" & sqlEscapeIdent(stmt.cvName) & "\" AS " & viewSql
    ctx.db.put(viewKey, cast[seq[byte]](viewDdl))
    return okResult(msg="CREATE VIEW " & stmt.cvName)

  of nkDropView:
    if stmt.dvName in ctx.views:
      ctx.views.del(stmt.dvName)
    let viewKey = "_schema:views:" & stmt.dvName
    ctx.db.delete(viewKey)
    return okResult(msg="DROP VIEW " & stmt.dvName)

  of nkCreateTrigger:
    let tbl = ctx.getTableDef(stmt.trigTable)
    var triggers = tbl.triggers
    triggers.add(TriggerDef(
      name: stmt.trigName,
      timing: stmt.trigTiming,
      event: stmt.trigEvent,
      action: stmt.trigAction,
    ))
    ctx.tables[stmt.trigTable].triggers = triggers
    # Persist trigger to LSM-Tree
    let trigKey = "_schema:triggers:" & stmt.trigTable & ":" & stmt.trigName
    let trigDdl = "CREATE TRIGGER \"" & sqlEscapeIdent(stmt.trigName) & "\" ON \"" & sqlEscapeIdent(stmt.trigTable) & "\" " &
                  stmt.trigTiming & " " & stmt.trigEvent & " AS " & stmt.trigAction.strVal
    ctx.db.put(trigKey, cast[seq[byte]](trigDdl))
    return okResult(msg="CREATE TRIGGER " & stmt.trigName)

  of nkDropTrigger:
    let tbl = ctx.getTableDef(stmt.trigTable)
    var newTriggers: seq[TriggerDef] = @[]
    for trig in tbl.triggers:
      if trig.name != stmt.trigDropName:
        newTriggers.add(trig)
    ctx.tables[stmt.trigTable].triggers = newTriggers
    let trigKey = "_schema:triggers:" & stmt.trigTable & ":" & stmt.trigDropName
    ctx.db.delete(trigKey)
    return okResult(msg="DROP TRIGGER " & stmt.trigDropName)

  of nkCreateMigration:
    let migKey = "_schema:migration:" & stmt.cmName
    let checksum = computeChecksum(stmt.cmBody)
    var storeBody = stmt.cmBody
    if stmt.cmDownBody.len > 0:
      storeBody = storeBody & "|DOWN|" & stmt.cmDownBody
    ctx.db.put(migKey, cast[seq[byte]](storeBody))
    var rec = getMigrationRecord(ctx, stmt.cmName)
    rec.checksum = checksum
    setMigrationRecord(ctx, rec)
    return okResult(msg="CREATE MIGRATION " & stmt.cmName & " (checksum: " & checksum[0..<16] & ")")

  of nkApplyMigration:
    if not acquireMigrationLock(ctx):
      return errResult("Migration already in progress (lock held)")
    defer: releaseMigrationLock(ctx)

    if isMigrationApplied(ctx, stmt.amName):
      return okResult(msg="Migration '" & stmt.amName & "' already applied")

    let (found, upBody, _) = getMigrationBody(ctx, stmt.amName)
    if not found:
      return errResult("Migration '" & stmt.amName & "' not found")

    let storedRec = getMigrationRecord(ctx, stmt.amName)
    let expectedChecksum = computeChecksum(upBody)
    if storedRec.checksum.len > 0 and storedRec.checksum != expectedChecksum:
      return errResult("Migration '" & stmt.amName & "' checksum mismatch! Stored: " &
                       storedRec.checksum[0..<16] & ", Expected: " & expectedChecksum[0..<16])

    let startTime = epochTime()
    let res = executeMigrationSql(ctx, upBody)
    let durationMs = int((epochTime() - startTime) * 1000)

    if not res.success:
      return errResult("Migration '" & stmt.amName & "' failed: " & res.message)

    ctx.db.put(migrationAppliedKey(stmt.amName), cast[seq[byte]]("applied"))
    setMigrationRecord(ctx, MigrationRecord(
      name: stmt.amName,
      checksum: expectedChecksum,
      appliedAt: int64(epochTime()),
      appliedBy: ctx.currentUser,
      durationMs: durationMs,
      rolledBack: false
    ))
    return okResult(msg="APPLY MIGRATION " & stmt.amName & " in " & $durationMs & "ms")

  of nkMigrationStatus:
    var rows: seq[Row] = @[]
    var cols = @["name", "status", "applied_at", "applied_by", "duration_ms", "checksum"]
    for name in listMigrations(ctx):
      let applied = isMigrationApplied(ctx, name)
      let rec = getMigrationRecord(ctx, name)
      var row = initTable[string, Value]()
      row["name"] = name
      row["status"] = if applied: "applied" else: "pending"
      row["applied_at"] = if rec.appliedAt > 0: $rec.appliedAt else: ""
      row["applied_by"] = rec.appliedBy
      row["duration_ms"] = $rec.durationMs
      row["checksum"] = if rec.checksum.len > 0: rec.checksum[0..<16] else: ""
      rows.add(row)
    return okResult(rows, cols, 0, "Migration status")

  of nkMigrationUp:
    if not acquireMigrationLock(ctx):
      return errResult("Migration already in progress (lock held)")
    defer: releaseMigrationLock(ctx)

    var pending: seq[string] = @[]
    for name in listMigrations(ctx):
      if not isMigrationApplied(ctx, name):
        pending.add(name)

    if pending.len == 0:
      return okResult(msg="No pending migrations")

    var toApply = pending
    if stmt.muCount > 0:
      toApply = pending[0 ..< min(stmt.muCount, pending.len)]

    var appliedCount = 0
    var totalDuration = 0
    for name in toApply:
      let (found, upBody, _) = getMigrationBody(ctx, name)
      if not found:
        return errResult("Migration '" & name & "' not found during batch apply")
      let startTime = epochTime()
      let res = executeMigrationSql(ctx, upBody)
      let durationMs = int((epochTime() - startTime) * 1000)
      if not res.success:
        return errResult("Migration '" & name & "' failed: " & res.message &
                         " (" & $appliedCount & " migrations applied before failure)")
      ctx.db.put(migrationAppliedKey(name), cast[seq[byte]]("applied"))
      setMigrationRecord(ctx, MigrationRecord(
        name: name,
        checksum: computeChecksum(upBody),
        appliedAt: int64(epochTime()),
        appliedBy: ctx.currentUser,
        durationMs: durationMs,
        rolledBack: false
      ))
      appliedCount.inc
      totalDuration += durationMs

    return okResult(msg="Applied " & $appliedCount & " migrations in " & $totalDuration & "ms")

  of nkMigrationDown:
    if not acquireMigrationLock(ctx):
      return errResult("Migration already in progress (lock held)")
    defer: releaseMigrationLock(ctx)

    var applied: seq[string] = @[]
    for name in listMigrations(ctx):
      if isMigrationApplied(ctx, name):
        applied.add(name)

    if applied.len == 0:
      return okResult(msg="No applied migrations to rollback")

    var toRollback = applied.reversed()
    let rollbackCount = if stmt.mdCount > 0: stmt.mdCount else: 1
    toRollback = toRollback[0 ..< min(rollbackCount, toRollback.len)]

    var rolledBackCount = 0
    for name in toRollback:
      let (found, _, downBody) = getMigrationBody(ctx, name)
      if not found:
        return errResult("Migration '" & name & "' not found during rollback")
      if downBody.len == 0:
        return errResult("Migration '" & name & "' has no DOWN script")
      let res = executeMigrationSql(ctx, downBody)
      if not res.success:
        return errResult("Rollback of '" & name & "' failed: " & res.message)
      ctx.db.delete(migrationAppliedKey(name))
      var rec = getMigrationRecord(ctx, name)
      rec.rolledBack = true
      setMigrationRecord(ctx, rec)
      rolledBackCount.inc

    return okResult(msg="Rolled back " & $rolledBackCount & " migrations")

  of nkImportFrom:
    let path = stmt.impPath
    let table = stmt.impTable
    let format = stmt.impFormat
    if not fileExists(path):
      return errResult("File not found: " & path)
    let content = readFile(path)
    var columns: seq[string] = @[]
    var rows: seq[seq[string]] = @[]
    case format
    of "csv":
      (columns, rows) = parseCsvTable(content, stmt.impDelimiter, stmt.impHasHeader)
    of "json":
      (columns, rows) = parseJsonTable(content)
    of "ndjson":
      (columns, rows) = parseNdjsonTable(content)
    else:
      return errResult("Unsupported import format: " & format)
    if columns.len == 0:
      return errResult("No columns found in import file")
    var inserted = 0
    let batchSize = stmt.impBatchSize
    var batchRows: seq[seq[string]] = @[]
    for row in rows:
      batchRows.add(row)
      if batchRows.len >= batchSize:
        # Generate INSERT INTO t (c1,c2) VALUES (...),(...) and execute
        let sql = buildInsertSql(table, columns, batchRows)
        let tokens = qlex.tokenize(sql)
        let astNode = qpar.parse(tokens)
        if astNode.stmts.len > 0:
          let insResult = executeQueryImpl(ctx, astNode)
          if insResult.success:
            inserted += batchRows.len
        batchRows.setLen(0)
    if batchRows.len > 0:
      let sql = buildInsertSql(table, columns, batchRows)
      let tokens = qlex.tokenize(sql)
      let astNode = qpar.parse(tokens)
      if astNode.stmts.len > 0:
        let insResult = executeQueryImpl(ctx, astNode)
        if insResult.success:
          inserted += batchRows.len
    return okResult(msg="IMPORTED " & $inserted & " rows into " & table)

  of nkExportTo:
    let path = stmt.expPath
    let table = stmt.expTable
    let format = stmt.expFormat
    var rows: seq[Row] = @[]
    var cols: seq[string] = @[]
    let scanResult = execScan(ctx, table)
    if scanResult.len == 0:
      let tbl = ctx.getTableDef(table)
      if tbl.columns.len == 0:
        return errResult("Table not found: " & table)
      for col in tbl.columns:
        cols.add(col.name)
    else:
      for k, v in scanResult[0].pairs:
        cols.add(k)
      rows = scanResult
    var content = ""
    var strRows: seq[seq[string]] = @[]
    for row in rows:
      var strRow: seq[string] = @[]
      for col in cols:
        strRow.add(if col in row: valueToString(row[col]) else: "")
      strRows.add(strRow)
    case format
    of "csv":
      content = toCsv(cols, strRows, stmt.expDelimiter, stmt.expIncludeHeader)
    of "json":
      content = toJson(cols, strRows)
    of "ndjson":
      content = toNdjson(cols, strRows)
    else:
      return errResult("Unsupported export format: " & format)
    writeFile(path, content)
    return okResult(msg="EXPORTED " & $strRows.len & " rows to " & path)

  of nkMigrationDryRun:
    let (found, upBody, downBody) = getMigrationBody(ctx, stmt.mdrName)
    if not found:
      return errResult("Migration '" & stmt.mdrName & "' not found")
    let tokens = qlex.tokenize(upBody)
    let astNode = qpar.parse(tokens)
    var msg = "DRY RUN " & stmt.mdrName & ":\n"
    msg.add("  Statements: " & $astNode.stmts.len & "\n")
    for i, s in astNode.stmts:
      msg.add("  [" & $(i+1) & "] " & $s.kind & "\n")
    msg.add("  DOWN script: " & (if downBody.len > 0: "yes" else: "no") & "\n")
    msg.add("  Checksum: " & computeChecksum(upBody)[0..<16] & "\n")
    return okResult(msg=msg)

  of nkCreateIndex:
    var colKey = stmt.ciTarget
    for col in stmt.ciColumns:
      colKey = colKey & "." & col
    let idxName = if stmt.ciName.len > 0: stmt.ciName else: colKey

    if stmt.ciKind == ikFullText:
      # Full-text search index
      var ftsIdx = fts.newInvertedIndex()
      let rows = execScan(ctx, stmt.ciTarget)
      for row in rows:
        let lsmKey = if "$key" in row: valueToString(row["$key"]) else: ""
        let docKey = stmt.ciTarget & "." & lsmKey
        var docId: uint64 = 0
        for ch in docKey:
          docId = docId * 31 + uint64(ord(ch))
        for col in stmt.ciColumns:
          let text = if col in row: valueToString(row[col]) else: ""
          if text.len > 0:
            ftsIdx.addDocument(docId, text)
      ctx.ftsIndexes[colKey] = ftsIdx
      return okResult(msg="CREATE INDEX " & idxName & " on " & stmt.ciTarget & " USING FTS")

    if stmt.ciKind == ikHNSW:
      # Vector HNSW index
      let rows = execScan(ctx, stmt.ciTarget)
      var dimensions = 0
      for row in rows:
        for col in stmt.ciColumns:
          if col in row:
            let vec = parseVectorString(valueToString(row[col]))
            if vec.len > 0:
              dimensions = vec.len
              break
        if dimensions > 0: break
      if dimensions == 0:
        dimensions = 128  # Default dimension
      var hnswIdx = vengine.newHNSWIndex(dimensions, m = 16, efConstruction = 200, metric = vengine.dmCosine)
      for row in rows:
        for col in stmt.ciColumns:
          if col in row:
            let vec = parseVectorString(valueToString(row[col]))
            if vec.len > 0:
              var meta = initTable[string, string]()
              if "$key" in row:
                meta["key"] = valueToString(row["$key"])
              for col, val in row:
                if col.len > 0 and col != "$key" and col != "$value":
                  meta[col] = valueToString(val)
              let fullKey = stmt.ciTarget & "." & valueToString(row["$key"])
              var docId: uint64 = 0
              for ch in fullKey:
                docId = docId * 31 + uint64(ord(ch))
              vengine.insert(hnswIdx, docId, vec, meta)
      ctx.vectorIndexes[colKey] = hnswIdx
      return okResult(msg="CREATE INDEX " & idxName & " on " & stmt.ciTarget & " USING HNSW")

    ctx.btrees[colKey] = newBTreeIndex[string, IndexEntry]()
    # Populate index from existing data
    let rows = execScan(ctx, stmt.ciTarget)
    for row in rows:
      var colVals: seq[string] = @[]
      for col in stmt.ciColumns:
        if col in row:
          colVals.add(valueToString(row[col]))
        else:
          colVals.add("\\N")
      let idxVal = colVals.join("|")
      if idxVal.len > 0 and not isNull(idxVal):
        let lsmKey = if "$key" in row: stmt.ciTarget & "." & valueToString(row["$key"]) else: ""
        ctx.btrees[colKey].insert(idxVal, IndexEntry(lsmKey: lsmKey, rowValue: ""))
    return okResult(msg="CREATE INDEX " & idxName & " on " & stmt.ciTarget)

  of nkDropIndex:
    # Find and remove index by name from ctx.btrees
    var found = false
    var targetKey = ""
    for key, _ in ctx.btrees:
      # Index key format: table.col or table.col1.col2
      # Try matching by the full key or by the table.indexName convention
      if key == stmt.diName or key.endsWith("." & stmt.diName):
        targetKey = key
        found = true
        break
    if found:
      ctx.btrees.del(targetKey)
      return okResult(msg="DROP INDEX " & stmt.diName)
    else:
      # Also remove from schema storage
      let idxKey = "_schema:indexes:" & stmt.diName
      ctx.db.delete(idxKey)
      return okResult(msg="DROP INDEX " & stmt.diName)

  of nkCreateUser:
    ctx.users[stmt.cuName] = UserDef(name: stmt.cuName, passwordHash: stmt.cuPassword,
                                     isSuperuser: stmt.cuSuperuser, roles: @[])
    let userKey = "_schema:users:" & stmt.cuName
    let userDdl = "CREATE USER \"" & sqlEscapeIdent(stmt.cuName) & "\" WITH PASSWORD '" & sqlEscapeString(stmt.cuPassword) & "'" &
                  (if stmt.cuSuperuser: " SUPERUSER" else: " NOSUPERUSER")
    ctx.db.put(userKey, cast[seq[byte]](userDdl))
    return okResult(msg="CREATE USER " & stmt.cuName)

  of nkDropUser:
    if stmt.duName in ctx.users:
      ctx.users.del(stmt.duName)
    let userKey = "_schema:users:" & stmt.duName
    ctx.db.delete(userKey)
    return okResult(msg="DROP USER " & stmt.duName)

  of nkCreatePolicy:
    var pols = ctx.policies.getOrDefault(stmt.cpTable)
    pols.add(PolicyDef(name: stmt.cpName, tableName: stmt.cpTable,
                       command: stmt.cpCommand, usingExpr: stmt.cpUsing,
                       withCheckExpr: stmt.cpWithCheck))
    ctx.policies[stmt.cpTable] = pols
    let polKey = "_schema:policies:" & stmt.cpTable & ":" & stmt.cpName
    var polDdl = "CREATE POLICY \"" & sqlEscapeIdent(stmt.cpName) & "\" ON \"" & sqlEscapeIdent(stmt.cpTable) & "\""
    if stmt.cpCommand != "ALL":
      polDdl.add(" FOR " & stmt.cpCommand)
    if stmt.cpUsing != nil:
      polDdl.add(" USING (expr)")
    if stmt.cpWithCheck != nil:
      polDdl.add(" WITH CHECK (expr)")
    ctx.db.put(polKey, cast[seq[byte]](polDdl))
    return okResult(msg="CREATE POLICY " & stmt.cpName)

  of nkDropPolicy:
    if stmt.dpTable in ctx.policies:
      var newPols: seq[PolicyDef] = @[]
      for pol in ctx.policies[stmt.dpTable]:
        if pol.name != stmt.dpName:
          newPols.add(pol)
      ctx.policies[stmt.dpTable] = newPols
    let polKey = "_schema:policies:" & stmt.dpTable & ":" & stmt.dpName
    ctx.db.delete(polKey)
    return okResult(msg="DROP POLICY " & stmt.dpName)

  of nkEnableRLS:
    # Mark table as RLS-enabled by creating a sentinel key
    let rlsKey = "_schema:rls:" & stmt.erlsTable
    ctx.db.put(rlsKey, cast[seq[byte]]("enabled"))
    return okResult(msg="ENABLE ROW LEVEL SECURITY on " & stmt.erlsTable)

  of nkDisableRLS:
    let rlsKey = "_schema:rls:" & stmt.drlsTable
    ctx.db.delete(rlsKey)
    return okResult(msg="DISABLE ROW LEVEL SECURITY on " & stmt.drlsTable)

  of nkGrant:
    # Store grant in LSM-Tree for persistence
    let grantKey = "_schema:grants:" & stmt.grTable & ":" & stmt.grPrivilege & ":" & stmt.grGrantee
    ctx.db.put(grantKey, cast[seq[byte]]("granted"))
    return okResult(msg="GRANT " & stmt.grPrivilege & " ON " & stmt.grTable & " TO " & stmt.grGrantee)

  of nkRevoke:
    let grantKey = "_schema:grants:" & stmt.rvTable & ":" & stmt.rvPrivilege & ":" & stmt.rvGrantee
    ctx.db.delete(grantKey)
    return okResult(msg="REVOKE " & stmt.rvPrivilege & " ON " & stmt.rvTable & " FROM " & stmt.rvGrantee)

  of nkSetVar:
    ctx.sessionVars[stmt.svName] = stmt.svValue
    return okResult(msg="SET " & stmt.svName & " = " & stmt.svValue)

  of nkCreateDatabase:
    if ctx.registry == nil:
      return errResult("Multi-database support not enabled")
    if not isValidDbName(stmt.cdDbName):
      return errResult("Invalid database name: " & stmt.cdDbName)
    if databaseExists(ctx.registry, stmt.cdDbName) and not stmt.cdIfNotExists:
      return errResult("Database already exists: " & stmt.cdDbName)
    if databaseExists(ctx.registry, stmt.cdDbName) and stmt.cdIfNotExists:
      return okResult(msg="CREATE DATABASE " & stmt.cdDbName)
    try:
      discard getOrCreateDatabase(ctx.registry, stmt.cdDbName)
      let dbKey = "_schema:databases:" & stmt.cdDbName
      ctx.db.put(dbKey, cast[seq[byte]]("created"))
      return okResult(msg="CREATE DATABASE " & stmt.cdDbName)
    except CatchableError as e:
      return errResult("CREATE DATABASE failed: " & e.msg)

  of nkDropDatabase:
    if ctx.registry == nil:
      return errResult("Multi-database support not enabled")
    if stmt.ddDbName == "default":
      return errResult("Cannot drop the default database")
    try:
      let count = getConnectionCount(ctx.registry, stmt.ddDbName)
      if count > 0:
        return errResult("Cannot drop database '" & stmt.ddDbName &
                         "': " & $count & " active connections")
      let dbKey = "_schema:databases:" & stmt.ddDbName
      ctx.db.delete(dbKey)
      if dropDatabase(ctx.registry, stmt.ddDbName):
        return okResult(msg="DROP DATABASE " & stmt.ddDbName)
      elif stmt.ddIfExists:
        return okResult(msg="DROP DATABASE " & stmt.ddDbName)
      else:
        return errResult("Database not found: " & stmt.ddDbName)
    except CatchableError as e:
      return errResult("DROP DATABASE failed: " & e.msg)

  of nkUseDatabase:
    if ctx.registry == nil:
      return errResult("Multi-database support not enabled")
    if ctx.pendingTxn != nil:
      return errResult("Cannot switch database inside a transaction. Commit or rollback first.")
    let info = getDatabaseInfo(ctx.registry, stmt.udDbName)
    if info == nil:
      return errResult("Database not found: " & stmt.udDbName)
    let targetCtx = cast[ExecutionContext](cast[pointer](info.ctx))
    let oldDb = ctx.currentDatabase
    ctx.db = info.db
    ctx.tables = targetCtx.tables
    ctx.btrees = targetCtx.btrees
    ctx.views = targetCtx.views
    ctx.ftsIndexes = targetCtx.ftsIndexes
    ctx.vectorIndexes = targetCtx.vectorIndexes
    ctx.users = targetCtx.users
    ctx.policies = targetCtx.policies
    ctx.graphs = targetCtx.graphs
    ctx.autoIncCounters = targetCtx.autoIncCounters
    ctx.sequences = targetCtx.sequences
    ctx.currentDatabase = stmt.udDbName
    decrementConnections(ctx.registry, oldDb)
    incrementConnections(ctx.registry, stmt.udDbName)
    return okResult(msg="Changed to database '" & stmt.udDbName & "'")

  of nkShowDatabases:
    if ctx.registry == nil:
      return errResult("Multi-database support not enabled")
    var rows: seq[Row] = @[]
    for dbName in listDatabases(ctx.registry):
      var row = initTable[string, Value]()
      row["name"] = dbName
      rows.add(row)
    return okResult(rows, @["name"])

  of nkShowTables:
    if stmt.stTableName.len == 0:
      # SHOW TABLES — list all tables
      var rows: seq[Row] = @[]
      for tableName in ctx.tables.keys:
        var row = initTable[string, Value]()
        row["name"] = tableName
        rows.add(row)
      return okResult(rows, @["name"])
    else:
      # SHOW COLUMNS FROM table — describe a specific table
      var rows: seq[Row] = @[]
      let tbl = ctx.getTableDef(stmt.stTableName)
      for col in tbl.columns:
        var row = initTable[string, Value]()
        row["column_name"] = col.name
        row["data_type"] = col.colType
        row["is_nullable"] = if col.isNotNull: "NO" else: "YES"
        row["is_primary_key"] = if col.isPk: "YES" else: "NO"
        if col.defaultVal.len > 0:
          row["column_default"] = col.defaultVal
        else:
          row["column_default"] = ""
        rows.add(row)
      return okResult(rows, @["column_name", "data_type", "is_nullable", "is_primary_key", "column_default"])

  else:
    return errResult("Unsupported statement type: " & $stmt.kind)


proc executeQuery*(ctx: ExecutionContext, astNode: Node, params: seq[WireValue] = @[]): ExecResult =
  if astNode == nil or astNode.stmts.len == 0:
    return okResult()
  let stmt = astNode.stmts[0]
  if isDDL(stmt):
    acquire(ctx.sharedLock.lock)
    try:
      result = executeQueryImpl(ctx, astNode, params)
    finally:
      release(ctx.sharedLock.lock)
  else:
    result = executeQueryImpl(ctx, astNode, params)

proc executeMigrationSql(ctx: ExecutionContext, sql: string): ExecResult =
  let tokens = qlex.tokenize(sql)
  let astNode = qpar.parse(tokens)
  if astNode.stmts.len > 0:
    return executeQueryImpl(ctx, astNode)
  return okResult(msg="Empty migration body")

# ----------------------------------------------------------------------
# Hook wiring — eval.nim back-edges (subqueries, hybrid search, NL->SQL
# validation). Resolved at module scope; stays valid when executePlan
# moves to its own module in a later task.
# ----------------------------------------------------------------------
eval.executePlanHook = executePlan
eval.execScanHook = scan.execScan
eval.executeQueryHook = executeQuery
