## Codegen — compile IR plan to storage operations
import std/strutils
import ../query/ir

type
  StorageOpKind* = enum
    sokScan       # full table scan
    sokPointRead  # single key read
    sokRangeScan  # range scan
    sokInsert     # insert record
    sokUpdate     # update record
    sokDelete     # delete record
    sokFilter     # filter results
    sokProject    # select columns
    sokSort       # sort results
    sokLimit      # limit results
    sokHashJoin   # hash join
    sokMergeJoin  # merge join
    sokAggregate  # aggregation
    sokGroupBy    # group by

  StorageOp* = ref object
    kind*: StorageOpKind
    table*: string
    alias*: string
    key*: string
    startKey*: string
    endKey*: string
    columns*: seq[string]
    filterExpr*: IRExpr
    sortExprs*: seq[IRExpr]
    sortDirs*: seq[bool]
    limit*: int64
    offset*: int64
    children*: seq[StorageOp]
    aggFuncs*: seq[(string, IRAggregate)]
    groupKeys*: seq[string]
    joinCond*: IRExpr
    joinType*: IRJoinKind

  CodegenResult* = object
    ops*: seq[StorageOp]
    tables*: seq[string]
    estimatedCost*: float64

proc newStorageOp*(kind: StorageOpKind): StorageOp =
  StorageOp(kind: kind, children: @[], columns: @[], sortExprs: @[], sortDirs: @[],
            limit: 0, offset: 0, aggFuncs: @[], groupKeys: @[])

proc codegenExpr*(expr: IRExpr): StorageOp =
  if expr == nil:
    return nil
  case expr.kind
  of irekLiteral:
    return nil
  of irekField:
    return nil
  of irekUnary:
    return codegenExpr(expr.unExpr)
  of irekBinary:
    let left = codegenExpr(expr.binLeft)
    let right = codegenExpr(expr.binRight)
    return nil
  of irekAggregate:
    return nil
  else:
    return nil

proc codegenPlan*(plan: IRPlan): StorageOp =
  if plan == nil:
    return nil

  case plan.kind
  of irpkScan:
    let op = newStorageOp(sokScan)
    op.table = plan.scanTable
    op.alias = plan.scanAlias
    return op

  of irpkFilter:
    let sourceOp = codegenPlan(plan.filterSource)
    if sourceOp != nil and plan.filterCond != nil:
      # Try to push filter down to scan level
      if sourceOp.kind == sokScan and plan.filterCond.kind == irekBinary:
        if plan.filterCond.binOp == irEq and plan.filterCond.binLeft.kind == irekField:
          let fieldPath = plan.filterCond.binLeft.fieldPath
          if fieldPath.len == 1:
            # Convert to point read
            let op = newStorageOp(sokPointRead)
            op.table = sourceOp.table
            op.key = fieldPath[0]
            return op
      sourceOp.filterExpr = plan.filterCond
      return sourceOp
    let op = newStorageOp(sokFilter)
    op.filterExpr = plan.filterCond
    if sourceOp != nil:
      op.children.add(sourceOp)
    return op

  of irpkProject:
    let sourceOp = codegenPlan(plan.projectSource)
    let op = newStorageOp(sokProject)
    op.columns = plan.projectAliases
    if sourceOp != nil:
      op.children.add(sourceOp)
    return op

  of irpkGroupBy:
    let sourceOp = codegenPlan(plan.groupSource)
    let op = newStorageOp(sokGroupBy)
    for key in plan.groupKeys:
      if key.kind == irekField and key.fieldPath.len > 0:
        op.groupKeys.add(key.fieldPath[^1])
    if sourceOp != nil:
      op.children.add(sourceOp)
    return op

  of irpkJoin:
    let leftOp = codegenPlan(plan.joinLeft)
    let rightOp = codegenPlan(plan.joinRight)
    let op = newStorageOp(sokHashJoin)
    op.joinCond = plan.joinCond
    op.joinType = plan.joinKind
    if leftOp != nil: op.children.add(leftOp)
    if rightOp != nil: op.children.add(rightOp)
    return op

  of irpkSort:
    let sourceOp = codegenPlan(plan.sortSource)
    let op = newStorageOp(sokSort)
    op.sortExprs = plan.sortExprs
    op.sortDirs = plan.sortDirs
    if sourceOp != nil:
      op.children.add(sourceOp)
    return op

  of irpkLimit:
    let sourceOp = codegenPlan(plan.limitSource)
    if sourceOp != nil:
      sourceOp.limit = plan.limitCount
      sourceOp.offset = plan.limitOffset
      return sourceOp
    let op = newStorageOp(sokLimit)
    op.limit = plan.limitCount
    op.offset = plan.limitOffset
    return op

  of irpkInsert:
    let op = newStorageOp(sokInsert)
    op.table = plan.insertTable
    op.columns = plan.insertFields
    return op

  of irpkUpdate:
    let sourceOp = codegenPlan(plan.updateSource)
    let op = newStorageOp(sokUpdate)
    op.table = plan.updateTable
    op.alias = plan.updateAlias
    if sourceOp != nil:
      op.children.add(sourceOp)
    return op

  of irpkDelete:
    let sourceOp = codegenPlan(plan.deleteSource)
    let op = newStorageOp(sokDelete)
    op.table = plan.deleteTable
    op.alias = plan.deleteAlias
    if sourceOp != nil:
      op.children.add(sourceOp)
    return op

  of irpkCreateType:
    return newStorageOp(sokScan)

  of irpkUnion:
    let leftOp = codegenPlan(plan.unionLeft)
    let rightOp = codegenPlan(plan.unionRight)
    let op = newStorageOp(sokScan)
    if leftOp != nil: op.children.add(leftOp)
    if rightOp != nil: op.children.add(rightOp)
    return op

  of irpkCTE:
    let cteOp = codegenPlan(plan.cteQuery)
    let mainOp = codegenPlan(plan.cteMain)
    let op = newStorageOp(sokScan)
    if cteOp != nil: op.children.add(cteOp)
    if mainOp != nil: op.children.add(mainOp)
    return op

  of irpkValues:
    return newStorageOp(sokScan)

  of irpkExplain:
    return codegenPlan(plan.explainPlan)
  of irpkWindow:
    let sourceOp = codegenPlan(plan.winSource)
    let op = newStorageOp(sokProject)
    for wf in plan.winFuncs:
      op.columns.add(wf.wfName)
    if sourceOp != nil:
      op.children.add(sourceOp)
    return op
  of irpkMerge:
    return newStorageOp(sokScan)
  of irpkPivot:
    let sourceOp = codegenPlan(plan.pivotSource)
    let op = newStorageOp(sokScan)
    if sourceOp != nil: op.children.add(sourceOp)
    return op
  of irpkUnpivot:
    let sourceOp = codegenPlan(plan.unpivotSource)
    let op = newStorageOp(sokScan)
    if sourceOp != nil: op.children.add(sourceOp)
    return op
  of irpkGraphTraversal:
    return newStorageOp(sokScan)

proc estimateCost*(op: StorageOp): float64 =
  if op == nil:
    return 0.0
  case op.kind
  of sokPointRead: return 1.0
  of sokRangeScan: return 10.0
  of sokScan: return 1000.0
  of sokFilter:
    var cost = 100.0
    for child in op.children:
      cost += estimateCost(child)
    return cost
  of sokProject:
    var cost = 0.0
    for child in op.children:
      cost += estimateCost(child)
    return cost + 1.0
  of sokSort:
    var cost = 0.0
    for child in op.children:
      cost += estimateCost(child)
    return cost * 2.0
  of sokLimit:
    var cost = 0.0
    for child in op.children:
      cost += estimateCost(child)
    return cost * 0.5
  of sokHashJoin:
    var cost = 0.0
    for child in op.children:
      cost += estimateCost(child)
    return cost * 3.0
  of sokGroupBy:
    var cost = 0.0
    for child in op.children:
      cost += estimateCost(child)
    return cost * 2.0
  else:
    var cost = 0.0
    for child in op.children:
      cost += estimateCost(child)
    return cost

proc explain*(op: StorageOp, indent: int = 0): string =
  if op == nil:
    return ""
  result = " ".repeat(indent) & $op.kind
  if op.table.len > 0:
    result &= " table=" & op.table
  if op.key.len > 0:
    result &= " key=" & op.key
  if op.limit > 0:
    result &= " limit=" & $op.limit
  result &= " (cost=" & $estimateCost(op) & ")\n"
  for child in op.children:
    result &= explain(child, indent + 2)
