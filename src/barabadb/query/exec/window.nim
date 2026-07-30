## Window function computation (partitionKey / compareRowsByOrder /
## resolveFrameBounds / computeWindowValues) and star-row expansion —
## extracted from `executor.nim` (Task 12 of the executor split).
import std/strutils
import std/tables
import std/algorithm
import ../ir
import ../../core/types
import types
import values
import context
import eval

# ----------------------------------------------------------------------
# Window Function Computation
# ----------------------------------------------------------------------

proc partitionKey*(row: Row, partExprs: seq[IRExpr], ctx: ExecutionContext = nil): string =
  ## Compute a string partition key for a row
  result = ""
  for expr in partExprs:
    result &= valueToString(evalExpr(expr, row, ctx)) & "|"

proc compareRowsByOrder*(a, b: Row, orderExprs: seq[IRExpr], orderDirs: seq[bool], ctx: ExecutionContext = nil): int =
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

proc resolveFrameBounds*(pos, partLen: int, frameStart, frameEnd: string): (int, int) =
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

proc expandStarRow*(row: Row): Row =
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
