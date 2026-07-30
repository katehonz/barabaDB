## AST → IR lowering (lowerExpr / lowerSelect) — extracted from
## `executor.nim` (Task 6 of the executor split).
import std/strutils
import std/tables
import ../ast
import ../ir
import ../../core/types
import values
import context
import eval

# ----------------------------------------------------------------------
# AST → IR Lowering
# ----------------------------------------------------------------------

proc lowerSelect*(node: Node): IRPlan

proc lowerExpr*(node: Node): IRExpr =
  if node == nil: return nil
  case node.kind
  of nkIntLit:
    result = IRExpr(kind: irekLiteral, valueKind: vkInt64)
    result.literal = IRLiteral(kind: vkInt64, int64Val: node.intVal)
  of nkFloatLit:
    result = IRExpr(kind: irekLiteral, valueKind: vkFloat64)
    result.literal = IRLiteral(kind: vkFloat64, float64Val: node.floatVal)
  of nkStringLit:
    result = IRExpr(kind: irekLiteral, valueKind: vkString)
    result.literal = IRLiteral(kind: vkString, strVal: node.strVal)
  of nkBoolLit:
    result = IRExpr(kind: irekLiteral, valueKind: vkBool)
    result.literal = IRLiteral(kind: vkBool, boolVal: node.boolVal)
  of nkNullLit:
    result = IRExpr(kind: irekLiteral, valueKind: vkNull)
    result.literal = IRLiteral(kind: vkNull)
  of nkCurrentUser:
    result = IRExpr(kind: irekFuncCall)
    result.irFunc = "current_user"
    result.irFuncArgs = @[]
  of nkCurrentRole:
    result = IRExpr(kind: irekFuncCall)
    result.irFunc = "current_role"
    result.irFuncArgs = @[]
  of nkIdent:
    result = IRExpr(kind: irekField, valueKind: vkString)
    result.fieldPath = @[node.identName]
  of nkPath:
    result = IRExpr(kind: irekField, valueKind: vkString)
    result.fieldPath = node.pathParts
  of nkJsonPath:
    result = IRExpr(kind: irekJsonPath)
    result.jpExpr = lowerExpr(node.jpLeft)
    result.jpKey = node.jpKey
    result.jpAsText = node.jpAsText
  of nkBinOp:
    result = IRExpr(kind: irekBinary)
    result.valueKind = vkString
    var irOp: IROperator
    case node.binOp
    of bkAdd: irOp = irAdd
    of bkSub: irOp = irSub
    of bkMul: irOp = irMul
    of bkDiv: irOp = irDiv
    of bkMod: irOp = irMod
    of bkEq: irOp = irEq
    of bkNotEq: irOp = irNeq
    of bkLt: irOp = irLt
    of bkLtEq: irOp = irLte
    of bkGt: irOp = irGt
    of bkGtEq: irOp = irGte
    of bkAnd: irOp = irAnd
    of bkOr: irOp = irOr
    of bkFtsMatch: irOp = irFtsMatch
    of bkDistance: irOp = irDistance
    of bkJsonContains: irOp = irJsonContains
    of bkJsonContainedBy: irOp = irJsonContainedBy
    of bkJsonHasAny: irOp = irJsonHasAny
    of bkJsonHasAll: irOp = irJsonHasAll
    else: irOp = irEq
    result.binOp = irOp
    result.binLeft = lowerExpr(node.binLeft)
    result.binRight = lowerExpr(node.binRight)
    # Infer valueKind for arithmetic operators
    case irOp
    of irAdd, irSub, irMul:
      if result.binLeft != nil and result.binRight != nil:
        if result.binLeft.valueKind == vkFloat64 or result.binRight.valueKind == vkFloat64:
          result.valueKind = vkFloat64
        elif result.binLeft.valueKind == vkInt64 and result.binRight.valueKind == vkInt64:
          result.valueKind = vkInt64
    of irDiv:
      result.valueKind = vkFloat64
    of irMod:
      result.valueKind = vkInt64
    of irPow:
      result.valueKind = vkFloat64
    of irEq, irNeq, irLt, irLte, irGt, irGte, irAnd, irOr,
       irIn, irNotIn, irLike, irILike, irBetween,
       irIsNull, irIsNotNull, irFtsMatch:
      result.valueKind = vkBool
    else: discard
  of nkUnaryOp:
    result = IRExpr(kind: irekUnary, valueKind: vkString)
    result.unOp = if node.unOp == ukNot: irNot else: irNeg
    result.unExpr = lowerExpr(node.unOperand)
    if node.unOp == ukNeg and result.unExpr != nil:
      result.valueKind = result.unExpr.valueKind
  of nkFuncCall:
    case node.funcName.toLower()
    of "count", "sum", "avg", "min", "max", "array_agg", "string_agg":
      result = IRExpr(kind: irekAggregate)
      case node.funcName.toLower()
      of "count": result.aggOp = irCount; result.valueKind = vkInt64
      of "sum": result.aggOp = irSum; result.valueKind = vkFloat64
      of "avg": result.aggOp = irAvg; result.valueKind = vkFloat64
      of "min": result.aggOp = irMin
      of "max": result.aggOp = irMax
      of "array_agg": result.aggOp = irArrayAgg
      of "string_agg": result.aggOp = irStringAgg
      else: discard
      result.aggArgs = @[]
      for arg in node.funcArgs: result.aggArgs.add(lowerExpr(arg))
      if node.funcFilter != nil:
        result.aggFilter = lowerExpr(node.funcFilter)
    else:
      result = IRExpr(kind: irekFuncCall, valueKind: vkString)
      result.irFunc = node.funcName
      result.irFuncArgs = @[]
      for arg in node.funcArgs: result.irFuncArgs.add(lowerExpr(arg))
  of nkIsExpr:
    result = IRExpr(kind: irekUnary, valueKind: vkBool)
    result.unOp = if node.isNegated: irIsNotNull else: irIsNull
    result.unExpr = lowerExpr(node.isExpr)
  of nkLikeExpr:
    result = IRExpr(kind: irekBinary, valueKind: vkBool)
    result.binOp = if node.likeCaseInsensitive: irILike else: irLike
    result.binLeft = lowerExpr(node.likeExpr)
    result.binRight = lowerExpr(node.likePattern)
    if node.likeNegated:
      let wrapped = result
      result = IRExpr(kind: irekUnary, valueKind: vkBool, unOp: irNot, unExpr: wrapped)
  of nkBetweenExpr:
    if node.betweenNegated:
      # NOT BETWEEN => NOT (expr >= low AND expr <= high)
      result = IRExpr(kind: irekBinary, valueKind: vkBool)
      result.binOp = irOr
      let leftCmp = IRExpr(kind: irekBinary, valueKind: vkBool)
      leftCmp.binOp = irLt
      leftCmp.binLeft = lowerExpr(node.betweenExpr)
      leftCmp.binRight = lowerExpr(node.betweenLow)
      let rightCmp = IRExpr(kind: irekBinary, valueKind: vkBool)
      rightCmp.binOp = irGt
      rightCmp.binLeft = lowerExpr(node.betweenExpr)
      rightCmp.binRight = lowerExpr(node.betweenHigh)
      result.binLeft = leftCmp
      result.binRight = rightCmp
    else:
      result = IRExpr(kind: irekBinary, valueKind: vkBool)
      result.binOp = irAnd
      let leftCmp = IRExpr(kind: irekBinary, valueKind: vkBool)
      leftCmp.binOp = irGte
      leftCmp.binLeft = lowerExpr(node.betweenExpr)
      leftCmp.binRight = lowerExpr(node.betweenLow)
      let rightCmp = IRExpr(kind: irekBinary, valueKind: vkBool)
      rightCmp.binOp = irLte
      rightCmp.binLeft = lowerExpr(node.betweenExpr)
      rightCmp.binRight = lowerExpr(node.betweenHigh)
      result.binLeft = leftCmp
      result.binRight = rightCmp
  of nkInExpr:
    if node.inRight.kind == nkArrayLit:
      if node.inNegated:
        # NOT IN (list) => AND of != comparisons
        result = IRExpr(kind: irekLiteral, literal: IRLiteral(kind: vkBool, boolVal: true))
        for elem in node.inRight.arrayElems:
          let neqCmp = IRExpr(kind: irekBinary)
          neqCmp.binOp = irNeq
          neqCmp.binLeft = lowerExpr(node.inLeft)
          neqCmp.binRight = lowerExpr(elem)
          let andNode = IRExpr(kind: irekBinary)
          andNode.binOp = irAnd
          andNode.binLeft = result
          andNode.binRight = neqCmp
          result = andNode
      else:
        result = IRExpr(kind: irekLiteral, literal: IRLiteral(kind: vkBool, boolVal: false))
        for elem in node.inRight.arrayElems:
          let eqCmp = IRExpr(kind: irekBinary)
          eqCmp.binOp = irEq
          eqCmp.binLeft = lowerExpr(node.inLeft)
          eqCmp.binRight = lowerExpr(elem)
          let orNode = IRExpr(kind: irekBinary)
          orNode.binOp = irOr
          orNode.binLeft = result
          orNode.binRight = eqCmp
          result = orNode
    elif node.inRight.kind == nkSubquery:
      result = IRExpr(kind: irekBinary)
      result.binOp = if node.inNegated: irNotIn else: irIn
      result.binLeft = lowerExpr(node.inLeft)
      result.binRight = IRExpr(kind: irekSubquery)
      result.binRight.subqueryPlan = lowerSelect(node.inRight.subQuery)
    else:
      result = IRExpr(kind: irekBinary)
      result.binOp = if node.inNegated: irNeq else: irEq
      result.binLeft = lowerExpr(node.inLeft)
      result.binRight = lowerExpr(node.inRight)
  of nkExists:
    result = IRExpr(kind: irekExists)
    result.existsSubquery = lowerSelect(node.existsExpr)
  of nkSubquery:
    result = IRExpr(kind: irekSubquery)
    result.subqueryPlan = lowerSelect(node.subQuery)
  of nkStar:
    result = IRExpr(kind: irekStar)
  of nkWindowExpr:
    result = IRExpr(kind: irekWindowFunc)
    result.wfName = node.winFunc
    result.wfArgs = @[]
    for arg in node.winArgs: result.wfArgs.add(lowerExpr(arg))
    result.wfPartition = @[]
    if node.winOver != nil:
      for part in node.winOver.overPartition:
        result.wfPartition.add(lowerExpr(part))
      result.wfOrderBy = @[]
      result.wfOrderDirs = @[]
      for ob in node.winOver.overOrderBy:
        result.wfOrderBy.add(lowerExpr(ob.orderByExpr))
        result.wfOrderDirs.add(ob.orderByDir == sdDesc)
      if node.winOver.overFrame != nil:
        result.wfFrameMode = node.winOver.overFrame.frameMode
        result.wfFrameStart = node.winOver.overFrame.frameStartType
        result.wfFrameEnd = node.winOver.overFrame.frameEndType
      else:
        result.wfFrameMode = "ROWS"
        result.wfFrameStart = "UNBOUNDED PRECEDING"
        result.wfFrameEnd = "CURRENT ROW"
  else:
    result = IRExpr(kind: irekLiteral, literal: IRLiteral(kind: vkNull))

proc evalNodeToString*(node: Node): string =
  ## Evaluate a simple AST node to a string value for INSERT/UPDATE.
  let ir = lowerExpr(node)
  return valueToString(evalExpr(ir, initTable[string, Value](), nil))

proc lowerSelect*(node: Node): IRPlan =
  result = IRPlan(kind: irpkScan)
  if node.selFrom != nil:
    if node.selFrom.kind == nkPivot:
      # PIVOT: source PIVOT (agg(val) FOR col IN ('v1', 'v2'))
      let pivotSrc = node.selFrom.pivotSource
      var pivotSource: IRPlan
      if pivotSrc.kind == nkFrom and pivotSrc.fromSubquery != nil:
        pivotSource = lowerSelect(pivotSrc.fromSubquery)
      elif pivotSrc.kind == nkFrom:
        pivotSource = IRPlan(kind: irpkScan)
        pivotSource.scanTable = pivotSrc.fromTable
        pivotSource.scanAlias = pivotSrc.fromAlias
      else:
        pivotSource = lowerSelect(Node(kind: nkSelect, selFrom: pivotSrc,
                                        selResult: @[Node(kind: nkStar)],
                                        selJoins: @[], selGroupBy: @[],
                                        line: node.line, col: node.col))
      let pivotPlan = IRPlan(kind: irpkPivot)
      pivotPlan.pivotSource = pivotSource
      pivotPlan.pivotAgg = lowerExpr(node.selFrom.pivotAgg)
      pivotPlan.pivotForCol = node.selFrom.pivotForCol
      pivotPlan.pivotInValues = node.selFrom.pivotInValues
      result = pivotPlan
    elif node.selFrom.kind == nkUnpivot:
      let unpivotSource = lowerSelect(Node(kind: nkSelect, selFrom: node.selFrom.unpivotSource,
                                            selResult: @[Node(kind: nkStar)],
                                            selJoins: @[], selGroupBy: @[],
                                            line: node.line, col: node.col))
      let unpivotPlan = IRPlan(kind: irpkUnpivot)
      unpivotPlan.unpivotSource = unpivotSource
      unpivotPlan.unpivotValueCol = node.selFrom.unpivotValueCol
      unpivotPlan.unpivotForCol = node.selFrom.unpivotForCol
      unpivotPlan.unpivotInCols = node.selFrom.unpivotInCols
      result = unpivotPlan
    elif node.selFrom.kind == nkGraphTraversal:
      let graphPlan = IRPlan(kind: irpkGraphTraversal)
      graphPlan.graphName = node.selFrom.gtGraphName
      graphPlan.graphAlgo = node.selFrom.gtAlgo.toLowerAscii()
      if node.selFrom.gtStart != nil:
        if node.selFrom.gtStart.kind == nkIdent:
          graphPlan.graphStartNode = node.selFrom.gtStart.identName
        elif node.selFrom.gtStart.kind == nkIntLit:
          graphPlan.graphStartNode = $node.selFrom.gtStart.intVal
      if node.selFrom.gtEnd != nil:
        if node.selFrom.gtEnd.kind == nkIdent:
          graphPlan.graphEndNode = node.selFrom.gtEnd.identName
        elif node.selFrom.gtEnd.kind == nkIntLit:
          graphPlan.graphEndNode = $node.selFrom.gtEnd.intVal
      graphPlan.graphEdgeLabel = node.selFrom.gtEdge
      graphPlan.graphMaxDepth = node.selFrom.gtMaxDepth
      graphPlan.graphReturnCols = node.selFrom.gtReturnCols
      result = graphPlan
    elif node.selFrom.fromTable.len > 0:
      result.scanTable = node.selFrom.fromTable
      result.scanAlias = node.selFrom.fromAlias

  # Build JOIN chain
  for joinNode in node.selJoins:
    if joinNode.kind == nkJoin:
      let joinPlan = IRPlan(kind: irpkJoin)
      case joinNode.joinKind
      of jkInner: joinPlan.joinKind = irjkInner
      of jkLeft: joinPlan.joinKind = irjkLeft
      of jkRight: joinPlan.joinKind = irjkRight
      of jkFull: joinPlan.joinKind = irjkFull
      of jkCross: joinPlan.joinKind = irjkCross
      joinPlan.joinLateral = joinNode.joinLateral
      joinPlan.joinLeft = result
      if joinNode.joinLateral and joinNode.joinTarget != nil and joinNode.joinTarget.kind == nkSubquery:
        # LATERAL: right side is a full subquery plan
        joinPlan.joinRight = lowerSelect(joinNode.joinTarget.subQuery)
      else:
        joinPlan.joinRight = IRPlan(kind: irpkScan)
        if joinNode.joinTarget != nil and joinNode.joinTarget.kind == nkFrom:
          joinPlan.joinRight.scanTable = joinNode.joinTarget.fromTable
          joinPlan.joinRight.scanAlias = joinNode.joinTarget.fromAlias
        else:
          joinPlan.joinRight.scanTable = ""
      joinPlan.joinAlias = joinNode.joinAlias
      if joinNode.joinOn != nil:
        joinPlan.joinCond = lowerExpr(joinNode.joinOn)
      result = joinPlan

  if node.selWhere != nil and node.selWhere.whereExpr != nil:
    let filterPlan = IRPlan(kind: irpkFilter)
    filterPlan.filterSource = result
    filterPlan.filterCond = lowerExpr(node.selWhere.whereExpr)
    result = filterPlan

  if node.selGroupBy.len > 0 or node.selGroupingSetsKind != gskNone:
    let groupPlan = IRPlan(kind: irpkGroupBy)
    groupPlan.groupSource = result
    groupPlan.groupKeys = @[]
    for g in node.selGroupBy: groupPlan.groupKeys.add(lowerExpr(g))
    # Collect aggregate expressions from SELECT list
    groupPlan.groupAggs = @[]
    for e in node.selResult:
      let lowered = lowerExpr(e)
      if lowered.kind == irekAggregate:
        groupPlan.groupAggs.add(lowered)
    if node.selHaving != nil:
      groupPlan.groupHaving = lowerExpr(node.selHaving.havingExpr)
    # Handle grouping sets
    case node.selGroupingSetsKind
    of gskNone:
      groupPlan.groupingSetsKind = irgskNone
    of gskGroupingSets:
      groupPlan.groupingSetsKind = irgskGroupingSets
      groupPlan.groupingSets = @[]
      for s in node.selGroupingSets:
        var setExprs: seq[IRExpr] = @[]
        for e in s: setExprs.add(lowerExpr(e))
        groupPlan.groupingSets.add(setExprs)
    of gskRollup:
      groupPlan.groupingSetsKind = irgskRollup
    of gskCube:
      groupPlan.groupingSetsKind = irgskCube
    result = groupPlan

  if node.selOrderBy.len > 0:
    let sortPlan = IRPlan(kind: irpkSort)
    sortPlan.sortSource = result
    sortPlan.sortExprs = @[]
    sortPlan.sortDirs = @[]
    for o in node.selOrderBy:
      sortPlan.sortExprs.add(lowerExpr(o.orderByExpr))
      sortPlan.sortDirs.add(o.orderByDir == sdAsc)
    result = sortPlan

  let projectPlan = IRPlan(kind: irpkProject)
  projectPlan.projectSource = result
  projectPlan.projectExprs = @[]
  projectPlan.projectAliases = @[]
  var seenAliases = initTable[string, int]()
  for i, e in node.selResult:
    projectPlan.projectExprs.add(lowerExpr(e))
    var alias = ""
    if e.exprAlias.len > 0:
      alias = e.exprAlias
    elif e.kind == nkIdent:
      alias = e.identName
    elif e.kind == nkPath and e.pathParts.len > 0:
      alias = e.pathParts.join(".")
    elif e.kind == nkFuncCall:
      var aliasArgs: seq[string] = @[]
      for arg in e.funcArgs:
        aliasArgs.add(exprToSql(arg))
      alias = e.funcName & "(" & aliasArgs.join(", ") & ")"
    elif e.kind == nkStar:
      alias = "*"
    else:
      alias = "col" & $i
    # Deduplicate aliases
    if alias in seenAliases:
      seenAliases[alias] += 1
      alias = alias & "_" & $seenAliases[alias]
    else:
      seenAliases[alias] = 0
    projectPlan.projectAliases.add(alias)
  result = projectPlan

  if node.selLimit != nil or node.selOffset != nil:
    let limitPlan = IRPlan(kind: irpkLimit)
    limitPlan.limitSource = result
    limitPlan.limitCount = if node.selLimit != nil and node.selLimit.limitExpr.kind == nkIntLit:
      node.selLimit.limitExpr.intVal else: 0
    limitPlan.limitOffset = if node.selOffset != nil and node.selOffset.offsetExpr.kind == nkIntLit:
      node.selOffset.offsetExpr.intVal else: 0
    result = limitPlan

