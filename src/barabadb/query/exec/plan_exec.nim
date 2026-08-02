## IR plan execution (executePlan) — walks a lowered IRPlan tree and
## produces result rows: filters, projections, aggregates, grouping sets,
## joins (nested loop / hash / index nested loop / lateral), pivot/unpivot,
## and graph traversal. Extracted from `executor.nim` (Task 13 of the
## executor split). Pure code motion — no behavior changes.
import std/strutils
import std/tables
import std/sets
import std/sequtils
import std/algorithm
import ../ir
import ../../core/types
import ../../storage/btree
import ../../graph/engine as gengine
import ../../graph/community as gcomm
import types
import values
import helpers
import eval
import scan
import window

# ----------------------------------------------------------------------
# Aggregate DISTINCT helpers
# ----------------------------------------------------------------------

proc shouldKeepDistinct(seen: var HashSet[string], s: string, doDistinct: bool): bool =
  ## Returns true if `s` should be counted/included (first occurrence when distinct).
  if not doDistinct:
    return true
  if s in seen:
    return false
  seen.incl(s)
  return true

# ----------------------------------------------------------------------
# IR Plan Execution (with actual filter/sort/projection)
# ----------------------------------------------------------------------

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
                var seen: HashSet[string]
                for row in filteredRows:
                  let v = evalExpr(expr.aggArgs[0], row, ctx)
                  if v.kind != vkNull:
                    let s = valueToString(v)
                    if shouldKeepDistinct(seen, s, expr.aggDistinct):
                      count += 1
                newRow[alias] = $count
            of irSum:
              var sum = 0.0
              var seen: HashSet[string]
              for row in filteredRows:
                let v = evalExpr(expr.aggArgs[0], row, ctx)
                let s = valueToString(v)
                if shouldKeepDistinct(seen, s, expr.aggDistinct):
                  try: sum += parseFloat(s) except CatchableError: discard
              newRow[alias] = $sum
            of irAvg:
              var sum = 0.0
              var count = 0
              var seen: HashSet[string]
              for row in filteredRows:
                let v = evalExpr(expr.aggArgs[0], row, ctx)
                let s = valueToString(v)
                if shouldKeepDistinct(seen, s, expr.aggDistinct):
                  try: sum += parseFloat(s); count += 1 except CatchableError: discard
              newRow[alias] = if count > 0: $(sum / float(count)) else: "0"
            of irMin:
              var minVal = ""
              var seen: HashSet[string]
              for row in filteredRows:
                let v = evalExpr(expr.aggArgs[0], row, ctx)
                if v.kind == vkNull: continue
                let s = valueToString(v)
                if shouldKeepDistinct(seen, s, expr.aggDistinct):
                  if minVal == "" or cmpMin(s, minVal): minVal = s
              newRow[alias] = minVal
            of irMax:
              var maxVal = ""
              var seen: HashSet[string]
              for row in filteredRows:
                let v = evalExpr(expr.aggArgs[0], row, ctx)
                if v.kind == vkNull: continue
                let s = valueToString(v)
                if shouldKeepDistinct(seen, s, expr.aggDistinct):
                  if maxVal == "" or cmpMax(s, maxVal): maxVal = s
              newRow[alias] = maxVal
            of irArrayAgg:
              var arr: seq[string]
              var seen: HashSet[string]
              for row in filteredRows:
                if expr.aggArgs.len > 0:
                  let s = valueToString(evalExpr(expr.aggArgs[0], row, ctx))
                  if shouldKeepDistinct(seen, s, expr.aggDistinct):
                    arr.add(s)
              newRow[alias] = "[" & arr.join(", ") & "]"
            of irStringAgg:
              var parts: seq[string]
              var seen: HashSet[string]
              let delim = if expr.aggArgs.len > 1: evalExpr(expr.aggArgs[1], initTable[string, Value](), ctx) else: Value(kind: vkString, strVal: ",")
              for row in filteredRows:
                if expr.aggArgs.len > 0:
                  let s = valueToString(evalExpr(expr.aggArgs[0], row, ctx))
                  if shouldKeepDistinct(seen, s, expr.aggDistinct):
                    parts.add(s)
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
              var seen: HashSet[string]
              for row in filteredRows:
                let v = evalExpr(aggExpr.aggArgs[0], row, ctx)
                if v.kind != vkNull:
                  let s = valueToString(v)
                  if shouldKeepDistinct(seen, s, aggExpr.aggDistinct):
                    count += 1
              aggRow[aggKey] = $count
          of irSum:
            var sum = 0.0
            var seen: HashSet[string]
            for row in filteredRows:
              let v = evalExpr(aggExpr.aggArgs[0], row, ctx)
              let s = valueToString(v)
              if shouldKeepDistinct(seen, s, aggExpr.aggDistinct):
                try: sum += parseFloat(s) except CatchableError: discard
            aggRow[aggKey] = $sum
          of irAvg:
            var sum = 0.0
            var count = 0
            var seen: HashSet[string]
            for row in filteredRows:
              let v = evalExpr(aggExpr.aggArgs[0], row, ctx)
              let s = valueToString(v)
              if shouldKeepDistinct(seen, s, aggExpr.aggDistinct):
                try: sum += parseFloat(s); count += 1 except CatchableError: discard
            aggRow[aggKey] = if count > 0: $(sum / float(count)) else: "0"
          of irMin:
            var minVal = ""
            var seen: HashSet[string]
            for row in filteredRows:
              let v = evalExpr(aggExpr.aggArgs[0], row, ctx)
              if v.kind == vkNull: continue
              let s = valueToString(v)
              if shouldKeepDistinct(seen, s, aggExpr.aggDistinct):
                if minVal == "" or cmpMin(s, minVal): minVal = s
            aggRow[aggKey] = minVal
          of irMax:
            var maxVal = ""
            var seen: HashSet[string]
            for row in filteredRows:
              let v = evalExpr(aggExpr.aggArgs[0], row, ctx)
              if v.kind == vkNull: continue
              let s = valueToString(v)
              if shouldKeepDistinct(seen, s, aggExpr.aggDistinct):
                if maxVal == "" or cmpMax(s, maxVal): maxVal = s
            aggRow[aggKey] = maxVal
          of irArrayAgg:
            var arr: seq[string]
            var seen: HashSet[string]
            for row in filteredRows:
              if aggExpr.aggArgs.len > 0:
                let s = valueToString(evalExpr(aggExpr.aggArgs[0], row, ctx))
                if shouldKeepDistinct(seen, s, aggExpr.aggDistinct):
                  arr.add(s)
            aggRow[aggKey] = "[" & arr.join(", ") & "]"
          of irStringAgg:
            var parts: seq[string]
            var seen: HashSet[string]
            let delim = if aggExpr.aggArgs.len > 1: evalExpr(aggExpr.aggArgs[1], initTable[string, Value](), ctx) else: Value(kind: vkString, strVal: ",")
            for row in filteredRows:
              if aggExpr.aggArgs.len > 0:
                let s = valueToString(evalExpr(aggExpr.aggArgs[0], row, ctx))
                if shouldKeepDistinct(seen, s, aggExpr.aggDistinct):
                  parts.add(s)
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
