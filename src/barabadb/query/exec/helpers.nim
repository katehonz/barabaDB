## Join strategy, vector parsing, and correlated-table helpers.
##
## Extracted from `executor.nim` (Task 2 of the executor split).
import std/strutils
import std/tables
import ../ir
import types

proc cmpMax*(a, b: string): bool =
  var fa, fb: float
  try:
    fa = parseFloat(a)
    fb = parseFloat(b)
    result = fa > fb
  except ValueError:
    result = a > b

proc cmpMin*(a, b: string): bool =
  var fa, fb: float
  try:
    fa = parseFloat(a)
    fb = parseFloat(b)
    result = fa < fb
  except ValueError:
    result = a < b

proc extractJoinEquality*(expr: IRExpr): (string, string) =
  ## Extract (leftCol, rightCol) from an equality join condition.
  ## Both operands must be simple field references.
  if expr == nil or expr.kind != irekBinary or expr.binOp != irEq:
    return ("", "")
  if expr.binLeft.kind == irekField and expr.binRight.kind == irekField:
    if expr.binLeft.fieldPath.len > 0 and expr.binRight.fieldPath.len > 0:
      return (expr.binLeft.fieldPath[^1], expr.binRight.fieldPath[^1])
  return ("", "")

proc chooseJoinStrategy*(ctx: ExecutionContext, plan: IRPlan) =
  ## Analyze join condition and pick the best execution strategy.
  if plan == nil or plan.kind != irpkJoin:
    return
  if plan.joinCond == nil:
    plan.joinStrategy = irjsNestedLoop
    return
  let (leftCol, rightCol) = extractJoinEquality(plan.joinCond)
  if leftCol.len == 0 or rightCol.len == 0:
    plan.joinStrategy = irjsNestedLoop
    return
  # Check if either side has a B-Tree index on the join column
  proc isPkIndex(tableName, colName: string): bool =
    if tableName in ctx.tables:
      for col in ctx.tables[tableName].columns:
        if col.name == colName and col.isPk:
          return true
    return false

  var hasLeftIndex = false
  var hasRightIndex = false
  if plan.joinLeft != nil and plan.joinLeft.kind == irpkScan:
    let idxName = plan.joinLeft.scanTable & "." & leftCol
    if idxName in ctx.btrees and not isPkIndex(plan.joinLeft.scanTable, leftCol):
      hasLeftIndex = true
  if plan.joinRight != nil and plan.joinRight.kind == irpkScan:
    let idxName = plan.joinRight.scanTable & "." & rightCol
    if idxName in ctx.btrees and not isPkIndex(plan.joinRight.scanTable, rightCol):
      hasRightIndex = true
  if hasRightIndex:
    plan.joinStrategy = irjsIndexNestedLoop
    plan.joinHashCol = rightCol
  elif hasLeftIndex:
    plan.joinStrategy = irjsIndexNestedLoop
    plan.joinHashCol = leftCol
  else:
    plan.joinStrategy = irjsHash
    plan.joinHashCol = rightCol

proc parseVectorString*(value: string): seq[float32] =
  ## Parse a vector string like "[1.0, 2.0, 3.0]" into seq[float32]
  result = @[]
  var cleaned = value.strip()
  if cleaned.len == 0: return result
  if cleaned.startsWith("[") and cleaned.endsWith("]"):
    cleaned = cleaned[1..^2]
  elif cleaned.startsWith("(") and cleaned.endsWith(")"):
    cleaned = cleaned[1..^2]
  for part in cleaned.split(","):
    let p = part.strip()
    if p.len > 0:
      try:
        result.add(parseFloat(p).float32)
      except CatchableError:
        discard

# Collect correlated table names from IRExpr (qualified refs with 2+ parts)
proc collectCorrelatedTables(expr: IRExpr, outTables: var seq[string]) =
  if expr == nil: return
  case expr.kind
  of irekField:
    if expr.fieldPath.len >= 2:
      let tbl = expr.fieldPath[0]
      if tbl notin outTables: outTables.add(tbl)
  of irekBinary:
    collectCorrelatedTables(expr.binLeft, outTables)
    collectCorrelatedTables(expr.binRight, outTables)
  of irekUnary:
    collectCorrelatedTables(expr.unExpr, outTables)
  of irekFuncCall:
    for a in expr.irFuncArgs: collectCorrelatedTables(a, outTables)
  of irekCast:
    collectCorrelatedTables(expr.irCastExpr, outTables)
  of irekExists:
    discard  # nested exists — skip for simplicity
  of irekAggregate:
    for a in expr.aggArgs: collectCorrelatedTables(a, outTables)
  of irekConditional:
    collectCorrelatedTables(expr.cond, outTables)
    collectCorrelatedTables(expr.thenExpr, outTables)
    collectCorrelatedTables(expr.elseExpr, outTables)
  of irekWindowFunc:
    for a in expr.wfArgs: collectCorrelatedTables(a, outTables)
    for a in expr.wfPartition: collectCorrelatedTables(a, outTables)
    for a in expr.wfOrderBy: collectCorrelatedTables(a, outTables)
  else: discard

# Walk plan to find correlated table names
proc collectCorrelatedTablesFromPlan*(plan: IRPlan, outTables: var seq[string]) =
  if plan == nil: return
  case plan.kind
  of irpkScan: discard
  of irpkFilter:
    collectCorrelatedTables(plan.filterCond, outTables)
    collectCorrelatedTablesFromPlan(plan.filterSource, outTables)
  of irpkProject:
    for e in plan.projectExprs: collectCorrelatedTables(e, outTables)
    collectCorrelatedTablesFromPlan(plan.projectSource, outTables)
  of irpkSort:
    for e in plan.sortExprs: collectCorrelatedTables(e, outTables)
    collectCorrelatedTablesFromPlan(plan.sortSource, outTables)
  of irpkLimit:
    collectCorrelatedTablesFromPlan(plan.limitSource, outTables)
  of irpkGroupBy:
    for e in plan.groupKeys: collectCorrelatedTables(e, outTables)
    for e in plan.groupAggs:
      for a in e.aggArgs: collectCorrelatedTables(a, outTables)
    collectCorrelatedTablesFromPlan(plan.groupSource, outTables)
  of irpkUnion:
    collectCorrelatedTablesFromPlan(plan.unionLeft, outTables)
    collectCorrelatedTablesFromPlan(plan.unionRight, outTables)
  of irpkJoin:
    collectCorrelatedTables(plan.joinCond, outTables)
    collectCorrelatedTablesFromPlan(plan.joinLeft, outTables)
    collectCorrelatedTablesFromPlan(plan.joinRight, outTables)
  of irpkInsert, irpkUpdate, irpkDelete, irpkValues, irpkExplain,
     irpkCTE, irpkWindow, irpkPivot, irpkUnpivot, irpkGraphTraversal,
     irpkMerge, irpkCreateType:
    discard
